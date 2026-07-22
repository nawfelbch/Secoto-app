// SECOTO — enregistrement du Service Worker et abonnement Web Push.
import { supabase } from "./supabaseClient";

const VAPID_PUBLIC_KEY = import.meta.env.VITE_VAPID_PUBLIC_KEY || "";

export function pushSupported() {
  return (
    typeof window !== "undefined" &&
    "serviceWorker" in navigator &&
    "PushManager" in window &&
    "Notification" in window
  );
}

export function pushConfigured() {
  return Boolean(VAPID_PUBLIC_KEY);
}

// Enregistre le service worker (PWA + push). Sans effet de bord si non supporté.
export async function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) return null;
  try {
    return await navigator.serviceWorker.register("/sw.js", { scope: "/" });
  } catch (err) {
    console.warn("SW registration failed", err);
    return null;
  }
}

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(base64);
  const output = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) output[i] = raw.charCodeAt(i);
  return output;
}

// Demande la permission, s'abonne et enregistre l'abonnement côté Supabase.
// Retourne { ok, reason }. Ne casse jamais l'app si les clés VAPID manquent.
export async function enablePush(account) {
  if (!pushSupported()) return { ok: false, reason: "unsupported" };
  if (!pushConfigured()) return { ok: false, reason: "no_vapid" };

  const permission = await Notification.requestPermission();
  if (permission !== "granted") return { ok: false, reason: "denied" };

  const registration = await navigator.serviceWorker.ready;
  let subscription = await registration.pushManager.getSubscription();
  if (!subscription) {
    subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
    });
  }

  const json = subscription.toJSON();
  try {
    await supabase.from("push_subscriptions").upsert(
      {
        account_id: account.id,
        role: account.role,
        endpoint: subscription.endpoint,
        p256dh: json.keys?.p256dh,
        auth: json.keys?.auth,
        user_agent: navigator.userAgent,
      },
      { onConflict: "endpoint" }
    );
  } catch (err) {
    console.warn("push subscription save failed", err);
    return { ok: false, reason: "save_failed" };
  }

  return { ok: true };
}

// Déclenche l'envoi push serveur (fonction Netlify). Silencieux si non déployé.
export async function triggerPush({ audience, transporterType, accountId, title, body, url, missionId }) {
  try {
    await fetch("/.netlify/functions/send-mission-notifications", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ audience, transporterType, accountId, title, body, url, missionId }),
    });
  } catch (err) {
    // La brique realtime prend le relais ; on n'interrompt pas le flux utilisateur.
    console.debug("triggerPush skipped", err?.message);
  }
}

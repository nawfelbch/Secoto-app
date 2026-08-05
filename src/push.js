// SECOTO — Web Push + APNs/FCM via l'adaptateur Capacitor.
// Aucun destinataire, rôle ou texte de notification n'est accepté ici :
// les messages sont créés par les opérations métier transactionnelles SQL.
import { Capacitor } from "@capacitor/core";
import { supabase } from "./supabaseClient";
import { buildMissionPath } from "./lib/deepLinks";

const VAPID_PUBLIC_KEY = import.meta.env.VITE_VAPID_PUBLIC_KEY || "";
const INSTALLATION_KEY = "secoto-installation-id-v1";
const CHANNEL_ID = "secoto-missions";

function installationId() {
  try {
    const existing = localStorage.getItem(INSTALLATION_KEY);
    if (existing) return existing;
    const created = globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`;
    localStorage.setItem(INSTALLATION_KEY, created);
    return created;
  } catch {
    return globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`;
  }
}

export function pushSupported() {
  if (Capacitor.isNativePlatform()) return Capacitor.getPlatform() === "ios" || Capacitor.getPlatform() === "android";
  return (
    typeof window !== "undefined" &&
    "serviceWorker" in navigator &&
    "PushManager" in window &&
    "Notification" in window
  );
}

export function pushConfigured() {
  return Capacitor.isNativePlatform() || Boolean(VAPID_PUBLIC_KEY);
}

export async function registerServiceWorker() {
  if (typeof navigator === "undefined" || !("serviceWorker" in navigator)) return null;
  try {
    return await navigator.serviceWorker.register("/sw.js", { scope: "/" });
  } catch {
    return null;
  }
}

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(base64);
  const output = new Uint8Array(raw.length);
  for (let index = 0; index < raw.length; index += 1) output[index] = raw.charCodeAt(index);
  return output;
}

async function registerNativeToken() {
  const { PushNotifications } = await import("@capacitor/push-notifications");
  let permission = await PushNotifications.checkPermissions();
  if (permission.receive === "prompt") permission = await PushNotifications.requestPermissions();
  if (permission.receive !== "granted") return { ok: false, reason: "denied" };

  if (Capacitor.getPlatform() === "android") {
    await PushNotifications.createChannel({
      id: CHANNEL_ID,
      name: "Missions SECOTO",
      description: "Avancement de vos missions et actions SECOTO",
      importance: 4,
      visibility: 0,
      vibration: true,
      lights: true,
    });
  }

  const token = await new Promise((resolve, reject) => {
    let registrationHandle;
    let errorHandle;
    const timeout = setTimeout(() => reject(new Error("Délai d'enregistrement push dépassé.")), 15000);
    Promise.all([
      PushNotifications.addListener("registration", (result) => {
        clearTimeout(timeout);
        resolve(result.value);
      }),
      PushNotifications.addListener("registrationError", (error) => {
        clearTimeout(timeout);
        reject(new Error(error?.error || "Enregistrement push refusé."));
      }),
    ]).then(([registered, failed]) => {
      registrationHandle = registered;
      errorHandle = failed;
      PushNotifications.register().catch(reject);
    });
    Promise.resolve().finally(() => {
      setTimeout(() => {
        registrationHandle?.remove().catch(() => {});
        errorHandle?.remove().catch(() => {});
      }, 16000);
    });
  });

  const platform = Capacitor.getPlatform();
  const { error } = await supabase.rpc("secoto_register_push_device", {
    p_platform: platform,
    p_provider: platform === "ios" ? "apns" : "fcm",
    p_token: token,
    p_installation_id: installationId(),
    p_device_label: navigator.userAgent.slice(0, 240),
  });
  if (error) throw error;
  return { ok: true };
}

async function registerWebSubscription() {
  if (!VAPID_PUBLIC_KEY) return { ok: false, reason: "no_vapid" };
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
  const { error } = await supabase.rpc("secoto_register_web_push", {
    p_endpoint: subscription.endpoint,
    p_p256dh: json.keys?.p256dh || "",
    p_auth: json.keys?.auth || "",
    p_installation_id: installationId(),
    p_device_label: navigator.userAgent.slice(0, 240),
  });
  if (error) throw error;
  return { ok: true };
}

// Appelé exclusivement après l'explication contextuelle affichée dans l'UI.
export async function enablePush() {
  if (!pushSupported()) return { ok: false, reason: "unsupported" };
  try {
    return Capacitor.isNativePlatform()
      ? await registerNativeToken()
      : await registerWebSubscription();
  } catch {
    return { ok: false, reason: "save_failed" };
  }
}

export async function initializePushListeners({ onNotification, onOpen } = {}) {
  if (!Capacitor.isNativePlatform()) return async () => {};
  const { PushNotifications } = await import("@capacitor/push-notifications");
  const received = await PushNotifications.addListener("pushNotificationReceived", (notification) => {
    onNotification?.({
      title: notification.title || "SECOTO",
      body: notification.body || "",
      data: notification.data || {},
    });
  });
  const action = await PushNotifications.addListener("pushNotificationActionPerformed", ({ notification }) => {
    const data = notification?.data || {};
    onOpen?.({
      kind: "navigation",
      screen: data.screen || "courses",
      missionId: data.missionId || data.mission_id || null,
    });
  });
  return async () => {
    await Promise.all([received.remove(), action.remove()]);
  };
}

export async function disablePush(accountId = null) {
  if (accountId) {
    try {
      localStorage.removeItem(`secoto-push-${accountId}`);
      localStorage.removeItem(`secoto-push-consent-v2-${accountId}`);
    } catch {
      /* ignore */
    }
  }
  try {
    await supabase.rpc("secoto_deactivate_push_device", {
      p_installation_id: installationId(),
    });
  } catch {
    // La déconnexion continue ; le token est aussi invalidé localement ci-dessous.
  }

  if (Capacitor.isNativePlatform()) {
    try {
      const { PushNotifications } = await import("@capacitor/push-notifications");
      await PushNotifications.unregister();
    } catch {
      // La session ne doit pas rester ouverte si le fournisseur push est indisponible.
    }
    return;
  }

  try {
    const registration = await navigator.serviceWorker.ready;
    const subscription = await registration.pushManager.getSubscription();
    await subscription?.unsubscribe();
  } catch {
    // Déjà désabonné ou navigateur non compatible.
  }
}

// Compatibilité temporaire avec les anciens appels : aucune cible ni aucun
// contenu n'est transmis. La RPC dérive le message de l'événement serveur.
export async function triggerPush({ eventType, missionId, operationId } = {}) {
  if (!eventType || !missionId) return { ok: false, reason: "server_event_required" };
  const { error } = await supabase.rpc("secoto_emit_business_event", {
    p_event_type: eventType,
    p_mission_id: missionId,
    p_idempotency_key: operationId || null,
  });
  return error ? { ok: false, reason: "server_rejected" } : { ok: true };
}

export function missionPushPath(missionId, screen = "courses") {
  return buildMissionPath(missionId, screen);
}

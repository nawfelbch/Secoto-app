import { Capacitor } from "@capacitor/core";
import { parseSecotoDeepLink, buildNativeAuthRedirect } from "../lib/deepLinks";

export function getPlatform() {
  const platform = Capacitor.getPlatform();
  return platform === "ios" || platform === "android" ? platform : "web";
}

export function isNativePlatform() {
  return Capacitor.isNativePlatform();
}

export function getAuthRedirectUrl() {
  if (isNativePlatform()) return buildNativeAuthRedirect();
  if (typeof window === "undefined") return "https://app.secoto-transport.fr/?auth=callback";
  return `${window.location.origin}/?auth=callback`;
}

export function getServerFunctionUrl(functionName) {
  const safeName = String(functionName || "").replace(/[^a-zA-Z0-9-]/g, "");
  if (!safeName) throw new Error("Fonction serveur invalide.");
  if (!isNativePlatform()) return `/.netlify/functions/${safeName}`;
  const base = String(import.meta.env.VITE_SECOTO_FUNCTIONS_BASE_URL || "")
    .trim()
    .replace(/\/+$/, "");
  if (!/^https:\/\//i.test(base)) {
    throw new Error("URL HTTPS des fonctions SECOTO absente du build mobile.");
  }
  return `${base}/${safeName}`;
}

function isAllowedExternalUrl(rawUrl) {
  try {
    const url = new URL(rawUrl, typeof window !== "undefined" ? window.location.origin : undefined);
    return ["https:", "mailto:", "tel:", "sms:", "whatsapp:"].includes(url.protocol);
  } catch {
    return false;
  }
}

export async function openExternal(rawUrl) {
  if (!isAllowedExternalUrl(rawUrl)) throw new Error("Lien externe non autorisé.");
  if (typeof window === "undefined") return;
  const opened = window.open(rawUrl, isNativePlatform() ? "_system" : "_blank", "noopener,noreferrer");
  if (!opened && !isNativePlatform()) window.location.assign(rawUrl);
}

export async function openRoute({ latitude, longitude, address } = {}) {
  let destination = "";
  if (Number.isFinite(Number(latitude)) && Number.isFinite(Number(longitude))) {
    destination = `${Number(latitude)},${Number(longitude)}`;
  } else if (address) {
    destination = String(address).trim();
  }
  if (!destination) throw new Error("Destination indisponible.");
  const url = `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(destination)}`;
  return openExternal(url);
}

export async function getOneTimeLocation() {
  if (!isNativePlatform() && !navigator.geolocation) {
    return { ok: false, reason: "unsupported" };
  }

  try {
    if (isNativePlatform()) {
      const { Geolocation } = await import("@capacitor/geolocation");
      let permission = await Geolocation.checkPermissions();
      if (permission.location === "prompt" || permission.coarseLocation === "prompt") {
        permission = await Geolocation.requestPermissions({ permissions: ["location"] });
      }
      if (permission.location !== "granted" && permission.coarseLocation !== "granted") {
        return { ok: false, reason: "denied" };
      }
      const position = await Geolocation.getCurrentPosition({
        enableHighAccuracy: true,
        timeout: 15000,
        maximumAge: 30000,
      });
      return {
        ok: true,
        latitude: position.coords.latitude,
        longitude: position.coords.longitude,
        accuracy: position.coords.accuracy,
        capturedAt: new Date(position.timestamp || Date.now()).toISOString(),
      };
    }

    const position = await new Promise((resolve, reject) => {
      navigator.geolocation.getCurrentPosition(resolve, reject, {
        enableHighAccuracy: true,
        timeout: 15000,
        maximumAge: 30000,
      });
    });
    return {
      ok: true,
      latitude: position.coords.latitude,
      longitude: position.coords.longitude,
      accuracy: position.coords.accuracy,
      capturedAt: new Date(position.timestamp || Date.now()).toISOString(),
    };
  } catch (error) {
    const denied = error?.code === 1 || /denied|permission/i.test(error?.message || "");
    return { ok: false, reason: denied ? "denied" : "unavailable" };
  }
}

export async function takeNativePhoto() {
  if (!isNativePlatform()) return { ok: false, reason: "web" };
  try {
    const { Camera, CameraResultType, CameraSource } = await import("@capacitor/camera");
    const photo = await Camera.getPhoto({
      source: CameraSource.Camera,
      resultType: CameraResultType.Uri,
      quality: 88,
      width: 2400,
      height: 2400,
      correctOrientation: true,
      saveToGallery: false,
      promptLabelHeader: "Ajouter une preuve",
      promptLabelPhoto: "Choisir une photo",
      promptLabelPicture: "Prendre une photo",
      promptLabelCancel: "Annuler",
    });
    if (!photo.webPath) return { ok: false, reason: "empty" };
    const response = await fetch(photo.webPath);
    if (!response.ok) throw new Error("Lecture de la photo impossible.");
    const blob = await response.blob();
    const extension = photo.format === "png" ? "png" : "jpg";
    const file = new File([blob], `secoto-${Date.now()}.${extension}`, {
      type: blob.type || `image/${extension === "jpg" ? "jpeg" : extension}`,
      lastModified: Date.now(),
    });
    return { ok: true, file };
  } catch (error) {
    if (/cancel/i.test(error?.message || "")) return { ok: false, reason: "cancelled" };
    return { ok: false, reason: "failed", error };
  }
}

export async function shareOrOpen({ title = "SECOTO", text = "", url }) {
  if (!url || !isAllowedExternalUrl(url)) throw new Error("Lien à partager non autorisé.");
  if (typeof navigator !== "undefined" && navigator.share) {
    try {
      await navigator.share({ title, text, url });
      return;
    } catch (error) {
      if (error?.name === "AbortError") return;
    }
  }
  return openExternal(url);
}

export async function initializePlatform({
  onResume,
  onNetworkChange,
  onDeepLink,
  onBack,
} = {}) {
  const handles = [];
  const runDeepLink = async (rawUrl) => {
    const parsed = parseSecotoDeepLink(
      rawUrl,
      typeof window !== "undefined" ? window.location.origin : undefined,
    );
    // Sur le Web, Supabase consomme lui-même une unique fois le code PKCE
    // (detectSessionInUrl). L'échange explicite reste réservé au callback natif.
    if (parsed?.kind === "auth" && !isNativePlatform()) return;
    if (parsed) await onDeepLink?.(parsed);
  };

  const online = () => onNetworkChange?.({ connected: true, connectionType: "unknown" });
  const offline = () => onNetworkChange?.({ connected: false, connectionType: "none" });
  if (typeof window !== "undefined") {
    window.addEventListener("online", online);
    window.addEventListener("offline", offline);
  }

  if (isNativePlatform()) {
    const [{ App }, { StatusBar, Style }] = await Promise.all([
      import("@capacitor/app"),
      import("@capacitor/status-bar"),
    ]);

    try {
      await StatusBar.setOverlaysWebView({ overlay: true });
      await StatusBar.setStyle({ style: Style.Dark });
    } catch {
      // Certains environnements WebView de test n'exposent pas la barre système.
    }

    handles.push(
      await App.addListener("appStateChange", ({ isActive }) => {
        if (isActive) onResume?.();
      }),
    );
    handles.push(await App.addListener("resume", () => onResume?.()));
    handles.push(await App.addListener("appUrlOpen", ({ url }) => runDeepLink(url)));
    handles.push(
      await App.addListener("appRestoredResult", (result) => {
        onResume?.({ restoredResult: result });
      }),
    );
    if (getPlatform() === "android") {
      handles.push(
        await App.addListener("backButton", ({ canGoBack }) => {
          const handled = onBack?.();
          if (handled) return;
          if (canGoBack && typeof window !== "undefined") window.history.back();
          else App.minimizeApp();
        }),
      );
    }
    const launch = await App.getLaunchUrl();
    if (launch?.url) await runDeepLink(launch.url);
  } else if (typeof window !== "undefined") {
    await runDeepLink(window.location.href);
  }

  return async () => {
    if (typeof window !== "undefined") {
      window.removeEventListener("online", online);
      window.removeEventListener("offline", offline);
    }
    await Promise.all(handles.map((handle) => handle.remove().catch(() => {})));
  };
}

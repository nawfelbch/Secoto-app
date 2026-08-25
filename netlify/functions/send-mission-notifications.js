import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — consommateur d'outbox Push privé.
// Entrée autorisée : uniquement un identifiant d'outbox provenant d'un
// Database Webhook Supabase signé par SECOTO_PUSH_WEBHOOK_SECRET.
import { createSign, timingSafeEqual } from "node:crypto";
import http2 from "node:http2";
import webpush from "web-push";
import { createClient } from "@supabase/supabase-js";

const {
  // ⚠ NE PAS « corriger » cette valeur en fr.secototransport.app.
  // Les deux plateformes n'ont PAS le même identifiant :
  //   iOS     PRODUCT_BUNDLE_IDENTIFIER = fr.secoto.app        (project.pbxproj,
  //           et bundle_identifier dans codemagic.yaml)
  //   Android applicationId             = fr.secototransport.app
  //   Capacitor appId                   = fr.secototransport.app (côté Android)
  // L'en-tete apns-topic doit valoir le bundle iOS, donc fr.secoto.app.
  // Y mettre l'identifiant Android provoquerait un 400 DeviceTokenNotForTopic,
  // classé « stale » plus bas, ce qui DÉSACTIVERAIT définitivement le token de
  // l'appareil dès le premier essai.
  APNS_BUNDLE_ID = "fr.secoto.app",
  APNS_KEY_ID,
  APNS_PRIVATE_KEY_BASE64,
  APNS_TEAM_ID,
  APNS_USE_SANDBOX,
  FIREBASE_SERVICE_ACCOUNT_JSON,
  SECOTO_PUSH_WEBHOOK_SECRET,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_URL,
  VAPID_PRIVATE_KEY,
  VAPID_PUBLIC_KEY,
  VAPID_SUBJECT = "mailto:contact.secoto@gmail.com",
} = process.env;

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED_SCREENS = new Set([
  "courses", "documents", "frais", "available", "assigned",
  "applications", "requests", "paiement", "transporters",
]);
let firebaseTokenCache = null;

function response(statusCode, body) {
  return {
    statusCode,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
    },
    body: JSON.stringify(body),
  };
}

export function secretMatches(received, expected) {
  if (!received || !expected) return false;
  const left = Buffer.from(received);
  const right = Buffer.from(expected);
  return left.length === right.length && timingSafeEqual(left, right);
}

function base64Url(value) {
  return Buffer.from(value).toString("base64url");
}

export function genericPushCopy(type) {
  const messages = {
    course_assigned: "Une mission SECOTO nécessite votre attention.",
    new_mission: "Une nouvelle mission SECOTO est disponible.",
    new_application: "Une nouvelle candidature est disponible dans SECOTO.",
    new_request: "Une nouvelle demande est disponible dans SECOTO.",
    tracking_update: "Le suivi d’une mission SECOTO a été mis à jour.",
    delivered: "Une livraison SECOTO vient d’être mise à jour.",
    frais: "Une action concernant des frais est disponible dans SECOTO.",
    frais_status: "Le statut d’un frais a été mis à jour.",
    document: "Un document SECOTO est disponible.",
    account: "Une action concernant votre compte SECOTO est disponible.",
    payment: "Un paiement SECOTO vient d’être encaissé.",
    payment_failed: "Un paiement SECOTO n’a pas abouti.",
    cancellation: "Une mission SECOTO a été annulée.",
    new_account: "Une nouvelle inscription attend une vérification dans SECOTO.",
    transporter_status: "Le statut d’un compte SECOTO a été mis à jour.",
  };
  return {
    title: "SECOTO",
    body: messages[type] || "Une nouvelle information est disponible dans SECOTO.",
  };
}

// ----------------------------------------------------------------------------
// Son de caisse enregistreuse.
// ----------------------------------------------------------------------------
// Il est réservé aux notifications qui représentent de l'argent, afin qu'il
// garde sa valeur de signal : entendre la caisse doit vouloir dire « il y a
// quelque chose à gagner », jamais « SECOTO a quelque chose à dire ».
//
//   transporteur : nouvelle course, mission attribuée, paiement reçu
//   admin        : paiement encaissé, nouvelle demande
//
// Toute autre notification (documents, suivi, frais, comptes) garde le son
// standard du téléphone.
// ----------------------------------------------------------------------------
export const CASH_SOUND_FILE = "secoto_cash_register.wav";
export const CASH_CHANNEL_ID = "secoto-cash-register-v1";
export const DEFAULT_CHANNEL_ID = "secoto-missions";

const CASH_EVENTS = {
  transporter: new Set(["new_course", "course_assigned", "payment"]),
  admin: new Set(["payment", "new_request"]),
};

export function isCashEvent(notification = {}) {
  const events = CASH_EVENTS[notification.audience];
  return Boolean(events && events.has(notification.type));
}

/**
 * @param notification ligne public.notifications (type + audience)
 * @param preferences  ligne public.notification_preferences du destinataire.
 *                     Absente = préférence par défaut, donc son de caisse actif.
 */
export function nativeNotificationPresentation(notification = {}, preferences = null) {
  const wantsCash = preferences?.cash_sound_enabled !== false;
  if (wantsCash && isCashEvent(notification)) {
    return {
      iosSound: CASH_SOUND_FILE,
      androidSound: CASH_SOUND_FILE.replace(/\.wav$/, ""),
      androidChannelId: CASH_CHANNEL_ID,
    };
  }
  return {
    iosSound: "default",
    androidSound: "default",
    androidChannelId: DEFAULT_CHANNEL_ID,
  };
}

export function notificationRoute(notification) {
  const screen = ALLOWED_SCREENS.has(notification.push_screen)
    ? notification.push_screen
    : notification.type === "document"
      ? "documents"
      : notification.type?.startsWith("frais")
        ? "frais"
        : notification.type?.startsWith("payment")
          ? "paiement"
          : "courses";
  const params = new URLSearchParams({ ecran: screen });
  if (notification.mission_id) params.set("mission", notification.mission_id);
  return `/?${params.toString()}`;
}

function parseFirebaseCredentials() {
  if (!FIREBASE_SERVICE_ACCOUNT_JSON) return null;
  try {
    const credentials = JSON.parse(FIREBASE_SERVICE_ACCOUNT_JSON);
    if (!credentials.client_email || !credentials.private_key || !credentials.project_id) return null;
    return credentials;
  } catch {
    return null;
  }
}

async function firebaseAccessToken() {
  if (firebaseTokenCache?.expiresAt > Date.now() + 60000) return firebaseTokenCache.value;
  const credentials = parseFirebaseCredentials();
  if (!credentials) throw new Error("FCM_NOT_CONFIGURED");
  const now = Math.floor(Date.now() / 1000);
  const signingInput = [
    base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" })),
    base64Url(JSON.stringify({
      iss: credentials.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    })),
  ].join(".");
  const signer = createSign("RSA-SHA256");
  signer.update(signingInput);
  signer.end();
  const assertion = `${signingInput}.${signer.sign(credentials.private_key, "base64url")}`;
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!tokenResponse.ok) throw new Error("FCM_AUTH_FAILED");
  const payload = await tokenResponse.json();
  firebaseTokenCache = {
    value: payload.access_token,
    expiresAt: Date.now() + Number(payload.expires_in || 3600) * 1000,
  };
  return firebaseTokenCache.value;
}

async function sendFcm(token, push, route, missionId, presentation) {
  const credentials = parseFirebaseCredentials();
  if (!credentials) throw new Error("FCM_NOT_CONFIGURED");
  const accessToken = await firebaseAccessToken();
  const result = await fetch(
    `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(credentials.project_id)}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: push.title, body: push.body },
          data: {
            screen: route.includes("ecran=") ? new URL(route, "https://app.secoto-transport.fr").searchParams.get("ecran") : "courses",
            missionId: missionId || "",
            url: route,
          },
          android: {
            priority: "high",
            notification: {
              channel_id: presentation.androidChannelId,
              sound: presentation.androidSound,
              notification_priority: "PRIORITY_HIGH",
              visibility: "PRIVATE",
              tag: missionId ? `mission-${missionId}` : "secoto",
            },
          },
        },
      }),
    },
  );
  if (result.ok) return;
  const body = await result.text();
  const error = new Error(`FCM_${result.status}`);
  error.stale = result.status === 404 || /UNREGISTERED|registration-token-not-registered/i.test(body);
  throw error;
}

function apnsProviderToken() {
  if (!APNS_KEY_ID || !APNS_TEAM_ID || !APNS_PRIVATE_KEY_BASE64) {
    throw new Error("APNS_NOT_CONFIGURED");
  }
  const now = Math.floor(Date.now() / 1000);
  const signingInput = [
    base64Url(JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID })),
    base64Url(JSON.stringify({ iss: APNS_TEAM_ID, iat: now })),
  ].join(".");
  const privateKey = Buffer.from(APNS_PRIVATE_KEY_BASE64, "base64").toString("utf8");
  const signer = createSign("SHA256");
  signer.update(signingInput);
  signer.end();
  const signature = signer.sign({ key: privateKey, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${signingInput}.${signature}`;
}

function sendApns(token, push, route, missionId, presentation) {
  const origin = APNS_USE_SANDBOX === "true"
    ? "https://api.sandbox.push.apple.com"
    : "https://api.push.apple.com";
  const providerToken = apnsProviderToken();
  return new Promise((resolve, reject) => {
    const client = http2.connect(origin);
    client.once("error", reject);
    const request = client.request({
      ":method": "POST",
      ":path": `/3/device/${encodeURIComponent(token)}`,
      authorization: `bearer ${providerToken}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-collapse-id": missionId ? `mission-${missionId}` : "secoto",
    });
    let status = 0;
    let responseBody = "";
    request.on("response", (headers) => { status = Number(headers[":status"] || 0); });
    request.once("error", (error) => {
      client.close();
      reject(error);
    });
    request.setEncoding("utf8");
    request.on("data", (chunk) => { responseBody += chunk; });
    request.on("end", () => {
      client.close();
      if (status === 200) {
        resolve();
        return;
      }
      const error = new Error(`APNS_${status}`);
      error.stale =
        status === 410 ||
        /BadDeviceToken|DeviceTokenNotForTopic|Unregistered/i.test(responseBody);
      reject(error);
    });
    request.end(JSON.stringify({
      aps: {
        alert: { title: push.title, body: push.body },
        sound: presentation.iosSound,
        badge: 1,
        "thread-id": missionId ? `mission-${missionId}` : "secoto",
      },
      screen: new URL(route, "https://app.secoto-transport.fr").searchParams.get("ecran") || "courses",
      missionId: missionId || "",
      url: route,
    }));
  });
}

async function sendWebPush(device, push, route, missionId) {
  if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) throw new Error("WEB_PUSH_NOT_CONFIGURED");
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
  try {
    await webpush.sendNotification(
      {
        endpoint: device.endpoint,
        keys: { p256dh: device.p256dh, auth: device.auth_secret },
      },
      JSON.stringify({
        title: push.title,
        body: push.body,
        url: route,
        missionId,
        tag: missionId ? `mission-${missionId}` : "secoto",
      }),
      { TTL: 300, urgency: "high" },
    );
  } catch (error) {
    error.stale = [404, 410].includes(error?.statusCode);
    throw error;
  }
}

async function sendToDevice(device, push, route, missionId, presentation) {
  if (device.provider === "fcm") {
    return sendFcm(device.token, push, route, missionId, presentation);
  }
  if (device.provider === "apns") {
    return sendApns(device.token, push, route, missionId, presentation);
  }
  if (device.provider === "webpush") return sendWebPush(device, push, route, missionId);
  throw new Error("UNKNOWN_PUSH_PROVIDER");
}

export const dispatchMissionNotifications = async (event) => {
  if (event.httpMethod !== "POST") return response(405, { error: "method_not_allowed" });
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !SECOTO_PUSH_WEBHOOK_SECRET) {
    return response(503, { error: "server_not_configured" });
  }
  const providedSecret =
    event.headers?.["x-secoto-push-secret"] ||
    event.headers?.["X-Secoto-Push-Secret"];
  if (!secretMatches(providedSecret, SECOTO_PUSH_WEBHOOK_SECRET)) {
    return response(401, { error: "unauthorized" });
  }

  let payload;
  try {
    payload = JSON.parse(event.body || "{}");
  } catch {
    return response(400, { error: "invalid_json" });
  }
  const outboxId = payload.outboxId || payload.record?.id;
  if (!UUID_PATTERN.test(outboxId || "")) return response(400, { error: "invalid_outbox_id" });

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: claimed, error: claimError } = await admin.rpc("secoto_claim_push_outbox", {
    p_outbox_id: outboxId,
  });
  if (claimError) return response(500, { error: "outbox_claim_failed" });
  const outbox = Array.isArray(claimed) ? claimed[0] : claimed;
  if (!outbox?.notification_id) return response(202, { skipped: true, reason: "already_claimed" });

  const { data: notification, error: notificationError } = await admin
    .from("notifications")
    .select("id,account_id,type,mission_id,push_screen,audience")
    .eq("id", outbox.notification_id)
    .single();
  if (notificationError || !notification) {
    await admin.rpc("secoto_complete_push_outbox", {
      p_outbox_id: outboxId,
      p_success: false,
      p_error: "notification_not_found",
    });
    return response(500, { error: "notification_not_found" });
  }

  const { data: devices, error: deviceError } = await admin
    .from("device_push_tokens")
    .select("id,provider,token,endpoint,p256dh,auth_secret")
    .eq("account_id", notification.account_id)
    .eq("is_active", true)
    .limit(100);
  if (deviceError) {
    await admin.rpc("secoto_complete_push_outbox", {
      p_outbox_id: outboxId,
      p_success: false,
      p_error: "device_query_failed",
    });
    return response(500, { error: "device_query_failed" });
  }

  const allTargets = devices || [];
  if (allTargets.length) {
    const { error: deliveryInsertError } = await admin
      .from("push_deliveries")
      .upsert(
        allTargets.map((device) => ({
          outbox_id: outboxId,
          device_token_id: device.id,
        })),
        {
          onConflict: "outbox_id,device_token_id",
          ignoreDuplicates: true,
        },
      );
    if (deliveryInsertError) {
      await admin.rpc("secoto_complete_push_outbox", {
        p_outbox_id: outboxId,
        p_success: false,
        p_error: "delivery_prepare_failed",
      });
      return response(500, { error: "delivery_prepare_failed" });
    }
  }

  const { data: deliveryRows, error: deliveryReadError } = await admin
    .from("push_deliveries")
    .select("id,device_token_id,status,attempts,max_attempts,available_at,updated_at")
    .eq("outbox_id", outboxId);
  if (deliveryReadError) {
    await admin.rpc("secoto_complete_push_outbox", {
      p_outbox_id: outboxId,
      p_success: false,
      p_error: "delivery_query_failed",
    });
    return response(500, { error: "delivery_query_failed" });
  }

  const deliveriesByDevice = new Map(
    (deliveryRows || []).map((delivery) => [delivery.device_token_id, delivery]),
  );
  const now = Date.now();
  const targets = allTargets
    .map((device) => ({ device, delivery: deliveriesByDevice.get(device.id) }))
    .filter(({ delivery }) => {
      if (!delivery || ["sent", "skipped", "failed"].includes(delivery.status)) return false;
      if (
        delivery.status === "processing"
        && Date.parse(delivery.updated_at || 0) > now - 10 * 60 * 1000
      ) return false;
      return Date.parse(delivery.available_at || 0) <= now;
    });

  const claimResults = await Promise.all(
    targets.map(({ delivery }) => admin
      .from("push_deliveries")
      .update({
        status: "processing",
        attempts: delivery.attempts + 1,
        updated_at: new Date().toISOString(),
      })
      .eq("id", delivery.id)
      .in("status", ["pending", "processing"])),
  );
  if (claimResults.some((result) => result.error)) {
    await admin.rpc("secoto_complete_push_outbox", {
      p_outbox_id: outboxId,
      p_success: false,
      p_error: "delivery_claim_failed",
    });
    return response(500, { error: "delivery_claim_failed" });
  }

  const push = genericPushCopy(notification.type);
  const route = notificationRoute(notification);

  // Le son de caisse est une préférence du destinataire. Une lecture absente
  // ou en erreur ne doit jamais empêcher l'envoi : on retombe alors sur la
  // valeur par défaut (son de caisse actif), comme pour un compte qui n'a
  // jamais ouvert l'écran Notifications.
  let preferences = null;
  if (isCashEvent(notification)) {
    const { data } = await admin
      .from("notification_preferences")
      .select("cash_sound_enabled")
      .eq("account_id", notification.account_id)
      .maybeSingle();
    preferences = data || null;
  }
  const presentation = nativeNotificationPresentation(notification, preferences);

  const results = await Promise.allSettled(
    targets.map(({ device }) =>
      sendToDevice(device, push, route, notification.mission_id, presentation)),
  );

  const staleIds = [];
  const errors = [];
  const deliveryUpdates = results.map((result, index) => {
    const { device, delivery } = targets[index];
    const attempts = delivery.attempts + 1;
    if (result.status === "fulfilled") {
      return admin.from("push_deliveries").update({
        status: "sent",
        sent_at: new Date().toISOString(),
        last_error: null,
        updated_at: new Date().toISOString(),
      }).eq("id", delivery.id);
    }

    const message = (result.reason?.message || "provider_failed").slice(0, 500);
    errors.push(message);
    if (result.reason?.stale) {
      staleIds.push(device.id);
      return admin.from("push_deliveries").update({
        status: "skipped",
        last_error: message,
        updated_at: new Date().toISOString(),
      }).eq("id", delivery.id);
    }

    return admin.from("push_deliveries").update({
      status: attempts >= delivery.max_attempts ? "failed" : "pending",
      available_at: new Date(
        Date.now() + Math.min(3600, (2 ** Math.max(attempts, 1)) * 15) * 1000,
      ).toISOString(),
      last_error: message,
      updated_at: new Date().toISOString(),
    }).eq("id", delivery.id);
  });
  const deliveryUpdateResults = await Promise.all(deliveryUpdates);
  if (deliveryUpdateResults.some((result) => result.error)) {
    errors.push("delivery_update_failed");
  }
  if (staleIds.length) {
    await admin
      .from("device_push_tokens")
      .update({ is_active: false, updated_at: new Date().toISOString() })
      .in("id", staleIds);
  }

  const sent = results.filter((result) => result.status === "fulfilled").length;
  // Un compte sans aucun appareil enregistré produisait jusqu'ici un « succès »
  // parfaitement silencieux : 0 envoi, 0 erreur, 0 trace. C'était la signature
  // exacte du bug « l'admin ne reçoit aucune notification ». On trace désormais
  // l'anomalie dans push_outbox.last_error, où elle est directement requêtable.
  if (allTargets.length === 0) {
    await admin.rpc("secoto_complete_push_outbox", {
      p_outbox_id: outboxId,
      p_success: true,
      p_error: "no_active_device_for_account",
    });
    return response(200, {
      sent: 0,
      attempted: 0,
      total: 0,
      stale: 0,
      pending: false,
      warning: "no_active_device_for_account",
    });
  }
  const { data: finalDeliveries, error: finalDeliveryError } = await admin
    .from("push_deliveries")
    .select("status,last_error")
    .eq("outbox_id", outboxId);
  const success = !finalDeliveryError && (
    allTargets.length === 0
    || (finalDeliveries || []).every((delivery) => ["sent", "skipped"].includes(delivery.status))
  );
  await admin.rpc("secoto_complete_push_outbox", {
    p_outbox_id: outboxId,
    p_success: success,
    p_error: finalDeliveryError
      ? "delivery_final_query_failed"
      : errors.length
        ? errors.slice(0, 3).join(",").slice(0, 500)
        : success
          ? null
          : "delivery_retry_pending",
  });
  return response(success ? 200 : 202, {
    sent,
    attempted: targets.length,
    total: allTargets.length,
    stale: staleIds.length,
    pending: !success,
  });
};

export default withLambda(dispatchMissionNotifications);

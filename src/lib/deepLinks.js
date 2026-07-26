const TRUSTED_WEB_HOSTS = new Set([
  "app.secoto-transport.fr",
  "www.app.secoto-transport.fr",
]);

export const ALLOWED_APP_SCREENS = Object.freeze([
  "courses",
  "documents",
  "frais",
  "available",
  "assigned",
  "applications",
  "requests",
  "profile",
  "contact",
]);

const MISSION_ID_PATTERN = /^[a-zA-Z0-9_-]{1,100}$/;

function cleanMissionId(value) {
  if (!value) return null;
  const candidate = String(value).trim();
  return MISSION_ID_PATTERN.test(candidate) ? candidate : null;
}

function screenFromParams(params) {
  const value = params.get("ecran") || params.get("screen") || "courses";
  return ALLOWED_APP_SCREENS.includes(value) ? value : "courses";
}

function paramsFromHash(url) {
  const raw = url.hash.startsWith("#") ? url.hash.slice(1) : url.hash;
  return new URLSearchParams(raw.startsWith("?") ? raw.slice(1) : raw);
}

export function parseSecotoDeepLink(rawUrl, currentOrigin = "https://app.secoto-transport.fr") {
  if (!rawUrl || typeof rawUrl !== "string") return null;

  let url;
  try {
    url = new URL(rawUrl, currentOrigin);
  } catch {
    return null;
  }

  const isNativeScheme = url.protocol === "secoto:";
  const isLocalOrigin =
    url.origin === currentOrigin &&
    (url.hostname === "localhost" || url.hostname === "127.0.0.1");
  const isTrustedWeb =
    (url.protocol === "https:" && (
      TRUSTED_WEB_HOSTS.has(url.hostname) || url.origin === currentOrigin
    )) ||
    (url.protocol === "http:" && isLocalOrigin);
  if (!isNativeScheme && !isTrustedWeb) return null;

  const route = `${url.hostname}${url.pathname}`.toLowerCase();
  const query = url.searchParams;
  const hash = paramsFromHash(url);
  const code = query.get("code") || hash.get("code");
  const authType = query.get("type") || hash.get("type");

  if (
    route.includes("auth/callback") ||
    query.get("auth") === "callback" ||
    code ||
    authType === "recovery"
  ) {
    return {
      kind: "auth",
      code: code || null,
      authType: authType || null,
    };
  }

  const missionId = cleanMissionId(query.get("mission") || query.get("missionId"));
  return {
    kind: "navigation",
    screen: screenFromParams(query),
    missionId,
  };
}

export function buildMissionPath(missionId, screen = "courses") {
  const safeMissionId = cleanMissionId(missionId);
  const safeScreen = ALLOWED_APP_SCREENS.includes(screen) ? screen : "courses";
  const params = new URLSearchParams({ ecran: safeScreen });
  if (safeMissionId) params.set("mission", safeMissionId);
  return `/?${params.toString()}`;
}

export function buildNativeAuthRedirect() {
  return "secoto://auth/callback";
}

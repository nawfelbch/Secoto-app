import { supabase } from "../supabaseClient";

const WEB_APP_URL = "https://app.secoto-transport.fr";
const PENDING_CLAIM_KEY = "secoto-pending-mission-claim-v2";
const MAX_PENDING_AGE_MS = 30 * 24 * 60 * 60 * 1000;

function firstRow(data) {
  return Array.isArray(data) ? data[0] : data;
}

function cleanToken(value) {
  const token = String(value || "").trim();
  return /^[A-Za-z0-9_-]{32,200}$/.test(token) ? token : "";
}

export function normalizeClaimCode(value) {
  const compact = String(value || "")
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "")
    .slice(0, 10);

  if (compact.length <= 4) return compact;
  if (compact.length <= 8) return `${compact.slice(0, 4)}-${compact.slice(4)}`;
  return `${compact.slice(0, 4)}-${compact.slice(4, 8)}-${compact.slice(8)}`;
}

function cleanCode(value) {
  const compact = normalizeClaimCode(value).replace(/-/g, "");
  return compact.length === 10 ? compact : "";
}

function cleanPublicRef(value) {
  const ref = String(value || "").trim().toUpperCase();
  return /^[A-Z0-9-]{4,60}$/.test(ref) ? ref : "";
}

function normalizeInvite(invite = {}) {
  const token = cleanToken(invite.token || invite.claimToken);
  const code = cleanCode(invite.code || invite.claimCode);
  const publicRef = cleanPublicRef(invite.publicRef || invite.ref);
  if (!token && !code) return null;

  return {
    token: token || "",
    code: code || "",
    publicRef: publicRef || "",
    savedAt: Date.now(),
  };
}

export function persistPendingMissionClaim(invite) {
  const normalized = normalizeInvite(invite);
  if (!normalized) return null;

  try {
    localStorage.setItem(PENDING_CLAIM_KEY, JSON.stringify(normalized));
  } catch {
    // Le lien reste exploitable pendant la session même sans stockage persistant.
  }
  return normalized;
}

function claimFromUrl() {
  if (typeof window === "undefined") return null;
  const params = new URLSearchParams(window.location.search);
  return normalizeInvite({
    token: params.get("claim"),
    code: params.get("claim_code"),
    publicRef: params.get("ref"),
  });
}

export function getPendingMissionClaim() {
  const fromUrl = claimFromUrl();
  if (fromUrl) return persistPendingMissionClaim(fromUrl);

  try {
    const raw = localStorage.getItem(PENDING_CLAIM_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!parsed?.savedAt || Date.now() - Number(parsed.savedAt) > MAX_PENDING_AGE_MS) {
      localStorage.removeItem(PENDING_CLAIM_KEY);
      return null;
    }
    return normalizeInvite(parsed);
  } catch {
    return null;
  }
}

export function clearPendingMissionClaim() {
  try {
    localStorage.removeItem(PENDING_CLAIM_KEY);
  } catch {
    // ignore
  }

  if (typeof window !== "undefined") {
    const url = new URL(window.location.href);
    url.searchParams.delete("claim");
    url.searchParams.delete("claim_code");
    url.searchParams.delete("ref");
    window.history.replaceState({}, "", `${url.pathname}${url.search}${url.hash}`);
  }
}

export async function createMissionClaimForAdmin(mission) {
  if (!mission?.id) throw new Error("Mission invalide.");

  const { data, error } = await supabase.rpc("secoto_generate_mission_claim_v2", {
    p_mission_id: mission.id,
    p_expires_in_days: 30,
  });
  if (error) throw error;

  const row = firstRow(data);
  if (!row?.token || !row?.access_code) {
    throw new Error("L'accès sécurisé du client n'a pas été généré.");
  }

  const publicRef = row.public_ref || mission.publicRef || "MISSION-SECOTO";
  const params = new URLSearchParams({
    claim: row.token,
    ref: publicRef,
  });

  return {
    missionId: mission.id,
    publicRef,
    accessCode: normalizeClaimCode(row.access_code),
    expiresAt: row.expires_at,
    url: `${WEB_APP_URL}/?${params.toString()}`,
  };
}

export async function claimMissionInvite(invite) {
  const normalized = normalizeInvite(invite);
  if (!normalized) throw new Error("Lien ou code SECOTO manquant.");

  const { data, error } = await supabase.rpc("secoto_claim_mission_v2", {
    p_token: normalized.token || null,
    p_code: normalized.code || null,
  });
  if (error) throw error;

  const row = firstRow(data);
  if (!row?.mission_id) throw new Error("Le transport n'a pas pu être ajouté.");
  return row;
}
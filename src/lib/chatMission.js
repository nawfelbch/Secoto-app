// SECOTO 142 — appels au chat client ↔ transporteur (fonctions SQL 142).
import { supabase } from "../supabaseClient";

async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data;
}

export const chatMessages = (missionId) => rpc("secoto_chat_messages", { p_mission: missionId });
export const chatEnvoyer = (missionId, texte) => rpc("secoto_chat_envoyer", { p_mission: missionId, p_texte: texte });
export const chatSignaler = (messageId) => rpc("secoto_chat_signaler", { p_message: messageId });
export const chatNonLus = () => rpc("secoto_chat_non_lus", {});

// Un seul appel partagé par toutes les cartes affichées (rafraîchi toutes les 30 s).
let cache = { at: 0, promesse: null };
export function chatNonLusPartage() {
  if (!cache.promesse || Date.now() - cache.at > 30000) {
    cache = { at: Date.now(), promesse: chatNonLus().catch(() => ({})) };
  }
  return cache.promesse;
}

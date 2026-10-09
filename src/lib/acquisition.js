// SECOTO 088 — Tableau d'acquisition et réseau (administrateur, lecture seule).
import { supabase } from "../supabaseClient";
import { humanizeError } from "./humanError";

async function rpc(name, args, fallback) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(humanizeError(error, fallback));
  return data;
}
export const acquisition = (debut, fin) =>
  rpc("secoto_admin_acquisition", { p_debut: debut, p_fin: fin }, "Le tableau d’acquisition n’a pas pu être chargé.");
export const reseau = () => rpc("secoto_admin_reseau", {}, "Les chiffres du réseau n’ont pas pu être chargés.");


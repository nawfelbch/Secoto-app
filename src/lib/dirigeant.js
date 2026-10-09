// SECOTO 087 — Espace dirigeant : appels à la base (lecture seule).
import { supabase } from "../supabaseClient";
import { humanizeError } from "./humanError";

async function rpc(name, args, fallback) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(humanizeError(error, fallback));
  return data;
}

/** L'onglet n'apparaît que si la base confirme l'accès (false en cas de doute). */
export async function dirigeantAcces() {
  const { data, error } = await supabase.rpc("secoto_dirigeant_acces");
  return error ? false : data === true;
}
export const dirigeantTableau = (annee = null) =>
  rpc("secoto_dirigeant_tableau", { p_annee: annee }, "Le tableau de bord n’a pas pu être chargé.");
export const dirigeantUrssaf = (debut, fin) =>
  rpc("secoto_dirigeant_urssaf", { p_debut: debut, p_fin: fin }, "La déclaration n’a pas pu être calculée.");
export const dirigeantLitiges = () =>
  rpc("secoto_dirigeant_litiges", {}, "Le suivi des litiges n’a pas pu être chargé.");

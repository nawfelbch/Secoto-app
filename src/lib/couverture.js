// SECOTO 088 — Couverture d'un transporteur : appels à la base.
import { supabase } from "../supabaseClient";
import { humanizeError } from "./humanError";

export async function couvertureStatut() {
  const { data, error } = await supabase.rpc("secoto_carrier_coverage_status");
  return error ? { required: false } : (data || { required: false });
}
export async function couvertureEnregistrer(zones, moto) {
  const { data, error } = await supabase.rpc("secoto_carrier_coverage_save", { p_zones: zones, p_moto: Boolean(moto) });
  if (error) throw new Error(humanizeError(error, "Vos départements n’ont pas pu être enregistrés."));
  return data;
}

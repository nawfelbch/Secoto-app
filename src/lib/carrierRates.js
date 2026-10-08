// SECOTO 085 — Barème déclaré par le transporteur (il fixe librement son prix).
import { supabase } from "../supabaseClient";
import { humanizeError } from "./humanError";
import { getPlatform } from "../platform/runtime";


/** En cas d'incident, on ne bloque personne : la fenêtre réapparaîtra. */
export async function carrierRatesStatus() {
  const { data, error } = await supabase.rpc("secoto_carrier_rates_status");
  if (error || !data) return { active: false, concerned: false, required: false };
  return data;
}

export async function saveCarrierRates(rates) {
  const { data, error } = await supabase.rpc("secoto_carrier_rates_save", { p_rates: rates, p_platform: getPlatform() });
  if (error) throw new Error(humanizeError(error, "Votre barème n’a pas pu être enregistré. Réessayez."));
  return data;
}

export { CLASS_LABEL, parseEuros, exampleTrip, formatEuros, sameAsDefaults } from "./carrierRatesUtil";

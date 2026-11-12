// SECOTO 133 — Types de véhicule du barème (sans dépendance : testable seul).

// Un barème par type de véhicule. La catégorie (class) reste celle que
// les transporteurs connaissent ; le gabarit choisit le barème.
export const GABARITS = [
  { value: "citadine", class: "voiture", label: "Citadine (Twingo, Clio, 208, Aygo…)" },
  { value: "berline", class: "voiture", label: "Berline / SUV compact (308, Golf, 3008…)" },
  { value: "grand", class: "voiture", label: "4x4 / grand SUV / monospace (X5, Grand Cherokee…)" },
  { value: "utilitaire", class: "utilitaire", label: "Utilitaire (Kangoo, Trafic, Boxer, Ducato…)" },
  { value: "moto", class: "moto", label: "Moto / scooter" },
  { value: "caravane", class: "autre", label: "Caravane" },
  { value: "camping_car", class: "autre", label: "Camping-car / van aménagé" },
  { value: "poids_lourd", class: "autre", label: "Bus, camion, poids lourd (sur devis)" },
];
export const GABARITS_DIMENSIONS = ["caravane", "camping_car"];
export function classeDuGabarit(gabarit) {
  return GABARITS.find((g) => g.value === gabarit)?.class || "voiture";
}
/** Message d'erreur si poids / dimensions manquent (caravane, camping-car), sinon "". */
export function erreurDimensions(v) {
  if (!GABARITS_DIMENSIONS.includes(v?.gabarit)) return "";
  const poids = Number(String(v.weight_kg ?? "").replace(",", "."));
  const longueur = Number(String(v.length_m ?? "").replace(",", "."));
  const hauteur = Number(String(v.height_m ?? "").replace(",", "."));
  if (!(poids >= 300 && poids <= 20000)) return "Indiquez le poids de votre caravane ou camping-car (en kg, carte grise : PTAC).";
  if (!(longueur >= 2 && longueur <= 20)) return "Indiquez la longueur totale (en mètres, flèche comprise).";
  if (!(hauteur >= 1 && hauteur <= 5)) return "Indiquez la hauteur (en mètres).";
  return "";
}


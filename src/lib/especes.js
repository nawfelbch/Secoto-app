// SECOTO 119 — course réglée en espèces : ce que le transporteur encaisse,
// puis le détail (sa part, la part SECOTO à reverser). Montants en centimes.

export function detailEspeces(totalCents, partTransporteurCents) {
  const total = Number.isFinite(Number(totalCents)) && totalCents !== null && totalCents !== undefined
    ? Math.round(Number(totalCents)) : null;
  const part = Number.isFinite(Number(partTransporteurCents)) && partTransporteurCents !== null && partTransporteurCents !== undefined
    ? Math.round(Number(partTransporteurCents)) : null;
  if (total === null) return { total: null, partTransporteur: part, partSecoto: null };
  // Sans la part transporteur (chauffeur d'une entreprise), seul le total s'affiche.
  if (part === null) return { total, partTransporteur: null, partSecoto: null };
  return { total, partTransporteur: Math.min(part, total), partSecoto: Math.max(total - part, 0) };
}

// Montants des missions en euros (numeric) → centimes.
export const eurosEnCentimes = (v) => (v === null || v === undefined || v === "" || Number.isNaN(Number(v)) ? null : Math.round(Number(v) * 100));

// Mesure de conversion (pixel OpenAI).
//
// Un seul point d'entree pour toute l'application : l'evenement ne part qu'une
// fois par paiement, jamais dans l'app iOS (ou le pixel n'est pas charge), et
// un echec de mesure ne doit jamais casser l'ecran qui le porte.

const CLE = "secoto:conversions-mesurees";

function dejaMesure(reference) {
  try {
    const vues = JSON.parse(window.localStorage.getItem(CLE) || "[]");
    if (vues.includes(reference)) return true;
    window.localStorage.setItem(CLE, JSON.stringify([...vues, reference].slice(-50)));
    return false;
  } catch {
    // Navigation privee, stockage bloque : on mesure, quitte a compter deux fois.
    return false;
  }
}

export function conversionCommande(reference) {
  try {
    if (!reference || typeof window === "undefined") return;
    if (typeof window.oaiq !== "function") return; // app iOS, ou pixel non charge
    if (dejaMesure(String(reference))) return;
    window.oaiq("measure", "order_created", { type: "contents" });
  } catch {
    // Jamais d'erreur remontee au client pour une question de mesure.
  }
}

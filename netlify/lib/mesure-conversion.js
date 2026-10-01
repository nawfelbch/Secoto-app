// SECOTO — mesure de conversion cote serveur (API Conversions OpenAI).
// ----------------------------------------------------------------------------
// Le pixel du navigateur ne voit pas tout : il est absent de l'app iOS, bloque
// par les bloqueurs de publicite, et muet si le client ferme l'onglet pendant
// le paiement. L'evenement part donc aussi d'ici, du webhook Stripe, c'est-a-dire
// d'un fait comptable et non d'une page ouverte.
//
// L'identifiant de l'evenement est l'identifiant du PAIEMENT, le meme que celui
// envoye par le navigateur : les deux envois decrivent le meme fait et ne
// doivent compter qu'une fois.
//
// Rien ici ne peut interrompre le webhook : une mesure ratee n'est pas un
// paiement rate, et Stripe doit recevoir son 200 dans tous les cas.

const PIXEL_ID = "QaUGD9H7HkVGbEFNafsha4";
const ENDPOINT = `https://bzr.openai.com/v1/events?pid=${PIXEL_ID}`;
const SOURCE_URL = "https://app.secoto-transport.fr/";
const DELAI_MS = 4000;

export async function mesurerConversion({ reference, horodatageMs } = {}) {
  const cle = process.env.OPENAI_PIXEL_API_KEY;
  if (!cle) return { envoye: false, raison: "cle_absente" };
  if (!reference) return { envoye: false, raison: "reference_absente" };

  // Interrupteur de test : aucun enregistrement cote OpenAI, la reponse dit
  // seulement si la requete serait acceptee.
  const validationSeule = process.env.OPENAI_PIXEL_VALIDATE_ONLY === "1";

  const corps = {
    validate_only: validationSeule,
    events: [
      {
        id: String(reference),
        type: "order_created",
        timestamp_ms: Number(horodatageMs) || Date.now(),
        source_url: SOURCE_URL,
        action_source: "web",
        data: { type: "contents" },
      },
    ],
  };

  try {
    const reponse = await fetch(ENDPOINT, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${cle}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(corps),
      signal: typeof AbortSignal?.timeout === "function" ? AbortSignal.timeout(DELAI_MS) : undefined,
    });
    const texte = await reponse.text().catch(() => "");
    // Journalise la reponse de l'API : c'est le seul moyen de diagnostiquer
    // depuis les journaux Netlify sans rejouer un paiement.
    console.log("[mesure] order_created", JSON.stringify({
      reference: String(reference),
      validate_only: validationSeule,
      http: reponse.status,
      reponse: texte.slice(0, 500),
    }));
    return { envoye: reponse.ok, http: reponse.status };
  } catch (erreur) {
    console.log("[mesure] echec reseau", String(erreur?.message || erreur));
    return { envoye: false, raison: "reseau" };
  }
}

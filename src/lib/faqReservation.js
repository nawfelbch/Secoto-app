import { cancellationPolicy, OFFER_WINDOW_HOURS, NO_PARTNER_REFUND_HOURS } from "./orderCopy.js";

// SECOTO 084 — Questions fréquentes affichées avant le paiement (voir
// ReassuranceReservation). Les réponses suivent le mode et le circuit réels.
export function questionsReservation({ mode = "plateau", circuit = null, relation = false } = {}) {
  const direct = circuit === "direct";
  // 100 : carte enregistrée à la réservation, règlement à la livraison.
  const arrivee = circuit === "arrivee";
  const plateau = mode === "plateau";
  const faq = [];
  faq.push({
    q: "Qui est SECOTO ?",
    r: plateau
      ? "SECOTO est une plateforme de mise en relation avec des transporteurs professionnels indépendants. Chaque compte transporteur est examiné et validé manuellement par SECOTO avant de recevoir des missions. Le transport est réalisé par le transporteur qui accepte votre demande, sous sa propre responsabilité."
      : "SECOTO organise votre convoyage : un convoyeur dont le compte a été validé par SECOTO conduit votre véhicule jusqu’à destination, avec un état des lieux photo au départ et à l’arrivée.",
  });
  faq.push({
    q: "Quand suis-je débité ?",
    r: arrivee
      ? "À la livraison seulement. À la réservation, votre carte est enregistrée en garantie auprès de Stripe : 0 € prélevé, aussi quand un transporteur accepte. Une fois le véhicule livré, vous réglez avec le mode choisi : carte (prélevée automatiquement), Klarna, virement ou espèces. Sans transporteur, la demande est annulée et rien n’est prélevé."
      : direct
      ? `Uniquement quand un transporteur accepte votre transport. À la réservation, votre carte est seulement validée : rien n’est prélevé. Si personne n’accepte sous ${OFFER_WINDOW_HOURS} h (ou avant la date d’enlèvement), votre demande est annulée sans aucun débit.`
      : `À la réservation, et le paiement reste en réserve. Si aucun transporteur n’accepte, vous êtes remboursé intégralement sous ${NO_PARTNER_REFUND_HOURS} h.`,
  });
  faq.push({
    q: "Mon paiement est-il sécurisé ?",
    r: direct
      ? "Oui. Le paiement passe par Stripe, l’un des leaders mondiaux du paiement en ligne : SECOTO ne voit jamais votre numéro de carte. Votre règlement va directement au transporteur, qui n’est versé qu’après la livraison."
      : "Oui. Le paiement passe par Stripe, l’un des leaders mondiaux du paiement en ligne : SECOTO ne voit jamais votre numéro de carte.",
  });
  faq.push({
    q: "Que se passe-t-il en cas de dommage ?",
    r: plateau
      ? "Le transport est exécuté sous la responsabilité du transporteur, avec ses propres assurances. SECOTO examine les attestations transmises par les transporteurs, mais ne garantit pas la couverture d’une mission précise. Un état des lieux avec photos est fait au départ et à l’arrivée : signalez tout dommage à la livraison, SECOTO vous accompagne dans la réclamation. Détails : « Comprendre nos vérifications »."
      : "Un état des lieux avec photos est fait au départ et à l’arrivée : signalez tout dommage à la livraison, SECOTO vous accompagne dans la réclamation. Détails : « Comprendre nos vérifications ».",
  });
  faq.push({
    q: "Qui sera mon interlocuteur ?",
    r: plateau && !relation
      ? "Le transporteur qui accepte votre transport : son nom s’affiche dans votre commande et vous suivez chaque étape dans l’application."
      : plateau
      ? "Votre transporteur. Dès qu’il accepte, son nom, son SIREN et son téléphone s’affichent dans votre commande, avec des boutons pour l’appeler ou lui écrire. Vous organisez directement avec lui l’enlèvement et la livraison. En cas de difficulté, le SAV SECOTO vous accompagne depuis l’application."
      : "Votre convoyeur pour le jour J, et SECOTO pour l’organisation. Vous suivez chaque étape dans l’application.",
  });
  faq.push({
    q: "Combien de temps pour trouver un transporteur ?",
    r: "Votre demande est envoyée en même temps à tous les transporteurs compatibles de votre secteur. Vous êtes prévenu immédiatement dès que l’un d’eux accepte, par notification et par e-mail.",
  });
  faq.push({ q: "Puis-je annuler ?", r: cancellationPolicy(arrivee ? { debit_a_livraison: true } : { payment_circuit: circuit }) });
  faq.push({
    q: "Que comprend le prix ?",
    r: direct
      ? "Le prix est tout compris : transport, chargement, carburant et péages. Il se compose du prix du transporteur et de la commission de mise en relation SECOTO, détaillés sous le prix. Aucun frais caché."
      : "Le prix est tout compris : transport, chargement, carburant et péages. Aucun frais caché.",
  });
  faq.push({
    q: "Vais-je recevoir une facture ?",
    r: "Oui, automatiquement, dans l’application et par e-mail.",
  });
  return faq;
}


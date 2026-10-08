import { NO_PARTNER_REFUND_HOURS } from "../lib/orderCopy";
import { questionsReservation } from "../lib/faqReservation";

// ============================================================================
// SECOTO 084 — Réserver en confiance.
// ----------------------------------------------------------------------------
// Toutes les réponses qu'un client venait chercher au téléphone, sur la page
// de prix, AVANT de payer : qui est SECOTO, quand il est débité, qui fait le
// transport, assurance, annulation, facture. Replié par défaut : rien ne gêne
// le bouton de réservation. Les textes suivent le circuit réel de la commande
// (paiement direct au transporteur ou ancien circuit) et le mode (plateau :
// mise en relation ; convoyage : SECOTO prestataire).
// ============================================================================

function Icone({ d }) {
  return (
    <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" fill="none" stroke="currentColor"
      strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d={d} />
    </svg>
  );
}
const BOUCLIER = "M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6l7-3zM9 12l2 2 4-4";
const CADENAS = "M7 11V8a5 5 0 0 1 10 0v3M6 11h12v9H6z";
const CARTE = "M3 7h18v10H3zM3 11h18";
const CAMION = "M3 7h11v8H3zM14 10h4l3 3v2h-7zM7 18a1.5 1.5 0 1 0 0-.1M17 18a1.5 1.5 0 1 0 0-.1";

export default function ReassuranceReservation({ mode = "plateau", circuit = null, relation = false, compact = false }) {
  const direct = circuit === "direct";
  const plateau = mode === "plateau";
  const garanties = [
    { icone: BOUCLIER, titre: plateau ? "Transporteurs vérifiés" : "Convoyeurs vérifiés", texte: "Registre des transporteurs et assurance contrôlés" },
    { icone: CADENAS, titre: "Paiement sécurisé", texte: "Par Stripe, votre carte n’est jamais vue par SECOTO" },
    direct
      ? { icone: CARTE, titre: "Aucun débit avant acceptation", texte: "Rien n’est prélevé tant qu’aucun transporteur n’accepte" }
      : { icone: CARTE, titre: "Remboursé si personne n’accepte", texte: `Intégralement, sous ${NO_PARTNER_REFUND_HOURS} h` },
    { icone: CAMION, titre: "État des lieux photo", texte: "Au départ et à l’arrivée, preuve en cas de litige" },
  ];
  const etapes = plateau
    ? [
      direct ? "Vous réservez : votre carte est validée, rien n’est débité." : "Vous réservez et réglez en ligne, en toute sécurité.",
      direct ? "Un transporteur professionnel accepte : vous êtes débité à ce moment-là, en son nom." : "Un transporteur professionnel accepte votre transport.",
      relation ? "Vous recevez ses coordonnées et échangez directement avec lui." : "Vous suivez chaque étape dans l’application.",
      "Enlèvement et livraison, avec état des lieux photo au départ et à l’arrivée.",
    ]
    : [
      "Vous réservez et réglez en ligne, en toute sécurité.",
      "Un convoyeur vérifié est désigné pour votre véhicule.",
      "Il conduit votre véhicule jusqu’à destination.",
      "État des lieux photo au départ et à l’arrivée.",
    ];

  return (
    <section className="od-confiance" aria-label="Réserver en confiance">
      <ul className="od-garanties">
        {garanties.map((g) => (
          <li key={g.titre}>
            <span className="od-garantie-icone"><Icone d={g.icone} /></span>
            <span><strong>{g.titre}</strong><small>{g.texte}</small></span>
          </li>
        ))}
      </ul>
      {!compact && (
        <>
          <details className="od-etapes">
            <summary>Comment ça se passe ?</summary>
            <ol>{etapes.map((e) => <li key={e}>{e}</li>)}</ol>
          </details>
          <details className="od-faq">
            <summary>Vos questions, nos réponses</summary>
            <div>
              {questionsReservation({ mode, circuit, relation }).map((x) => (
                <details key={x.q} className="od-faq-item">
                  <summary>{x.q}</summary>
                  <p>{x.r}</p>
                </details>
              ))}
            </div>
          </details>
        </>
      )}
    </section>
  );
}

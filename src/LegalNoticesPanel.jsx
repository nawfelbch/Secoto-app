import { useEffect, useState } from "react";
import { supabase } from "./supabaseClient";

// ============================================================================
// SECOTO — Mentions légales accessibles DANS l'application.
// ----------------------------------------------------------------------------
// Exigence App Store et Google Play : les conditions qui engagent le client
// (rétractation, commission, remboursement) doivent être consultables dans
// l'app, pas seulement sur le site. Les textes viennent de app_settings, donc
// modifiables sans redéployer ni resoumettre l'application.
// ============================================================================

export default function LegalNoticesPanel() {
  const [legal, setLegal] = useState(null);
  const [policy, setPolicy] = useState(null);

  useEffect(() => {
    let alive = true;
    supabase
      .from("app_settings")
      .select("key,value")
      .in("key", ["legal_texts", "cancellation_policy"])
      .then(({ data }) => {
        if (!alive) return;
        for (const row of data || []) {
          if (row.key === "legal_texts") setLegal(row.value);
          if (row.key === "cancellation_policy") setPolicy(row.value);
        }
      });
    return () => { alive = false; };
  }, []);

  const tiers = Array.isArray(policy?.convoyage) ? policy.convoyage : [];

  return (
    <div className="panel panel-full">
      <h2>Informations légales</h2>

      <div className="card-section">
        <h3>Deux activités distinctes</h3>
        <p>
          <strong>Convoyage automobile.</strong> SECOTO agit comme prestataire :
          un conducteur dédié achemine votre véhicule par la route. Le prix est
          fixé par le barème SECOTO et réglé en totalité à la livraison. Les
          véhicules ne sont jamais transportés par camion en convoyage.
        </p>
        <p>
          <strong>Transport par plateau ou moto.</strong> SECOTO agit comme
          intermédiaire de mise en relation. Le transporteur fixe librement son
          tarif ; SECOTO n’encaisse que sa commission de 20 %, réglée à la
          réservation. Le prix du transport est versé directement au
          transporteur et ne transite jamais par SECOTO.
        </p>
      </div>

      <div className="card-section">
        <h3>Frais de réservation (plateau / moto)</h3>
        <p>{legal?.commission_notice || "—"}</p>
        <p>{legal?.transport_notice || "—"}</p>
      </div>

      <div className="card-section">
        <h3>Droit de rétractation</h3>
        <p>
          Les clients particuliers disposent d’un droit de rétractation de
          14 jours. Pour une réservation de créneau, l’exécution étant immédiate,
          ce droit ne peut être exercé qu’à la condition d’avoir été expressément
          conservé : la case de renonciation n’est jamais cochée à votre place.
        </p>
        <p>{legal?.waiver_execution || "—"}</p>
        <p>{legal?.waiver_withdrawal || "—"}</p>
        <p className="muted">
          Les clients professionnels ne bénéficient pas de ce droit, réservé aux
          consommateurs.
        </p>
        <p>
          En convoyage, le droit de rétractation reste ouvert jusqu’à
          l’exécution de la mission.
        </p>
      </div>

      <div className="card-section">
        <h3>Annulation et remboursement</h3>
        <p>{legal?.refund_policy || "—"}</p>
        {tiers.length > 0 && (
          <>
            <p><strong>Barème d’annulation applicable au convoyage :</strong></p>
            <ul>
              {tiers.map((tier) => (
                <li key={tier.hours_before}>
                  Annulation à moins de {tier.hours_before} h du départ :{" "}
                  {tier.fee_pct} % du montant de la mission.
                </li>
              ))}
            </ul>
            <p className="muted">
              Cette indemnité couvre le préjudice propre à SECOTO en tant que
              prestataire. Elle ne s’applique pas au transport par plateau, où
              SECOTO n’est qu’intermédiaire.
            </p>
          </>
        )}
      </div>

      <div className="card-section">
        <h3>Éditeur</h3>
        <p>
          SECOTO — micro-entrepreneur · SIREN 951 857 531 · code APE 8299Z.
          <br />
          TVA non applicable, article 293 B du CGI.
          <br />
          contact.secoto@gmail.com
        </p>
      </div>
    </div>
  );
}

import { useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import { currentLegalCopy } from "./lib/legalCopy";

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

  const copy = currentLegalCopy(legal);
  const tiers = Array.isArray(policy?.convoyage) ? policy.convoyage : [];

  function cancellationLabel(tier) {
    const hours = Number(tier.hours_before);
    if (hours <= 0) return "À partir de l’heure prévue du départ";
    if (hours <= 24) return "À moins de 24 h du départ";
    return "Plus de 24 h avant le départ";
  }

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
        <p>{copy.commission_notice}</p>
        <p>{copy.transport_notice}</p>
      </div>

      <div className="card-section">
        <h3>Droit de rétractation</h3>
        <p>
          Pour les contrats de service conclus à distance, les consommateurs
          disposent en principe d’un délai de rétractation de 14 jours à compter
          de la conclusion du contrat, sous réserve des exceptions légales.
        </p>
        <p>
          Si vous demandez le début de la prestation avant la fin de ce délai,
          votre demande expresse est recueillie sans case précochée. En cas de
          rétractation avant l’exécution complète, le montant dû correspond au
          service déjà fourni. Le droit n’est perdu qu’après l’exécution complète,
          lorsque les conditions légales sont réunies.
        </p>
        <p>{copy.waiver_execution}</p>
        <p>{copy.waiver_withdrawal}</p>
        <p className="muted">
          Ce droit est réservé aux consommateurs. Certaines protections peuvent
          toutefois s’étendre aux professionnels dans les cas prévus par l’article
          L. 221-3 du Code de la consommation.
        </p>
        <p>
          Pour le convoyage, les conditions applicables sont précisées avant la
          validation, selon la nature et la date de la prestation.
        </p>
      </div>

      <div className="card-section">
        <h3>Annulation et remboursement</h3>
        <p>{copy.refund_policy}</p>
        {tiers.length > 0 && (
          <>
            <p><strong>Barème d’annulation applicable au convoyage :</strong></p>
            <ul>
              {tiers.map((tier) => (
                <li key={tier.hours_before}>
                  {cancellationLabel(tier)} :{" "}
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

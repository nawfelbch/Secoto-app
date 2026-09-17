import { useCallback, useEffect, useState } from "react";
import {
  acceptExtension, acceptProposal, declineProposal, formatCents, formatDateTime,
  historyRows, replaceHistoryRows, requestExtension, saveQuestionnaire,
  startEligibility, startSubscriptionCheckout, submitEligibility, subscriptionOverview, uploadEligibilityFile,
  departmentsFromText, VEHICLE_CLASSES,
} from "../lib/onDemand";
import { payNow } from "../lib/payments";
import { MAX_ROWS, TEMPLATE_COLUMNS, checkRow, markDuplicates, readHistoryFile, rowsForServer, templateCsv } from "../lib/historyImport";

const STATUS_TEXT = {
  draft: "Dossier en cours de préparation.",
  submitted: "Dossier transmis. SECOTO étudie votre activité.",
  under_review: "Dossier en cours d’étude par SECOTO.",
  needs_correction: "SECOTO demande un complément avant de poursuivre l’étude.",
  proposal_sent: "Une proposition personnalisée vous attend.",
  accepted: "Proposition acceptée.",
  rejected: "Dossier non retenu.",
};

function downloadBlob(content, filename, type) {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

export default function SubscriptionPanel({ flags }) {
  const [overview, setOverview] = useState(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [company, setCompany] = useState({ name: "", siren: "" });
  const [answers, setAnswers] = useState(null);
  const [rows, setRows] = useState([]);
  const [importInfo, setImportInfo] = useState(null);
  const [extension, setExtension] = useState({ category: "convoyage:voiture", quantity: 1, extra_km: 0, note: "" });

  const load = useCallback(async () => {
    try {
      const data = await subscriptionOverview();
      setOverview(data);
      if (data.application?.questionnaire && Object.keys(data.application.questionnaire).length) setAnswers(data.application.questionnaire);
      if (data.application?.id) {
        const existing = await historyRows(data.application.id).catch(() => null);
        if (existing?.rows?.length) {
          setRows(existing.rows.map((r, i) => ({
            line: i + 2, date: r.trip_date || "", from: r.from_label || "", to: r.to_label || "",
            distance_km: r.distance_km ?? "", vehicle: r.vehicle || "", mode: r.mode || "",
            requested_delay_hours: r.requested_delay_hours ?? "", amount_eur: r.amount_cents != null ? String(r.amount_cents / 100) : "",
            fees_eur: r.fees_cents != null ? String(r.fees_cents / 100) : "", receipt_ref: r.receipt_ref || "",
            issues: (r.issues || []).map((x) => x.replace(/_/g, " ")),
          })));
        }
      }
      setError("");
    } catch (e) {
      setError(e.message);
    }
  }, []);
  useEffect(() => { queueMicrotask(load); }, [load]);

  async function run(work, successMessage) {
    setBusy(true); setError(""); setMessage("");
    try {
      await work();
      if (successMessage) setMessage(successMessage);
      await load();
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  if (!flags?.subscriptions) {
    return (
      <div className="panel panel-full">
        <h2>Abonnement professionnel</h2>
        <p className="muted">L’étude d’éligibilité n’est pas encore ouverte. Contactez SECOTO pour être prévenu de son ouverture.</p>
      </div>
    );
  }
  if (!overview) return <div className="panel panel-full"><h2>Abonnement professionnel</h2><p className="muted">Chargement…</p>{error && <div className="alert error">{error}</div>}</div>;

  const application = overview.application;
  const editable = application && ["draft", "needs_correction"].includes(application.status);
  const proposal = (overview.proposals || []).find((p) => p.status === "sent");
  const subscription = overview.subscription;
  const usage = overview.usage;
  const errorsCount = rows.filter((r) => r.issues?.some((i) => !/doublon|Doublon/.test(i))).length;

  return (
    <div className="panel panel-full">
      <h2>Abonnement professionnel personnalisé</h2>
      {error && <div className="alert error" role="alert">{error}</div>}
      {message && <div className="alert success" role="status">{message}</div>}

      {!application && (
        <>
          <p>Pour les entreprises qui déplacent des véhicules régulièrement, SECOTO étudie votre activité réelle et construit un forfait sur mesure : volumes, zones, délais et modes de transport qui correspondent à vos besoins, avec une capacité de prise en charge réservée.</p>
          <p className="muted">L’éligibilité est décidée après analyse de votre dossier : le forfait n’est pas ouvert automatiquement.</p>
          <div className="form-grid">
            <label className="field"><span>Raison sociale *</span><input value={company.name} onChange={(e) => setCompany({ ...company, name: e.target.value })} /></label>
            <label className="field"><span>SIREN</span><input value={company.siren} inputMode="numeric" maxLength={11} onChange={(e) => setCompany({ ...company, siren: e.target.value })} /></label>
          </div>
          <button className="btn primary" type="button" disabled={busy || company.name.trim().length < 2}
            onClick={() => run(() => startEligibility(company.name.trim(), company.siren.replace(/\s/g, "")), "Dossier créé.")}>
            Vérifier l’éligibilité de mon entreprise
          </button>
        </>
      )}

      {application && (
        <>
          <p><span className={`od-pill ${application.status === "proposal_sent" ? "is-ok" : application.status === "rejected" ? "is-bad" : "is-warn"}`}>{STATUS_TEXT[application.status] || application.status}</span></p>
          {application.review_note && <div className="alert">{application.review_note}</div>}
        </>
      )}

      {editable && (
        <>
          <h3>1. Votre activité</h3>
          <QuestionnaireForm value={answers} onChange={setAnswers} />
          <button className="btn ghost small" type="button" disabled={busy || !answers}
            onClick={() => run(() => saveQuestionnaire(application.id, {
              ...answers,
              zones: departmentsFromText(answers.zonesText || (answers.zones || []).join(",")),
              trips_per_month: Number(answers.trips_per_month),
              typical_km: Number(answers.typical_km),
              max_km: Number(answers.max_km),
            }), "Questionnaire enregistré.")}>Enregistrer le questionnaire</button>

          <h3 style={{ marginTop: 20 }}>2. Historique des trois derniers mois</h3>
          <p className="muted">Importez un fichier .xlsx ou .csv. Les formules et macros ne sont jamais exécutées : seules les valeurs sont lues, puis vérifiées.</p>
          <div className="actions-row">
            <button className="btn ghost small" type="button" onClick={() => downloadBlob(templateCsv(), "secoto-historique-transports.csv", "text/csv;charset=utf-8")}>Modèle CSV</button>
            <a className="btn ghost small" href="/modeles/secoto-historique-transports.xlsx" download>Modèle Excel</a>
            <label className="btn primary small">
              Importer un fichier
              <input type="file" accept=".csv,.xlsx,text/csv" className="visually-hidden-file" onChange={async (e) => {
                const file = e.target.files?.[0];
                e.target.value = "";
                if (!file) return;
                setBusy(true); setError(""); setMessage("");
                try {
                  const result = await readHistoryFile(file);
                  setRows(result.rows);
                  setImportInfo(result);
                  await uploadEligibilityFile({ businessId: overview.business.id, applicationId: application.id, file, kind: "history" }).catch(() => null);
                } catch (e2) { setError(e2.message); } finally { setBusy(false); }
              }} />
            </label>
            <label className="btn ghost small">
              Ajouter un justificatif
              <input type="file" accept=".pdf,image/jpeg,image/png" className="visually-hidden-file" onChange={async (e) => {
                const file = e.target.files?.[0];
                e.target.value = "";
                if (!file) return;
                run(() => uploadEligibilityFile({ businessId: overview.business.id, applicationId: application.id, file, kind: "receipt" }), "Justificatif transmis.");
              }} />
            </label>
          </div>
          {importInfo?.missingColumns?.length > 0 && <div className="alert error">Colonnes manquantes : {importInfo.missingColumns.join(", ")}. Utilisez le modèle.</div>}
          {importInfo?.truncated && <div className="alert error">Fichier tronqué : seules les {MAX_ROWS} premières lignes ont été lues.</div>}
          {importInfo?.formulaCells > 0 && <div className="alert">{importInfo.formulaCells} cellule(s) contenaient une formule : la valeur enregistrée dans le fichier a été lue, jamais recalculée. Vérifiez-les.</div>}
          {rows.length > 0 && (
            <>
              <p>{rows.length} ligne(s) · {errorsCount} à corriger.</p>
              <div className="od-scroll">
                <table className="od-table">
                  <thead><tr>{TEMPLATE_COLUMNS.map((c) => <th key={c.key}>{c.header}</th>)}<th>Contrôles</th></tr></thead>
                  <tbody>
                    {rows.slice(0, 200).map((row, index) => (
                      <tr key={row.line || index} className={row.issues?.length ? (row.issues.every((i) => /oublon/.test(i)) ? "is-warning" : "is-error") : ""}>
                        {TEMPLATE_COLUMNS.map((c) => (
                          <td key={c.key}>
                            <input value={row[c.key] ?? ""} aria-label={`${c.header} ligne ${row.line}`} onChange={(e) => {
                              const next = [...rows];
                              const updated = { ...row, [c.key]: e.target.value };
                              updated.issues = checkRow(updated);
                              next[index] = updated;
                              setRows(markDuplicates(next));
                            }} />
                          </td>
                        ))}
                        <td>{row.issues?.length ? row.issues.join(" · ") : "OK"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {rows.length > 200 && <p className="muted">200 premières lignes affichées ; toutes seront transmises.</p>}
              <div className="actions-row">
                <button className="btn ghost small" type="button" disabled={busy}
                  onClick={() => run(() => replaceHistoryRows(application.id, rowsForServer(rows)), "Historique enregistré.")}>Enregistrer l’historique</button>
                <button className="btn primary small" type="button" disabled={busy || errorsCount > 0}
                  onClick={() => run(async () => {
                    await replaceHistoryRows(application.id, rowsForServer(rows));
                    await submitEligibility(application.id);
                  }, "Dossier transmis à SECOTO.")}>Transmettre mon dossier</button>
                {errorsCount > 0 && <small className="muted">Corrigez les {errorsCount} ligne(s) signalées avant de transmettre.</small>}
              </div>
            </>
          )}
        </>
      )}

      {proposal && (
        <div className="applications-box">
          <h3>Proposition personnalisée (version {proposal.version})</h3>
          <div className="od-price"><span>Mensualité</span><strong>{formatCents(proposal.monthly_price_cents)}</strong></div>
          <ul className="od-lines">
            {(proposal.allowances || []).map((a) => <li key={a.category}><span>{a.category.replace(":", " · ")}</span><span>{a.quantity} transport(s) / mois</span></li>)}
            <li><span>Plafond kilométrique mensuel</span><span>{proposal.km_cap_total} km</span></li>
            <li><span>Distance maximale par trajet</span><span>{proposal.max_km_per_trip} km</span></li>
            <li><span>Zones couvertes</span><span>{(proposal.zones || []).join(", ")}</span></li>
            <li><span>Modes couverts</span><span>{(proposal.modes || []).join(", ")}</span></li>
            <li><span>Délai de prévenance</span><span>{proposal.lead_time_hours} h</span></li>
            <li><span>Préavis d’annulation</span><span>{proposal.cancellation_notice_hours} h</span></li>
          </ul>
          <p><strong>Inclus :</strong> {proposal.included_fees}</p>
          <p><strong>Exclusions :</strong> {proposal.exclusions}</p>
          <p><strong>Report :</strong> {proposal.carry_over_rule}</p>
          <p><strong>Annulation :</strong> {proposal.cancellation_rule}</p>
          <p><strong>Résiliation :</strong> {proposal.termination_rule}</p>
          <p className="muted">Prise d’effet le {new Date(proposal.effective_date).toLocaleDateString("fr-FR")} · proposition valable jusqu’au {new Date(proposal.valid_until).toLocaleDateString("fr-FR")}.</p>
          <div className="actions-row">
            <button className="btn primary" type="button" disabled={busy} onClick={() => run(() => acceptProposal(proposal.id), "Proposition acceptée.")}>Accepter</button>
            <button className="btn ghost" type="button" disabled={busy} onClick={() => run(() => declineProposal(proposal.id), "Proposition déclinée.")}>Décliner</button>
          </div>
        </div>
      )}

      {subscription && (
        <div className="applications-box">
          <h3>Mon forfait</h3>
          <p><span className={`od-pill ${subscription.status === "active" ? "is-ok" : subscription.status === "pending_payment" ? "is-warn" : "is-bad"}`}>
            {{ pending_payment: "Paiement à mettre en place", active: "Actif", past_due: "Prélèvement en échec", suspended: "Suspendu", cancelled: "Résilié", expired: "Terminé" }[subscription.status]}
          </span>{subscription.current_period_end ? ` · période en cours jusqu’au ${formatDateTime(subscription.current_period_end)}` : ""}</p>
          {subscription.status === "pending_payment" && (
            <button className="btn primary" type="button" disabled={busy} onClick={() => run(async () => {
              const { checkoutUrl } = await startSubscriptionCheckout(subscription.id);
              if (checkoutUrl) window.location.assign(checkoutUrl);
            })}>Mettre en place le paiement mensuel</button>
          )}
          {["past_due", "suspended"].includes(subscription.status) && (
            <div className="alert error">Le dernier prélèvement n’a pas abouti. Les nouvelles réservations sur forfait sont suspendues ; les missions déjà confirmées ne sont pas affectées. Régularisez depuis l’e-mail de facture Stripe, ou contactez SECOTO.</div>
          )}
          {usage && (
            <div className="od-usage">
              {(usage.categories || []).map((c) => (
                <article key={c.category}>
                  <strong>{c.category.replace(":", " · ")}</strong>
                  <dl>
                    <dt>Disponibles</dt><dd>{c.available}</dd>
                    <dt>Réservés</dt><dd>{c.reserved}</dd>
                    <dt>Consommés</dt><dd>{c.consumed}</dd>
                    <dt>Inclus / mois</dt><dd>{c.included}</dd>
                  </dl>
                </article>
              ))}
              <article>
                <strong>Kilomètres</strong>
                <dl>
                  <dt>Plafond</dt><dd>{usage.km?.cap} km</dd>
                  <dt>Réservés</dt><dd>{Math.round(usage.km?.reserved || 0)} km</dd>
                  <dt>Consommés</dt><dd>{Math.round(usage.km?.consumed || 0)} km</dd>
                </dl>
              </article>
            </div>
          )}
          {subscription.status === "active" && (
            <>
              <h4 style={{ marginTop: 16 }}>Demander une extension de mon forfait</h4>
              <p className="muted">Hors forfait, aucun supplément n’est appliqué automatiquement : SECOTO vous transmet un prix, que vous acceptez avant tout engagement.</p>
              <div className="od-inline-form">
                <label className="field"><span>Catégorie</span>
                  <select value={extension.category} onChange={(e) => setExtension({ ...extension, category: e.target.value })}>
                    {["convoyage", "plateau"].flatMap((m) => VEHICLE_CLASSES.map((c) => `${m}:${c.value}`)).map((v) => <option key={v} value={v}>{v.replace(":", " · ")}</option>)}
                  </select>
                </label>
                <label className="field"><span>Transports</span><input type="number" min="1" max="200" value={extension.quantity} onChange={(e) => setExtension({ ...extension, quantity: Number(e.target.value) })} /></label>
                <label className="field"><span>Km supplémentaires</span><input type="number" min="0" max="50000" value={extension.extra_km} onChange={(e) => setExtension({ ...extension, extra_km: Number(e.target.value) })} /></label>
                <button className="btn ghost small" type="button" disabled={busy}
                  onClick={() => run(() => requestExtension(subscription.id, extension.category, extension.quantity, extension.extra_km, extension.note), "Demande transmise à SECOTO.")}>Demander un prix</button>
              </div>
              {(overview.extensions || []).filter((e) => ["requested", "priced", "accepted", "active"].includes(e.status)).map((e) => (
                <div className="alert" key={e.id}>
                  {e.category.replace(":", " · ")} × {e.quantity}{e.extra_km ? ` + ${e.extra_km} km` : ""} —{" "}
                  {e.status === "requested" && "en cours de chiffrage par SECOTO."}
                  {e.status === "priced" && (
                    <>
                      {formatCents(e.price_cents)} · offre valable jusqu’au {formatDateTime(e.offer_valid_until)}
                      <div className="actions-row">
                        <button className="btn primary small" type="button" disabled={busy} onClick={() => run(async () => {
                          const r = await acceptExtension(e.id);
                          await payNow(r.payment_id);
                        }, "Extension acceptée : finalisez le paiement.")}>Accepter et payer</button>
                      </div>
                    </>
                  )}
                  {e.status === "accepted" && (
                    <>paiement à finaliser. <button className="btn primary small" type="button" disabled={busy} onClick={() => run(() => payNow(e.payment_id))}>Payer</button></>
                  )}
                  {e.status === "active" && "extension active sur la période en cours."}
                </div>
              ))}
            </>
          )}
        </div>
      )}
    </div>
  );
}

function QuestionnaireForm({ value, onChange }) {
  const v = value || { trips_per_month: "", zonesText: "", typical_km: "", max_km: "", vehicle_classes: [], modes: [], lead_time: "48h", constraints: "", seasonality: "" };
  const set = (patch) => onChange({ ...v, ...patch });
  const toggle = (list, item) => (list.includes(item) ? list.filter((x) => x !== item) : [...list, item]);
  return (
    <div className="form-grid">
      <label className="field"><span>Transports par mois *</span><input type="number" min="1" max="2000" value={v.trips_per_month} onChange={(e) => set({ trips_per_month: e.target.value })} /></label>
      <label className="field"><span>Départements desservis *</span><input value={v.zonesText ?? (v.zones || []).join(", ")} placeholder="75, 92, 69" onChange={(e) => set({ zonesText: e.target.value })} /></label>
      <label className="field"><span>Distance habituelle (km) *</span><input type="number" min="1" max="3000" value={v.typical_km} onChange={(e) => set({ typical_km: e.target.value })} /></label>
      <label className="field"><span>Distance maximale (km) *</span><input type="number" min="1" max="3000" value={v.max_km} onChange={(e) => set({ max_km: e.target.value })} /></label>
      <fieldset className="field"><span>Véhicules *</span>
        <div className="od-checks">{VEHICLE_CLASSES.map((c) => (
          <label key={c.value}><input type="checkbox" checked={(v.vehicle_classes || []).includes(c.value)} onChange={() => set({ vehicle_classes: toggle(v.vehicle_classes || [], c.value) })} />{c.label}</label>
        ))}</div>
      </fieldset>
      <fieldset className="field"><span>Modes *</span>
        <div className="od-checks">{["convoyage", "plateau"].map((m) => (
          <label key={m}><input type="checkbox" checked={(v.modes || []).includes(m)} onChange={() => set({ modes: toggle(v.modes || [], m) })} />{m}</label>
        ))}</div>
      </fieldset>
      <label className="field"><span>Délai habituel *</span>
        <select value={v.lead_time} onChange={(e) => set({ lead_time: e.target.value })}>
          <option value="24h">Sous 24 h</option><option value="48h">Sous 48 h</option><option value="semaine">Dans la semaine</option><option value="flexible">Flexible</option>
        </select>
      </label>
      <label className="field field-full"><span>Contraintes particulières</span><textarea rows={2} maxLength={1000} value={v.constraints} onChange={(e) => set({ constraints: e.target.value })} /></label>
      <label className="field field-full"><span>Saisonnalité</span><textarea rows={2} maxLength={1000} value={v.seasonality} onChange={(e) => set({ seasonality: e.target.value })} placeholder="Pics d’activité, périodes creuses…" /></label>
    </div>
  );
}

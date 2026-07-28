import { useEffect, useMemo, useRef, useState } from "react";
import { supabase } from "./supabaseClient";
import {
  emptyMissionForm,
  TRANSPORTER_TYPES,
  accountFromDb,
  missionFromDb,
  publicMissionFromDb,
  applicationFromDb,
  documentFromDb,
  trackingEventFromDb,
  trackingPhotoFromDb,
  requestFromDb,
  notificationFromDb,
  missionToDb,
  requestToDb,
  labelTransporterType,
  labelTrackingEventType,
  labelFuelLevel,
  labelStatus,
  labelMissionType,
  labelProgress,
  formatDateTime,
} from "./lib/mappers";
import {
  disablePush,
  enablePush,
  initializePushListeners,
  pushSupported,
} from "./push";
import { computeClientPrice, computeCarrierPay, computeMargin, formatAmount } from "./lib/pricing";
import {
  normalizePublicSignupMetadata,
  progressFromTrackingEvent,
} from "./lib/domainPolicy";
import {
  getAuthRedirectUrl,
  getServerFunctionUrl,
  getOneTimeLocation,
  initializePlatform,
  openExternal,
  openRoute,
  shareOrOpen,
} from "./platform/runtime";
import {
  buildPrivateFilePath,
  randomIdempotencyKey,
  validateFiles,
} from "./lib/fileSafety";
import {
  createShortSignedUrl,
  hydrateSignedFileUrls,
  uploadPrivateFile,
} from "./lib/privateFiles";
import {
  clearEncryptedAccountData,
  listPendingActions,
  listTrackingDrafts,
  queueTrackingAction,
  removeEncryptedRecord,
  removeTrackingDraft,
  saveTrackingDraft,
} from "./lib/resilienceStore";
import FraisPanel from "./FraisPanel";
import AddressAutocomplete from "./AddressAutocomplete";
import ContactPanel from "./ContactPanel";
import ClientsPanel from "./ClientsPanel";
import DocumentModal from "./DocumentModal";
import MyDocumentsPanel from "./MyDocumentsPanel";
import SecureFilePicker from "./SecureFilePicker";
import { emitMissionDocuments, emitFacture, syncDocTemplates } from "./lib/docFlow";
import "./index.css";

/* ============================================================
   Petits composants UI
============================================================ */

// Libellés des documents générés (suivi côté admin).
const DOC_LABEL_FR = {
  devis: "Devis",
  bon_de_mission: "Bon de mission",
  facture: "Facture",
};

const DATA_PAGE_SIZE = 200;
const MISSION_ADMIN_COLUMNS = [
  "id", "public_ref", "type", "status", "progress_status", "from_city", "to_city",
  "pickup_address", "delivery_address", "mission_date", "vehicle", "plate",
  "distance_km", "carrier_cost", "client_price", "carrier_pay", "margin",
  "client_name", "client_contact", "client_phone", "price_mode", "proposed_price",
  "payment_method", "notes", "created_by_role", "client_account_id",
  "assigned_transporter_id", "assigned_transporter_name", "source_request_id", "created_at",
].join(",");
const MISSION_CLIENT_COLUMNS = [
  "id", "public_ref", "type", "status", "progress_status", "from_city", "to_city",
  "pickup_address", "delivery_address", "mission_date", "vehicle", "plate",
  "distance_km", "client_price", "client_name", "client_contact", "client_phone",
  "price_mode", "proposed_price", "payment_method", "notes", "created_by_role",
  "client_account_id", "assigned_transporter_id", "assigned_transporter_name",
  "source_request_id", "created_at",
].join(",");
const MISSION_TRANSPORTER_COLUMNS = [
  "id", "public_ref", "type", "status", "progress_status", "from_city", "to_city",
  "pickup_address", "delivery_address", "mission_date", "vehicle", "plate",
  "distance_km", "carrier_cost", "carrier_pay", "client_name", "client_contact",
  "client_phone", "payment_method", "notes", "assigned_transporter_id",
  "assigned_transporter_name", "created_at",
].join(",");
const PUBLIC_MISSION_COLUMNS = [
  "id", "public_ref", "type", "status", "progress_status", "from_city", "to_city",
  "vehicle", "distance_km", "created_at",
].join(",");
const APPLICATION_COLUMNS = [
  "id", "mission_id", "transporter_id", "transporter_name", "transporter_company",
  "transporter_status", "message", "proposed_price", "price_note", "status", "created_at",
].join(",");
const REQUEST_COLUMNS = [
  "id", "public_ref", "status", "requester_id", "requester_name", "requester_company",
  "type", "from_city", "to_city", "pickup_address", "delivery_address", "mission_date",
  "vehicle", "plate", "distance_km", "client_name", "client_contact", "client_phone",
  "price_mode", "proposed_price", "notes", "created_by_role", "approved_mission_id", "created_at",
].join(",");
const DOCUMENT_COLUMNS = [
  "id", "mission_id", "account_id", "recipient_id", "type", "file_name", "file_path",
  "status", "doc_type", "numero", "statut", "needs_signature", "signed_at", "emitted_at", "created_at",
].join(",");
const TRACKING_EVENT_COLUMNS = [
  "id", "mission_id", "transporter_id", "event_type", "title", "comment", "odometer_km",
  "fuel_level", "issue_type", "issue_severity", "latitude", "longitude",
  "location_accuracy_m", "location_recorded_at", "created_at",
].join(",");
const TRACKING_PHOTO_COLUMNS = [
  "id", "tracking_event_id", "mission_id", "transporter_id", "photo_type",
  "file_name", "file_path", "created_at",
].join(",");

function Field({ label, name, value, onChange, type = "text", placeholder = "", required = false }) {
  return (
    <label className="field">
      <span>{label}{required ? " *" : ""}</span>
      <input type={type} name={name} value={value ?? ""} placeholder={placeholder} onChange={onChange} aria-label={label} required={required} />
    </label>
  );
}

function Tabs({ items, active, onChange }) {
  return (
    <div className="tabs">
      {items.map((item) => (
        <button key={item.value} type="button" className={active === item.value ? "active" : ""} aria-pressed={active === item.value} onClick={() => onChange(item.value)}>
          {item.label}
          {typeof item.count === "number" && <span>{item.count}</span>}
        </button>
      ))}
    </div>
  );
}

function KpiGrid({ stats }) {
  return (
    <div className="kpi-grid">
      <div className="kpi-card"><strong>{stats.total}</strong><span>Missions totales</span></div>
      <div className="kpi-card"><strong>{stats.published}</strong><span>Publiées</span></div>
      <div className="kpi-card"><strong>{stats.pendingApplications}</strong><span>Candidatures</span></div>
      <div className="kpi-card"><strong>{stats.assigned}</strong><span>Attribuées</span></div>
      <div className="kpi-card"><strong>{stats.pendingRequests}</strong><span>Demandes</span></div>
    </div>
  );
}

function TransporterTypeBadge({ type }) {
  if (!type) return null;
  return <span className={`type-badge type-${type}`}>{labelTransporterType(type)}</span>;
}

function ThemeToggle() {
  const [theme, setTheme] = useState(() => {
    if (typeof window === "undefined") return null;
    try { return localStorage.getItem("secoto-theme"); } catch { return null; }
  });

  useEffect(() => {
    const root = document.documentElement;
    if (theme === "light" || theme === "dark") {
      root.dataset.theme = theme;
      try { localStorage.setItem("secoto-theme", theme); } catch { /* ignore */ }
    } else {
      delete root.dataset.theme;
      try { localStorage.removeItem("secoto-theme"); } catch { /* ignore */ }
    }
  }, [theme]);

  const prefersDark = typeof window !== "undefined" && window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  const isDark = theme === "dark" || (!theme && prefersDark);

  return (
    <button
      type="button"
      className="btn ghost small theme-toggle"
      onClick={() => setTheme(isDark ? "light" : "dark")}
      aria-label="Changer de thème"
      title={isDark ? "Passer en clair" : "Passer en sombre"}
    >
      <span aria-hidden="true">{isDark ? "☀︎" : "☾"}</span>
      <span className="tt-label">{isDark ? " Clair" : " Sombre"}</span>
    </button>
  );
}

function AccountDangerZone({ onDelete }) {
  return (
    <div className="danger-zone">
      <button
        className="privacy-link"
        type="button"
        onClick={() => openExternal("https://app.secoto-transport.fr/politique-confidentialite.html")}
      >
        Politique de confidentialité
      </button>
      <button className="btn danger small" type="button" onClick={onDelete}>
        Supprimer mon compte
      </button>
      <p className="muted danger-note">
        La suppression efface votre compte et vos données personnelles. Les documents comptables
        légalement obligatoires (factures) peuvent être conservés le temps prévu par la loi.
      </p>
    </div>
  );
}

function NotificationBell({ notifications, unreadCount, open, setOpen, onMarkAll, onOpenItem }) {
  const ref = useRef(null);
  useEffect(() => {
    function onClick(e) { if (open && ref.current && !ref.current.contains(e.target)) setOpen(false); }
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, [open, setOpen]);

  return (
    <div className="notif-wrap" ref={ref}>
      <button type="button" className="notif-bell" aria-label="Notifications" onClick={() => setOpen((v) => !v)}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" />
          <path d="M13.73 21a2 2 0 0 1-3.46 0" />
        </svg>
        {unreadCount > 0 && <span className="notif-badge">{unreadCount > 9 ? "9+" : unreadCount}</span>}
      </button>

      {open && (
        <div className="notif-panel">
          <div className="notif-panel-head">
            <strong>Notifications</strong>
            {unreadCount > 0 && <button type="button" onClick={onMarkAll}>Tout marquer lu</button>}
          </div>
          {notifications.length === 0 && <div className="notif-empty">Aucune notification pour le moment.</div>}
          {notifications.map((n) => (
            <div
              key={n.id}
              className={`notif-item ${n.isRead ? "read" : "unread"}`}
              onClick={() => onOpenItem(n)}
              role="button"
            >
              <span className="notif-dot" />
              <div className="notif-body">
                <strong>{n.title}</strong>
                {n.body && <p>{n.body}</p>}
                <span className="when">{formatDateTime(n.createdAt)}</span>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function MissionForm({ form, setForm, onSubmit, submitLabel, showPricing = false, disabled = false }) {
  function update(e) {
    const { name, value } = e.target;
    setForm((prev) => ({ ...prev, [name]: value }));
  }

  return (
    <form className="form-grid" onSubmit={onSubmit}>
      <label className="field">
        <span>Type de transport</span>
        <select name="type" value={form.type} onChange={update}>
          <option value="convoyage">Convoyage</option>
          <option value="plateau">Transport par plateau</option>
        </select>
      </label>
      <AddressAutocomplete label="Ville de départ" name="fromCity" value={form.fromCity} setForm={setForm} kind="city" />
      <AddressAutocomplete label="Ville d’arrivée" name="toCity" value={form.toCity} setForm={setForm} kind="city" />
      <AddressAutocomplete label="Adresse de départ" name="pickupAddress" value={form.pickupAddress} setForm={setForm} kind="address" />
      <AddressAutocomplete label="Adresse d’arrivée" name="deliveryAddress" value={form.deliveryAddress} setForm={setForm} kind="address" />
      <Field label="Date / heure" name="missionDate" value={form.missionDate} onChange={update} type="datetime-local" />
      <Field label="Véhicule" name="vehicle" value={form.vehicle} onChange={update} placeholder="Ex : Renault Clio" />
      <Field label="Immatriculation" name="plate" value={form.plate} onChange={update} />
      <Field label="Distance km" name="distanceKm" value={form.distanceKm} onChange={update} type="number" />
      {form.type === "plateau" && (
        <Field
          label="Coût transporteur €"
          name="carrierCost"
          value={form.carrierCost}
          onChange={update}
          type="number"
          placeholder="Ce que SECOTO paie au transporteur"
        />
      )}
      <Field label="Nom client" name="clientName" value={form.clientName} onChange={update} />
      <Field label="Contact client" name="clientContact" value={form.clientContact} onChange={update} />
      <Field label="Téléphone client" name="clientPhone" value={form.clientPhone} onChange={update} />
      <label className="field">
        <span>Mode de règlement</span>
        <select name="paymentMethod" value={form.paymentMethod} onChange={update}>
          <option value="virement">Virement bancaire</option>
          <option value="especes">Espèces à la livraison</option>
        </select>
      </label>
      {showPricing && <BaremeBox form={form} />}
      <label className="field field-full">
        <span>Notes internes</span>
        <textarea name="notes" value={form.notes} onChange={update} />
      </label>
      <button className="btn primary field-full" type="submit" disabled={disabled}>{submitLabel}</button>
    </form>
  );
}

/* Tarification automatique (barème SECOTO). Vue admin : affiche prix client,
   rémunération transporteur et marge. Le calcul fait foi côté base (colonnes
   générées) ; ceci n'est qu'un aperçu. */
function BaremeBox({ form }) {
  const client = computeClientPrice(form);
  const carrier = computeCarrierPay(form);
  const margin = computeMargin(form);
  const hint =
    form.type === "plateau"
      ? "Plateau : prix client = coût transporteur × 1,20 (marge 20 %, péages inclus)."
      : "Convoyage : 1,00 €/km facturé client · 0,55 €/km au transporteur · frais réels remboursés au réel.";
  return (
    <div className="field field-full bareme-box">
      <span>Tarification automatique — barème SECOTO</span>
      <div className="bareme-lines">
        <div><strong>Prix client</strong><b>{formatAmount(client)}</b></div>
        <div><strong>Rémunération transporteur</strong><b>{formatAmount(carrier)}</b></div>
        <div className="margin"><strong>Marge SECOTO</strong><b>{formatAmount(margin)}</b></div>
      </div>
      <small>{hint}</small>
    </div>
  );
}

function ClientCourseForm({ form, setForm, onSubmit, submitLabel, disabled }) {
  function update(e) {
    const { name, value } = e.target;
    setForm((prev) => ({ ...prev, [name]: value }));
  }
  return (
    <form className="form-grid" onSubmit={onSubmit}>
      <label className="field">
        <span>Type de transport *</span>
        <select name="type" value={form.type} onChange={update}>
          <option value="convoyage">Convoyage (conduite)</option>
          <option value="plateau">Transport par plateau / camion</option>
        </select>
      </label>
      <AddressAutocomplete label="Ville de départ" name="fromCity" value={form.fromCity} setForm={setForm} kind="city" required />
      <AddressAutocomplete label="Ville d’arrivée" name="toCity" value={form.toCity} setForm={setForm} kind="city" required />
      <AddressAutocomplete label="Adresse de prise en charge" name="pickupAddress" value={form.pickupAddress} setForm={setForm} kind="address" />
      <AddressAutocomplete label="Adresse de livraison" name="deliveryAddress" value={form.deliveryAddress} setForm={setForm} kind="address" />
      <Field label="Date / heure souhaitée" name="missionDate" value={form.missionDate} onChange={update} type="datetime-local" />
      <Field label="Véhicule à transporter" name="vehicle" value={form.vehicle} onChange={update} placeholder="Ex : Yamaha MT-07 / Peugeot 208" required />
      <Field label="Immatriculation" name="plate" value={form.plate} onChange={update} />
      <Field label="Distance estimée (km)" name="distanceKm" value={form.distanceKm} onChange={update} type="number" />
      <Field label="Votre budget indicatif €" name="proposedPrice" value={form.proposedPrice} onChange={update} type="number" placeholder="Optionnel" />
      <label className="field">
        <span>Mode de règlement *</span>
        <select name="paymentMethod" value={form.paymentMethod} onChange={update}>
          <option value="virement">Virement bancaire</option>
          <option value="especes">Espèces à la livraison</option>
        </select>
      </label>
      <label className="field field-full">
        <span>Détails / consignes</span>
        <textarea name="notes" value={form.notes} onChange={update} placeholder="État du véhicule, contraintes horaires, contact sur place…" />
      </label>
      <button className="btn primary field-full" type="submit" disabled={disabled}>{submitLabel}</button>
    </form>
  );
}

function PublicMissionInfo({ mission }) {
  return (
    <div className="card-section">
      <p><strong>Départ :</strong> {mission.pickupAddress || mission.fromCity || "Non renseigné"}</p>
      <p><strong>Arrivée :</strong> {mission.deliveryAddress || mission.toCity || "Non renseigné"}</p>
      <p><strong>Type de transport :</strong> {labelMissionType(mission.type)}</p>
      <p><strong>Type de véhicule :</strong> {mission.vehicle || "Non renseigné"}</p>
      <p><strong>Distance :</strong> {mission.distanceKm ? `${mission.distanceKm} km` : "Non renseignée"}</p>
    </div>
  );
}

function PrivateMissionInfo({ mission, showPricing = false, pricingView = "none" }) {
  const visiblePricing = showPricing ? "admin" : pricingView;
  const clientAmount = mission.clientPrice ?? computeClientPrice(mission);
  const carrierAmount = mission.carrierPay ?? computeCarrierPay(mission);
  const marginAmount = mission.margin ?? (clientAmount - carrierAmount);
  return (
    <div className="card-section private-box">
      <p><strong>Date :</strong> {formatDateTime(mission.missionDate)}</p>
      <p><strong>Client :</strong> {mission.clientName || "Non renseigné"}</p>
      <p><strong>Contact :</strong> {mission.clientContact || "Non renseigné"}</p>
      <p><strong>Téléphone :</strong> {mission.clientPhone || "Non renseigné"}</p>
      <p><strong>Immatriculation :</strong> {mission.plate || "Non renseignée"}</p>
      {/* Montants visibles uniquement par l'admin (cloisonnement marge/coût). */}
      {visiblePricing === "admin" && (
        <>
          <p><strong>Prix client :</strong> {formatAmount(clientAmount)}</p>
          <p><strong>Rémunération transporteur :</strong> {formatAmount(carrierAmount)}</p>
          <p><strong>Marge SECOTO :</strong> {formatAmount(marginAmount)}</p>
        </>
      )}
      {visiblePricing === "client" && <p><strong>Prix client :</strong> {formatAmount(clientAmount)}</p>}
      {visiblePricing === "transporter" && <p><strong>Votre rémunération :</strong> {formatAmount(carrierAmount)}</p>}
      <p><strong>Notes internes :</strong> {mission.notes || "Aucune note"}</p>
    </div>
  );
}

/* Timeline lisible côté client */
function ClientTrackingTimeline({ mission, events, getPhotos }) {
  const steps = [
    { key: "pickup_inspection", label: "Prise en charge du véhicule" },
    { key: "road_incident", label: "Incident signalé" },
    { key: "delivery_inspection", label: "Livraison" },
  ];
  const byType = {};
  events.forEach((ev) => { byType[ev.eventType] = ev; });

  return (
    <div className="timeline">
      <div className={`timeline-step ${mission.status === "published" ? "" : ""}`}>
        <strong>Course publiée</strong>
        <div className="when">{formatDateTime(mission.createdAt)}</div>
      </div>
      <div className={`timeline-step ${mission.assignedTransporterName ? "" : "pending"}`}>
        <strong>{mission.assignedTransporterName ? `Transporteur attribué : ${mission.assignedTransporterName}` : "En attente d’un transporteur"}</strong>
      </div>
      {steps.map((s) => {
        const ev = byType[s.key];
        const photos = ev ? getPhotos(ev.id) : [];
        return (
          <div className={`timeline-step ${ev ? "" : "pending"}`} key={s.key}>
            <strong>{s.label}</strong>
            {ev ? (
              <>
                <div className="when">{formatDateTime(ev.createdAt)}</div>
                {ev.comment && <p className="muted" style={{ margin: "4px 0 0" }}>{ev.comment}</p>}
                {photos.length > 0 && (
                  <div className="cards" style={{ marginTop: 10, gridTemplateColumns: "repeat(auto-fill,minmax(120px,1fr))" }}>
                    {photos.map((p) => {
                      const isImage = /\.(png|jpg|jpeg|webp|gif)$/i.test(p.fileName || p.fileUrl || "");
                      return isImage ? (
                        <a href={p.fileUrl} key={p.id} target="_blank" rel="noreferrer">
                          <img src={p.fileUrl} alt={p.fileName || "photo"} style={{ width: "100%", height: 90, objectFit: "cover", borderRadius: 12, border: "1px solid var(--border)" }} />
                        </a>
                      ) : (
                        <a className="btn ghost small" key={p.id} href={p.fileUrl} target="_blank" rel="noreferrer">Document</a>
                      );
                    })}
                  </div>
                )}
              </>
            ) : (
              <div className="when">À venir</div>
            )}
          </div>
        );
      })}
    </div>
  );
}

/* ============================================================
   Écran d'authentification (multi-rôles)
============================================================ */

function AuthScreen({ onBack }) {
  const [authMode, setAuthMode] = useState("login");
  const [role, setRole] = useState("client");
  const [transporterType, setTransporterType] = useState("convoyeur");
  const [clientType, setClientType] = useState("particulier");

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [fullName, setFullName] = useState("");
  const [companyName, setCompanyName] = useState("");
  const [phone, setPhone] = useState("");
  const [city, setCity] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleLogin(e) {
    e.preventDefault();
    setLoading(true); setError("");
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim().toLowerCase(), password });
    if (error) setError(error.message);
    setLoading(false);
  }

  async function handleResetPassword(e) {
    e.preventDefault();
    setLoading(true); setError(""); setNotice("");
    try {
      const cleanEmail = email.trim().toLowerCase();
      if (!cleanEmail) throw new Error("Indiquez l’adresse e-mail de votre compte.");
      const { error: resetError } = await supabase.auth.resetPasswordForEmail(cleanEmail, {
        redirectTo: getAuthRedirectUrl(),
      });
      if (resetError) throw resetError;
      setNotice("Un lien sécurisé de réinitialisation vient de vous être envoyé.");
    } catch (resetError) {
      setError(resetError.message || "Envoi du lien impossible.");
    } finally {
      setLoading(false);
    }
  }

  async function handleSignup(e) {
    e.preventDefault();
    setLoading(true); setError(""); setNotice("");

    if (role === "client" && clientType === "pro" && !companyName.trim()) {
      setError("Merci d’indiquer le nom de votre société.");
      setLoading(false);
      return;
    }

    const cleanEmail = email.trim().toLowerCase();
    const metadata = normalizePublicSignupMetadata({
      role,
      full_name: fullName,
      company_name: companyName,
      phone,
      city,
      transporter_type: transporterType,
      client_type: clientType,
    });
    const { data, error } = await supabase.auth.signUp({
      email: cleanEmail,
      password,
      options: {
        data: metadata,
        emailRedirectTo: getAuthRedirectUrl(),
      },
    });

    if (error) { setError(error.message); setLoading(false); return; }

    if (!data.user) {
      setNotice("Compte créé. Vérifiez votre email si une confirmation est demandée.");
    } else if (role === "client") {
      setNotice("Compte client créé — vous pouvez publier vos courses immédiatement.");
    } else {
      setNotice("Compte transporteur créé. Il sera validé par SECOTO avant de pouvoir candidater.");
    }
    setLoading(false);
  }

  return (
    <main className="app-shell">
      <header className="app-header">
        <div>
          <p className="eyebrow">SECOTO</p>
          <h1>Le transport de véhicules, simplifié.</h1>
          <p className="subtitle">Publiez une course en 30 secondes ou trouvez des missions de convoyage et de transport auto / moto près de chez vous.</p>
        </div>
        <div className="header-actions">
          {onBack && <button className="btn ghost small" onClick={onBack}>← Retour</button>}
          <ThemeToggle />
        </div>
      </header>

      {error && <div className="alert error">{error}</div>}
      {notice && <div className="alert success">{notice}</div>}

      {authMode !== "reset" && (
        <Tabs
          active={authMode}
          onChange={setAuthMode}
          items={[
            { value: "login", label: "Connexion" },
            { value: "signup", label: "Créer un compte" },
          ]}
        />
      )}

      <section className="layout">
        <div className="panel panel-full">
          {authMode === "reset" ? (
            <>
              <h2>Réinitialiser le mot de passe</h2>
              <p className="muted">Le lien fonctionne sur le Web, Android et iOS.</p>
              <form className="form-grid" onSubmit={handleResetPassword}>
                <Field label="Email" name="email" value={email} onChange={(e) => setEmail(e.target.value)} type="email" required />
                <button className="btn primary field-full" type="submit" disabled={loading}>
                  {loading ? "Envoi…" : "Recevoir le lien sécurisé"}
                </button>
                <button className="btn ghost field-full" type="button" onClick={() => setAuthMode("login")}>
                  Retour à la connexion
                </button>
              </form>
            </>
          ) : authMode === "login" ? (
            <>
              <h2>Connexion</h2>
              <form className="form-grid" onSubmit={handleLogin}>
                <Field label="Email" name="email" value={email} onChange={(e) => setEmail(e.target.value)} type="email" required />
                <Field label="Mot de passe" name="password" value={password} onChange={(e) => setPassword(e.target.value)} type="password" required />
                <button className="btn primary field-full" type="submit" disabled={loading}>{loading ? "Connexion…" : "Se connecter"}</button>
                <button className="linklike field-full" type="button" onClick={() => setAuthMode("reset")}>
                  Mot de passe oublié ?
                </button>
              </form>
            </>
          ) : (
            <>
              <h2>Créer un compte</h2>

              <p className="field"><span>Je suis…</span></p>
              <div className="pick-grid">
                <button type="button" className={`pick-tile ${role === "client" ? "selected" : ""}`} onClick={() => setRole("client")}>
                  <strong>Client</strong>
                  <small>J’ai un véhicule à faire transporter</small>
                </button>
                <button type="button" className={`pick-tile ${role === "transporter" ? "selected" : ""}`} onClick={() => setRole("transporter")}>
                  <strong>Transporteur</strong>
                  <small>Je réalise des missions de transport</small>
                </button>
              </div>

              {role === "transporter" && (
                <>
                  <p className="field" style={{ marginTop: 16 }}><span>Mon activité</span></p>
                  <div className="pick-grid">
                    {TRANSPORTER_TYPES.map((t) => (
                      <button type="button" key={t.value} className={`pick-tile ${transporterType === t.value ? "selected" : ""}`} onClick={() => setTransporterType(t.value)}>
                        <strong>{t.label}</strong>
                        <small>{t.hint}</small>
                      </button>
                    ))}
                  </div>
                </>
              )}

              {role === "client" && (
                <>
                  <p className="field" style={{ marginTop: 16 }}><span>Type de client</span></p>
                  <div className="pick-grid">
                    <button type="button" className={`pick-tile ${clientType === "particulier" ? "selected" : ""}`} onClick={() => setClientType("particulier")}>
                      <strong>Particulier</strong>
                      <small>Pour un besoin personnel</small>
                    </button>
                    <button type="button" className={`pick-tile ${clientType === "pro" ? "selected" : ""}`} onClick={() => setClientType("pro")}>
                      <strong>Professionnel</strong>
                      <small>Garage, concession, loueur, flotte</small>
                    </button>
                  </div>
                </>
              )}

              <form className="form-grid" style={{ marginTop: 18 }} onSubmit={handleSignup}>
                <Field label="Nom complet" name="fullName" value={fullName} onChange={(e) => setFullName(e.target.value)} required />
                <Field label={role === "client" && clientType === "particulier" ? "Société (optionnel)" : "Société"} name="companyName" value={companyName} onChange={(e) => setCompanyName(e.target.value)} required={role === "transporter" || (role === "client" && clientType === "pro")} />
                <Field label="Email" name="email" value={email} onChange={(e) => setEmail(e.target.value)} type="email" required />
                <Field label="Mot de passe" name="password" value={password} onChange={(e) => setPassword(e.target.value)} type="password" required />
                <Field label="Téléphone" name="phone" value={phone} onChange={(e) => setPhone(e.target.value)} required />
                <Field label="Ville" name="city" value={city} onChange={(e) => setCity(e.target.value)} required />
                <button className="btn primary field-full" type="submit" disabled={loading}>
                  {loading ? "Création…" : role === "client" ? "Créer mon compte client" : "Demander mon accès transporteur"}
                </button>
              </form>
            </>
          )}
        </div>
      </section>
    </main>
  );
}

/* ============================================================
   Landing publique — dépôt sans compte
============================================================ */

const emptyGuestForm = {
  type: "convoyage",
  clientName: "",
  clientPhone: "",
  clientContact: "",
  fromCity: "",
  toCity: "",
  pickupAddress: "",
  deliveryAddress: "",
  missionDate: "",
  vehicle: "",
  plate: "",
  distanceKm: "",
  proposedPrice: "",
  notes: "",
  website: "", // honeypot anti-bot (doit rester vide)
};

function PublicLanding({ onShowAuth }) {
  const [form, setForm] = useState(emptyGuestForm);
  const [showDetails, setShowDetails] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [done, setDone] = useState(null);

  // Pré-remplissage depuis l'URL (redirection depuis le site vitrine)
  useEffect(() => {
    if (typeof window === "undefined") return;
    const q = new URLSearchParams(window.location.search);
    if (![...q.keys()].length) return;
    const svc = (q.get("service") || q.get("type") || "").toLowerCase();
    const patch = {
      clientName: q.get("name") || q.get("nom") || "",
      clientPhone: q.get("phone") || q.get("tel") || q.get("telephone") || "",
      clientContact: q.get("email") || "",
      fromCity: q.get("from") || q.get("depart") || "",
      toCity: q.get("to") || q.get("arrivee") || "",
      vehicle: q.get("vehicle") || q.get("vehicule") || "",
      distanceKm: q.get("km") || q.get("distance") || "",
      missionDate: q.get("date") || "",
      notes: q.get("notes") || q.get("infos") || "",
      type: svc.includes("moto") || svc === "plateau" ? "plateau" : "convoyage",
    };
    queueMicrotask(() => {
      setForm((prev) => ({ ...prev, ...Object.fromEntries(Object.entries(patch).filter(([, v]) => v !== "")), type: patch.type }));
      if (patch.clientContact || patch.distanceKm || patch.missionDate || patch.notes) setShowDetails(true);
    });
    setTimeout(() => {
      const el = document.querySelector(".deposit-card");
      if (el) el.scrollIntoView({ behavior: "smooth", block: "start" });
    }, 300);
  }, []);

  function update(e) {
    const { name, value } = e.target;
    setForm((prev) => ({ ...prev, [name]: value }));
  }

  async function submit(e) {
    e.preventDefault();
    setError("");

    if (form.website) return; // bot détecté
    if (!form.clientName.trim()) return setError("Merci d’indiquer votre nom.");
    if (!form.clientPhone.trim() || form.clientPhone.replace(/\D/g, "").length < 6) return setError("Un numéro de téléphone valide est obligatoire pour vous recontacter.");
    if (!form.fromCity.trim() || !form.toCity.trim()) return setError("Indiquez la ville de départ et d’arrivée.");
    if (!form.vehicle.trim()) return setError("Indiquez le véhicule à transporter.");

    setLoading(true);
    try {
      const row = requestToDb(form, null, { createdByRole: "guest" });
      const { data, error } = await supabase.rpc("secoto_create_public_request", {
        p_payload: row,
        p_idempotency_key: randomIdempotencyKey(),
      });
      if (error) throw error;
      const created = Array.isArray(data) ? data[0] : data;
      setDone({ ref: created?.public_ref || row.public_ref, phone: form.clientPhone.trim() });
      setForm(emptyGuestForm);
      window.scrollTo({ top: 0, behavior: "smooth" });
    } catch (err) {
      setError(err.message || "Une erreur est survenue. Réessayez ou appelez-nous.");
    } finally {
      setLoading(false);
    }
  }

  if (done) {
    return (
      <main className="app-shell">
        <header className="topbar">
          <div className="topbar-title"><p className="eyebrow">SECOTO</p><h1>Demande envoyée</h1></div>
          <div className="topbar-actions"><ThemeToggle /><button className="btn ghost small" onClick={onShowAuth}>Se connecter</button></div>
        </header>
        <section className="layout">
          <div className="panel panel-full" style={{ textAlign: "center" }}>
            <div style={{ fontSize: 46, marginBottom: 6 }}>✅</div>
            <h2 style={{ justifyContent: "center" }}>C’est enregistré, merci !</h2>
            <p className="muted" style={{ maxWidth: "48ch", margin: "0 auto 16px" }}>
              Votre demande <strong>{done.ref}</strong> a bien été transmise à SECOTO. Un conseiller vous rappelle rapidement au <strong>{done.phone}</strong> pour organiser votre transport.
            </p>
            <div className="actions-row" style={{ justifyContent: "center" }}>
              <button className="btn primary" onClick={() => setDone(null)}>Déposer une autre demande</button>
            </div>
          </div>
        </section>
      </main>
    );
  }

  return (
    <main className="app-shell">
      <header className="topbar">
        <div className="topbar-title"><p className="eyebrow">SECOTO</p><h1>Transport de véhicules</h1></div>
        <div className="topbar-actions">
          <ThemeToggle />
          <button className="btn ghost small" onClick={onShowAuth}>Espace pro / Connexion</button>
        </div>
      </header>

      <section className="hero">
        <span className="hero-badge">Mise en relation • Auto & Moto • France &amp; Europe</span>
        <h2 className="hero-title">Faites transporter votre véhicule, sans prise de tête.</h2>
        <p className="hero-sub">Décrivez votre besoin en 1 minute. Nos transporteurs vérifiés vous recontactent avec leur meilleur tarif. Aucune inscription nécessaire.</p>
        <div className="hero-points">
          <span>✓ Convoyage &amp; plateau</span>
          <span>✓ Transporteurs assurés</span>
          <span>✓ Suivi à chaque étape</span>
        </div>
      </section>

      <section className="layout">
        <div className="panel panel-full deposit-card">
          <h2>Déposer votre demande</h2>
          <p className="muted" style={{ marginBottom: 14 }}>Champs marqués d’un * obligatoires. On vous rappelle, pas besoin de créer de compte.</p>

          {error && <div className="alert error">{error}</div>}

          <form className="form-grid" onSubmit={submit}>
            <Field label="Votre nom" name="clientName" value={form.clientName} onChange={update} required />
            <Field label="Téléphone" name="clientPhone" value={form.clientPhone} onChange={update} type="tel" placeholder="Pour vous rappeler" required />
            <label className="field">
              <span>Type de transport *</span>
              <select name="type" value={form.type} onChange={update}>
                <option value="convoyage">Convoyage (un chauffeur conduit)</option>
                <option value="plateau">Plateau / camion</option>
              </select>
            </label>
            <Field label="Véhicule à transporter" name="vehicle" value={form.vehicle} onChange={update} placeholder="Ex : Yamaha MT-07, Peugeot 208…" required />
            <AddressAutocomplete label="Ville de départ" name="fromCity" value={form.fromCity} setForm={setForm} kind="city" required />
            <AddressAutocomplete label="Ville d’arrivée" name="toCity" value={form.toCity} setForm={setForm} kind="city" required />

            {/* Honeypot invisible */}
            <input type="text" name="website" value={form.website} onChange={update} tabIndex={-1} autoComplete="off" style={{ position: "absolute", left: "-9999px", width: 1, height: 1, opacity: 0 }} aria-hidden="true" />

            {!showDetails && (
              <button type="button" className="btn ghost field-full" onClick={() => setShowDetails(true)}>+ Ajouter des détails (facultatif)</button>
            )}

            {showDetails && (
              <>
                <Field label="Email (facultatif)" name="clientContact" value={form.clientContact} onChange={update} type="email" />
                <Field label="Date / heure souhaitée" name="missionDate" value={form.missionDate} onChange={update} type="datetime-local" />
                <AddressAutocomplete label="Adresse de prise en charge" name="pickupAddress" value={form.pickupAddress} setForm={setForm} kind="address" />
                <AddressAutocomplete label="Adresse de livraison" name="deliveryAddress" value={form.deliveryAddress} setForm={setForm} kind="address" />
                <Field label="Immatriculation" name="plate" value={form.plate} onChange={update} />
                <Field label="Distance estimée (km)" name="distanceKm" value={form.distanceKm} onChange={update} type="number" />
                <Field label="Budget indicatif €" name="proposedPrice" value={form.proposedPrice} onChange={update} type="number" />
                <label className="field field-full">
                  <span>Précisions</span>
                  <textarea name="notes" value={form.notes} onChange={update} placeholder="État du véhicule, contraintes horaires, contact sur place…" />
                </label>
              </>
            )}

            <button className="btn primary field-full" type="submit" disabled={loading} style={{ minHeight: 56, fontSize: "1.02rem" }}>
              {loading ? "Envoi…" : "Déposer ma demande"}
            </button>
          </form>
        </div>
      </section>

      <p className="muted" style={{ textAlign: "center", marginTop: 18 }}>
        Vous êtes transporteur ou déjà client SECOTO ? <button className="linklike" onClick={onShowAuth}>Connectez-vous ici</button>.
      </p>
    </main>
  );
}

function PasswordRecoveryScreen({ onDone }) {
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  async function updatePassword(event) {
    event.preventDefault();
    setError("");
    if (password.length < 10) {
      setError("Utilisez au moins 10 caractères.");
      return;
    }
    if (password !== confirmation) {
      setError("Les deux mots de passe ne correspondent pas.");
      return;
    }
    setLoading(true);
    const { error: updateError } = await supabase.auth.updateUser({ password });
    setLoading(false);
    if (updateError) {
      setError(updateError.message || "Mise à jour impossible.");
      return;
    }
    onDone();
  }

  return (
    <main className="app-shell">
      <header className="app-header">
        <div><p className="eyebrow">SECOTO</p><h1>Nouveau mot de passe</h1></div>
        <ThemeToggle />
      </header>
      {error && <div className="alert error">{error}</div>}
      <section className="layout">
        <div className="panel panel-full">
          <form className="form-grid" onSubmit={updatePassword}>
            <Field label="Nouveau mot de passe" type="password" value={password} onChange={(event) => setPassword(event.target.value)} required />
            <Field label="Confirmer le mot de passe" type="password" value={confirmation} onChange={(event) => setConfirmation(event.target.value)} required />
            <button className="btn primary field-full" type="submit" disabled={loading}>
              {loading ? "Mise à jour…" : "Enregistrer le mot de passe"}
            </button>
          </form>
        </div>
      </section>
    </main>
  );
}

function PublicEntry() {
  const [view, setView] = useState("landing");
  if (view === "auth") return <AuthScreen onBack={() => setView("landing")} />;
  return <PublicLanding onShowAuth={() => setView("auth")} />;
}

/* ============================================================
   Application
============================================================ */

export default function App() {
  const [session, setSession] = useState(null);
  const [account, setAccount] = useState(null);
  const [bootLoading, setBootLoading] = useState(true);
  const [accountChecked, setAccountChecked] = useState(false);
  const [passwordRecovery, setPasswordRecovery] = useState(false);
  const [networkConnected, setNetworkConnected] = useState(
    typeof navigator === "undefined" ? true : navigator.onLine,
  );
  const [pendingSyncCount, setPendingSyncCount] = useState(0);

  const [mode, setMode] = useState("admin");
  const [adminTab, setAdminTab] = useState("create");
  const [transporterTab, setTransporterTab] = useState("available");
  const [clientTab, setClientTab] = useState("post");
  const [transporterFilter, setTransporterFilter] = useState("all");

  const [missions, setMissions] = useState([]);
  const [publicMissions, setPublicMissions] = useState([]);
  const [requests, setRequests] = useState([]);
  const [applications, setApplications] = useState([]);
  const [transporters, setTransporters] = useState([]);
  const [documents, setDocuments] = useState([]);
  const [trackingEvents, setTrackingEvents] = useState([]);
  const [trackingPhotos, setTrackingPhotos] = useState([]);
  const [trackingForms, setTrackingForms] = useState({});

  const [missionForm, setMissionForm] = useState(emptyMissionForm);
  const [requestForm, setRequestForm] = useState(emptyMissionForm);
  const [clientForm, setClientForm] = useState(emptyMissionForm);
  const [applicationMessages, setApplicationMessages] = useState({});
  const [applicationPrices, setApplicationPrices] = useState({});
  const [documentType, setDocumentType] = useState("assurance_rc_pro");
  const [documentFiles, setDocumentFiles] = useState([]);
  const [documentOperationId, setDocumentOperationId] = useState(() => randomIdempotencyKey());
  const [uploadProgress, setUploadProgress] = useState({});

  // Fenêtre documents (devis / bon de mission / facture) : { kind, mission, transporter }
  const [docModal, setDocModal] = useState(null);
  // Mission mise en avant après clic sur une notification.
  const [focusMissionId, setFocusMissionId] = useState(null);

  const [notifications, setNotifications] = useState([]);
  const [notifOpen, setNotifOpen] = useState(false);
  const [navOpen, setNavOpen] = useState(false);
  const [toasts, setToasts] = useState([]);
  // Le choix « notifications » est mémorisé PAR COMPTE : sur un téléphone
  // partagé entre plusieurs comptes SECOTO, chacun doit pouvoir les activer.
  const [pushState, setPushState] = useState("idle"); // idle | enabled | dismissed

  // Relecture du choix à chaque changement de compte (clé propre au compte).
  useEffect(() => {
    if (!account?.id) return;
    let v = "idle";
    try { v = localStorage.getItem(`secoto-push-${account.id}`) || "idle"; } catch { /* ignore */ }
    queueMicrotask(() => setPushState(v));
  }, [account?.id]);

  useEffect(() => {
    if (!account?.id) return;
    try { localStorage.setItem(`secoto-push-${account.id}`, pushState); } catch { /* ignore */ }
  }, [pushState, account?.id]);

  const [loading, setLoading] = useState(false);
  const [actionLoading, setActionLoading] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const accountRef = useRef(null);
  useEffect(() => { accountRef.current = account; }, [account]);
  const actionLocksRef = useRef(new Set());
  const accountLoadGenerationRef = useRef(0);
  const dataGenerationRef = useRef(0);
  const notificationGenerationRef = useRef(0);
  const draftTimersRef = useRef(new Map());
  const pendingSyncRef = useRef(false);
  const pendingDeepLinkRef = useRef(null);
  const uiStateRef = useRef({ navOpen: false, notifOpen: false });
  useEffect(() => {
    uiStateRef.current = { navOpen, notifOpen };
  }, [navOpen, notifOpen]);
  // Minuteur de regroupement des rafraîchissements temps réel.
  const refreshTimer = useRef(null);

  async function runLocked(key, work) {
    if (actionLocksRef.current.has(key)) return { skipped: true };
    actionLocksRef.current.add(key);
    setActionLoading(true);
    try {
      return await work();
    } finally {
      actionLocksRef.current.delete(key);
      setActionLoading(actionLocksRef.current.size > 0);
    }
  }

  function applyNavigationLink(link, currentAccount = accountRef.current) {
    if (!link || link.kind !== "navigation") return;
    if (!currentAccount) {
      pendingDeepLinkRef.current = link;
      return;
    }
    const screen = link.screen || "courses";
    if (currentAccount.role === "admin") {
      setMode("admin");
      if (screen === "documents") setAdminTab("assigned");
      else if (screen === "frais") setAdminTab("frais");
      else if (screen === "requests") setAdminTab("requests");
      else if (screen === "applications") setAdminTab("applications");
      else if (screen === "assigned") setAdminTab("assigned");
      else setAdminTab("published");
    } else if (currentAccount.role === "transporter") {
      if (screen === "documents") setTransporterTab("documents");
      else if (screen === "frais") setTransporterTab("frais");
      else if (screen === "applications") setTransporterTab("applications");
      else if (screen === "requests") setTransporterTab("requests");
      else if (screen === "assigned") setTransporterTab("assigned");
      else if (screen === "profile") setTransporterTab("profile");
      else if (screen === "contact") setTransporterTab("contact");
      else setTransporterTab("available");
    } else {
      if (screen === "documents") setClientTab("documents");
      else if (screen === "profile") setClientTab("profile");
      else if (screen === "contact") setClientTab("contact");
      else setClientTab("courses");
    }
    if (link.missionId) setFocusMissionId(link.missionId);
    pendingDeepLinkRef.current = null;
  }

  async function handlePlatformDeepLink(link) {
    if (link?.kind === "auth") {
      if (link.code) {
        const { error: exchangeError } = await supabase.auth.exchangeCodeForSession(link.code);
        if (exchangeError) {
          setError(exchangeError.message || "Lien d’authentification invalide ou expiré.");
          return;
        }
      }
      if (link.authType === "recovery") setPasswordRecovery(true);
      return;
    }
    applyNavigationLink(link);
  }

  useEffect(() => {
    let dispose = async () => {};
    let alive = true;
    initializePlatform({
      onResume: async () => {
        const { data } = await supabase.auth.getSession();
        if (!data?.session) {
          accountLoadGenerationRef.current += 1;
          dataGenerationRef.current += 1;
          notificationGenerationRef.current += 1;
          setSession(null);
          setAccount(null);
          return;
        }
        scheduleRefresh(0);
        loadNotifications(accountRef.current);
      },
      onNetworkChange: ({ connected }) => {
        setNetworkConnected(Boolean(connected));
        if (connected) scheduleRefresh(0);
      },
      onDeepLink: handlePlatformDeepLink,
      onBack: () => {
        if (uiStateRef.current.notifOpen) {
          setNotifOpen(false);
          return true;
        }
        if (uiStateRef.current.navOpen) {
          setNavOpen(false);
          return true;
        }
        return false;
      },
    }).then((cleanup) => {
      if (alive) dispose = cleanup;
      else cleanup();
    }).catch((platformError) => {
      if (alive) setError(platformError.message || "Initialisation native incomplète.");
    });
    return () => {
      alive = false;
      dispose();
    };
    // Initialisation unique ; les callbacks utilisent des refs.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!account?.id) return undefined;
    let dispose = async () => {};
    let alive = true;
    initializePushListeners({
      onNotification: ({ title, body }) => pushToast(title, body),
      onOpen: handlePlatformDeepLink,
    }).then((cleanup) => {
      if (alive) dispose = cleanup;
      else cleanup();
    });
    return () => {
      alive = false;
      dispose();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [account?.id]);

  useEffect(() => {
    if (!account?.id) return undefined;
    let alive = true;
    Promise.all([
      listTrackingDrafts(account.id),
      listPendingActions(account.id),
    ]).then(([drafts, pending]) => {
      if (!alive) return;
      const restored = {};
      for (const draft of drafts) {
        const value = draft.value;
        if (!value?.missionId || !value?.eventType || !value?.form) continue;
        restored[`${value.missionId}-${value.eventType}`] = value.form;
      }
      if (Object.keys(restored).length) setTrackingForms((previous) => ({ ...previous, ...restored }));
      setPendingSyncCount(pending.length);
    }).catch(() => {
      if (alive) setPendingSyncCount(0);
    });
    return () => { alive = false; };
  }, [account?.id]);

  useEffect(() => {
    if (account?.id && pendingDeepLinkRef.current) {
      applyNavigationLink(pendingDeepLinkRef.current, account);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [account?.id]);

  /* ---------- Boot / session ---------- */
  useEffect(() => {
    let mounted = true;
    const timer = setTimeout(() => {
      if (mounted) {
        setBootLoading(false);
        setSession(null);
        accountLoadGenerationRef.current += 1;
        dataGenerationRef.current += 1;
        notificationGenerationRef.current += 1;
        setAccount(null);
      }
    }, 8000);

    async function boot() {
      try {
        const { data, error } = await supabase.auth.getSession();
        if (error) throw error;
        if (!mounted) return;
        clearTimeout(timer);
        const currentSession = data?.session || null;
        setSession(currentSession);
        setBootLoading(false);
        if (currentSession?.user?.id) loadAccount(currentSession.user.id);
      } catch (err) {
        if (mounted) {
          clearTimeout(timer);
          setError(err.message || "Erreur au chargement de la session Supabase.");
          setSession(null); setAccount(null); setBootLoading(false);
        }
      }
    }
    boot();

    const { data: listener } = supabase.auth.onAuthStateChange((event, newSession) => {
      if (event === "PASSWORD_RECOVERY") setPasswordRecovery(true);
      setSession(newSession || null);
      if (newSession?.user?.id) loadAccount(newSession.user.id);
      else {
        accountLoadGenerationRef.current += 1;
        dataGenerationRef.current += 1;
        notificationGenerationRef.current += 1;
        setAccount(null);
      }
    });

    return () => { mounted = false; clearTimeout(timer); listener?.subscription?.unsubscribe(); };
  }, []);

  useEffect(() => {
    if (account) {
      queueMicrotask(() => setMode(account.role === "admin" ? "admin" : account.role === "client" ? "client" : "transporter"));
      loadAllData(account);
      loadNotifications(account);
      subscribeRealtime(account);
    }
    return () => {
      for (const c of supabase.getChannels()) {
        if (c.topic.includes("notif-") || c.topic.includes("secoto-data-")) supabase.removeChannel(c);
      }
      if (refreshTimer.current) { clearTimeout(refreshTimer.current); refreshTimer.current = null; }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [account?.id]);

  async function loadAccount(userId) {
    const generation = ++accountLoadGenerationRef.current;
    const isCurrentAccountLoad = async () => {
      if (generation !== accountLoadGenerationRef.current) return false;
      const { data } = await supabase.auth.getSession();
      return data?.session?.user?.id === userId;
    };
    setError("");
    setAccountChecked(false); // on repasse en "chargement" tant que le profil n'est pas verifie
    try {
      const timeout = new Promise((_, reject) => setTimeout(() => reject(new Error("Timeout chargement profil SECOTO")), 8000));
      const query = supabase
        .from("accounts")
        .select("id,role,full_name,company_name,email,phone,city,status,docs_count,is_verified,transporter_type,client_type,created_at")
        .eq("id", userId)
        .single();
      const { data, error } = await Promise.race([query, timeout]);
      if (error) throw error;
      if (!(await isCurrentAccountLoad())) return;
      const loadedAccount = accountFromDb(data);
      if (loadedAccount.status === "suspended") {
        await supabase.auth.signOut();
        throw new Error("Ce compte est suspendu. Contactez SECOTO pour obtenir de l’aide.");
      }
      if (!(await isCurrentAccountLoad())) return;
      setAccount(loadedAccount);
    } catch (err) {
      if (await isCurrentAccountLoad()) {
        setError(err.message || "Profil SECOTO introuvable ou bloqué par RLS.");
        setAccount(null);
      }
    } finally {
      if (generation === accountLoadGenerationRef.current) setAccountChecked(true);
    }
  }

  /* ---------- Notifications ---------- */
  async function loadNotifications(currentAccount = account) {
    if (!currentAccount) return;
    const accountId = currentAccount.id;
    const generation = ++notificationGenerationRef.current;
    try {
      const { data, error } = await supabase
        .from("notifications")
        .select("id,account_id,type,title,body,mission_id,audience,is_read,created_at")
        .eq("account_id", currentAccount.id)
        .order("created_at", { ascending: false })
        .limit(50);
      if (error) throw error;
      if (
        generation !== notificationGenerationRef.current
        || accountRef.current?.id !== accountId
      ) return;
      setNotifications((data || []).map(notificationFromDb));
    } catch {
      // table absente => on ignore silencieusement (migration non encore exécutée)
    }
  }

  function pushToast(title, body) {
    const id = `${Date.now()}-${Math.random()}`;
    setToasts((prev) => [...prev, { id, title, body }]);
    setTimeout(() => setToasts((prev) => prev.filter((t) => t.id !== id)), 6000);
  }

  // Rafraîchissement groupé : plusieurs événements rapprochés ne déclenchent
  // qu'un seul appel réseau (évite de saturer la connexion mobile).
  function scheduleRefresh(delay = 250) {
    if (refreshTimer.current) clearTimeout(refreshTimer.current);
    refreshTimer.current = setTimeout(() => {
      refreshTimer.current = null;
      const acc = accountRef.current;
      if (acc) loadAllData(acc, { silent: true });
    }, delay);
  }

  function subscribeRealtime(currentAccount) {
    // On ne retire QUE nos deux canaux (removeAllChannels casserait aussi
    // l'abonnement temps réel du panneau Frais).
    for (const c of supabase.getChannels()) {
      if (c.topic.includes("notif-") || c.topic.includes("secoto-data-")) supabase.removeChannel(c);
    }

    // ---- 1) Mes notifications (instantané, sans rechargement) ----
    supabase
      .channel(`notif-${currentAccount.id}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "notifications", filter: `account_id=eq.${currentAccount.id}` },
        (payload) => {
          const n = notificationFromDb(payload.new);
          setNotifications((prev) => [n, ...prev.filter((x) => x.id !== n.id)]);
          pushToast(n.title, n.body);
          scheduleRefresh();
        })
      .subscribe();

    // ---- 2) Flux de données : un seul canal pour toutes les tables ----
    // On écoute TOUS les événements (INSERT / UPDATE / DELETE) afin qu'une
    // course supprimée, un frais déposé ou une candidature arrivent aussitôt
    // chez tout le monde.
    const data = supabase.channel(`secoto-data-${currentAccount.id}`);

    // Les missions brutes ne passent jamais par Realtime : elles contiennent
    // des colonnes financieres cloisonnees. Les notifications serveur et le
    // rafraichissement groupe rechargent les vues expurgees par role.

    data.on("postgres_changes", { event: "*", schema: "public", table: "mission_applications" }, (payload) => {
      if (payload.eventType === "INSERT" && currentAccount.role === "admin") {
        const a = applicationFromDb(payload.new);
        pushToast("Nouvelle candidature", `${a.transporterName || "Transporteur"} — ${a.proposedPrice ? `${Number(a.proposedPrice).toFixed(0)} €` : "tarif non renseigné"}`);
      }
      scheduleRefresh();
    });

    data.on("postgres_changes", { event: "*", schema: "public", table: "mission_requests" }, (payload) => {
      if (payload.eventType === "INSERT" && currentAccount.role === "admin") {
        const r = requestFromDb(payload.new);
        pushToast("Nouvelle demande client", `${r.fromCity || "Départ"} → ${r.toCity || "Arrivée"}${r.clientPhone ? " · " + r.clientPhone : ""}`);
      }
      scheduleRefresh();
    });

    data.on("postgres_changes", { event: "*", schema: "public", table: "frais" }, () => {
      // Le détail est affiché par FraisPanel (qui écoute aussi) ; ici on
      // rafraîchit les compteurs et l'état global.
      scheduleRefresh();
    });

    data.on("postgres_changes", { event: "*", schema: "public", table: "mission_tracking_events" }, () => {
      scheduleRefresh();
    });

    data.subscribe();
  }

  // Filet de sécurité : au retour de veille / réouverture de l'app, on
  // resynchronise (les WebSockets mobiles sont coupés en arrière-plan).
  useEffect(() => {
    if (!account?.id) return undefined;
    function onWake() {
      if (document.visibilityState !== "visible") return;
      scheduleRefresh(80);
      loadNotifications(accountRef.current || account);
    }
    document.addEventListener("visibilitychange", onWake);
    window.addEventListener("online", onWake);
    window.addEventListener("focus", onWake);

    // Filet de sécurité : sur mobile, la connexion temps réel est coupée dès
    // que l'écran s'éteint ou que le réseau change, et un événement peut
    // passer à la trappe. On resynchronise donc régulièrement tant que l'app
    // est à l'écran — invisible pour l'utilisateur, mais rien ne se perd.
    const tick = setInterval(() => {
      if (document.visibilityState === "visible") scheduleRefresh(0);
    }, 20000);

    return () => {
      clearInterval(tick);
      document.removeEventListener("visibilitychange", onWake);
      window.removeEventListener("online", onWake);
      window.removeEventListener("focus", onWake);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [account?.id]);

  async function markAllNotificationsRead() {
    setNotifications((prev) => prev.map((n) => ({ ...n, isRead: true })));
    try {
      await supabase.from("notifications").update({ is_read: true }).eq("account_id", account.id).eq("is_read", false);
    } catch { /* ignore */ }
  }

  // Ouvre la notification ET emmène l'utilisateur directement sur la mission
  // concernée : bon onglet + carte dépliée + défilement + surbrillance.
  async function openNotification(n) {
    if (!n.isRead) {
      setNotifications((prev) => prev.map((x) => (x.id === n.id ? { ...x, isRead: true } : x)));
      try { await supabase.from("notifications").update({ is_read: true }).eq("id", n.id); } catch { /* ignore */ }
    }
    setNotifOpen(false);
    setNavOpen(false);

    const target = n.missionId
      ? missions.find((m) => m.id === n.missionId) || publicMissions.find((m) => m.id === n.missionId)
      : null;

    // Une notification de document mène droit à l'écran « Mes documents ».
    if (n.type === "document" && account.role !== "admin") {
      if (account.role === "client") setClientTab("documents");
      else setTransporterTab("documents");
      if (n.missionId) setFocusMissionId(n.missionId);
      return;
    }

    if (account.role === "admin") {
      setMode("admin");
      if (n.type === "frais") setAdminTab("frais");
      else if (n.type === "new_request") setAdminTab("requests");
      else if (n.type === "new_application") setAdminTab("applications");
      else if (target?.status === "assigned") setAdminTab("assigned");
      else if (target?.status === "completed") setAdminTab("completed");
      else if (target) setAdminTab("published");
    } else if (account.role === "transporter") {
      if (n.type === "frais_status") setTransporterTab("frais");
      else if (target?.assignedTransporterId === account.id) setTransporterTab("assigned");
      else setTransporterTab("available");
    } else {
      setClientTab("courses");
    }

    if (n.missionId) setFocusMissionId(n.missionId);
  }

  // Synchronise les maquettes de documents vers la base : c'est ce qui permet
  // à Supabase de générer et d'envoyer le devis TOUT SEUL à l'attribution,
  // sans dépendre de l'application. Une fois par session admin.
  useEffect(() => {
    if (account?.role !== "admin") return;
    let alive = true;
    syncDocTemplates()
      .catch((e) => { if (alive) setError(e.message || "Maquettes de documents non synchronisées."); });
    return () => { alive = false; };
  }, [account?.role]);

  // Clic sur une notification du téléphone : le service worker ouvre l'app sur
  // /?ecran=documents&mission=… — on route ici vers le bon écran.
  useEffect(() => {
    if (!account?.id) return;
    const params = new URLSearchParams(window.location.search);
    const ecran = params.get("ecran");
    const mission = params.get("mission");
    if (!ecran && !mission) return;

    // Différé d'un tick : on route APRÈS le rendu courant.
    queueMicrotask(() => {
    if (ecran === "documents") {
      if (account.role === "client") setClientTab("documents");
      else if (account.role === "transporter") setTransporterTab("documents");
      else setMode("admin");
    } else if (ecran === "frais") {
      if (account.role === "admin") { setMode("admin"); setAdminTab("frais"); }
      else setTransporterTab("frais");
    }
    if (mission) setFocusMissionId(mission);

    // On nettoie l'adresse pour ne pas rejouer la redirection au rafraîchissement.
    window.history.replaceState({}, "", window.location.pathname);
    });
  }, [account?.id, account?.role]);

  // Nombre de documents en attente de ma signature (pastille du menu).
  const [docsToSignCount, setDocsToSignCount] = useState(0);
  useEffect(() => {
    if (!account?.id) return undefined;
    let alive = true;
    async function count() {
      if (account.role === "admin") { if (alive) setDocsToSignCount(0); return; }
      try {
        const { count: n } = await supabase
          .from("documents")
          .select("id", { count: "exact", head: true })
          .eq("recipient_id", account.id)
          .eq("needs_signature", true)
          .eq("statut", "envoye");
        if (alive) setDocsToSignCount(n || 0);
      } catch { /* patch documents non encore appliqué : ignoré */ }
    }
    count();
    const channel = supabase
      .channel(`docs-count-${account.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "documents" }, () => { count(); })
      .subscribe();
    return () => { alive = false; supabase.removeChannel(channel); };
  }, [account?.id, account?.role]);

  // Défilement + surbrillance temporaire de la mission ciblée.
  useEffect(() => {
    if (!focusMissionId) return undefined;
    const scroll = setTimeout(() => {
      const el = document.getElementById(`mission-${focusMissionId}`);
      if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
    }, 220);
    const clear = setTimeout(() => setFocusMissionId(null), 6000);
    return () => { clearTimeout(scroll); clearTimeout(clear); };
  }, [focusMissionId]);

  async function handleEnablePush() {
    const res = await enablePush();
    if (res.ok) { setPushState("enabled"); setNotice("Notifications push activées sur cet appareil."); }
    else if (res.reason === "no_vapid") { setPushState("dismissed"); setNotice("Notifications temps réel actives. (Le push système sera disponible une fois les clés VAPID configurées.)"); }
    else if (res.reason === "denied") { setPushState("dismissed"); setError("Notifications refusées par le navigateur."); }
    else if (res.reason === "save_failed") {
      setPushState("idle");
      setError("L’appareil n’a pas pu être rattaché au compte. La boîte de notifications interne reste active.");
    } else setPushState("dismissed");
  }

  const unreadCount = useMemo(() => notifications.filter((n) => !n.isRead).length, [notifications]);

  /* ---------- Derived ---------- */
  const publishedMissions = useMemo(() => missions.filter((m) => m.status === "published"), [missions]);
  const assignedMissions = useMemo(() => missions.filter((m) => m.status === "assigned"), [missions]);
  const completedMissions = useMemo(() => missions.filter((m) => m.status === "completed"), [missions]);
  const pendingRequests = useMemo(() => requests.filter((r) => r.status === "pending"), [requests]);
  const pendingApplications = useMemo(() => applications.filter((a) => a.status === "pending"), [applications]);

  const clientMissions = useMemo(
    () => missions.filter((m) => m.clientAccountId === account?.id),
    [missions, account?.id]
  );

  const assignedToCurrentTransporter = useMemo(
    () => missions.filter((m) => m.assignedTransporterId === account?.id && ["assigned", "completed"].includes(m.status)),
    [missions, account?.id]
  );
  const currentTransporterApplications = useMemo(
    () => applications.filter((a) => a.transporterId === account?.id),
    [applications, account?.id]
  );
  const currentTransporterRequests = useMemo(
    () => requests.filter((r) => r.requesterId === account?.id),
    [requests, account?.id]
  );

  const activeAssignedMissions = useMemo(
    () => assignedMissions.filter((mission) => !isMissionDeliveryValidated(mission)),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [assignedMissions, trackingEvents]
  );
  const completedOrDeliveredMissions = useMemo(() => {
    const map = new Map();
    completedMissions.forEach((m) => map.set(m.id, m));
    assignedMissions.filter((m) => isMissionDeliveryValidated(m)).forEach((m) => map.set(m.id, m));
    return Array.from(map.values());
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [assignedMissions, completedMissions, trackingEvents]);

  const filteredTransporters = useMemo(() => {
    if (transporterFilter === "all") return transporters;
    return transporters.filter((t) => t.transporterType === transporterFilter);
  }, [transporters, transporterFilter]);

  const adminStats = useMemo(() => ({
    total: missions.length,
    published: publishedMissions.length,
    assigned: activeAssignedMissions.length,
    completed: completedOrDeliveredMissions.length,
    pendingRequests: pendingRequests.length,
    pendingApplications: pendingApplications.length,
  }), [missions.length, publishedMissions.length, activeAssignedMissions.length, completedOrDeliveredMissions.length, pendingRequests.length, pendingApplications.length]);

  /* ---------- Data loading ---------- */
  async function signDocuments(rows) {
    const mapped = (rows || []).map(documentFromDb);
    return Promise.all(mapped.map(async (document) => {
      if (!document.filePath) return document;
      const bucket = document.docType ? "documents-pdf" : "documents";
      try {
        return {
          ...document,
          fileUrl: await createShortSignedUrl(bucket, document.filePath, 120),
        };
      } catch {
        return { ...document, fileUrl: null };
      }
    }));
  }

  async function loadAllData(currentAccount = account, { silent = false } = {}) {
    if (!currentAccount) return;
    const accountId = currentAccount.id;
    const generation = ++dataGenerationRef.current;
    const isCurrentLoad = () => (
      generation === dataGenerationRef.current
      && accountRef.current?.id === accountId
    );
    if (!silent) {
      setLoading(true);
      setError("");
    }

    try {
      if (currentAccount.role === "admin") {
        const [missionsResult, requestsResult, applicationsResult, transportersResult, documentsResult, trackingEventsResult, trackingPhotosResult] = await Promise.all([
          supabase.from("secoto_missions_admin_v2").select(MISSION_ADMIN_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("mission_requests").select(REQUEST_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("mission_applications").select(APPLICATION_COLUMNS).order("proposed_price", { ascending: true, nullsFirst: false }).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("accounts").select("id,role,full_name,company_name,email,phone,city,status,docs_count,is_verified,transporter_type,client_type,created_at").eq("role", "transporter").order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("documents").select(DOCUMENT_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("mission_tracking_events").select(TRACKING_EVENT_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("mission_tracking_photos").select(TRACKING_PHOTO_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
        ]);
        for (const r of [missionsResult, requestsResult, applicationsResult, transportersResult, documentsResult, trackingEventsResult, trackingPhotosResult]) {
          if (r.error) throw r.error;
        }
        const [signedDocuments, signedPhotos] = await Promise.all([
          signDocuments(documentsResult.data),
          hydrateSignedFileUrls((trackingPhotosResult.data || []).map(trackingPhotoFromDb), "mission-photos", 120),
        ]);
        if (!isCurrentLoad()) return;
        setMissions((missionsResult.data || []).map(missionFromDb));
        setPublicMissions([]);
        setRequests((requestsResult.data || []).map(requestFromDb));
        setApplications((applicationsResult.data || []).map(applicationFromDb));
        setTransporters((transportersResult.data || []).map(accountFromDb));
        setDocuments(signedDocuments);
        setTrackingEvents((trackingEventsResult.data || []).map(trackingEventFromDb));
        setTrackingPhotos(signedPhotos);
      } else if (currentAccount.role === "client") {
        const [missionsResult, trackingEventsResult, trackingPhotosResult] = await Promise.all([
          supabase.from("secoto_missions_client_v2").select(MISSION_CLIENT_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("mission_tracking_events").select(TRACKING_EVENT_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("mission_tracking_photos").select(TRACKING_PHOTO_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
        ]);
        for (const r of [missionsResult, trackingEventsResult, trackingPhotosResult]) { if (r.error) throw r.error; }
        const signedPhotos = await hydrateSignedFileUrls(
          (trackingPhotosResult.data || []).map(trackingPhotoFromDb),
          "mission-photos",
          120,
        );
        if (!isCurrentLoad()) return;
        setMissions((missionsResult.data || []).map(missionFromDb));
        setTrackingEvents((trackingEventsResult.data || []).map(trackingEventFromDb));
        setTrackingPhotos(signedPhotos);
        setPublicMissions([]); setRequests([]); setApplications([]); setTransporters([]); setDocuments([]);
      } else {
        const [publicResult, privateResult, requestsResult, applicationsResult, documentsResult, trackingEventsResult, trackingPhotosResult] = await Promise.all([
          supabase.from("secoto_public_missions_v2").select(PUBLIC_MISSION_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("secoto_missions_transporter_v2").select(MISSION_TRANSPORTER_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("mission_requests").select(REQUEST_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("mission_applications").select(APPLICATION_COLUMNS).order("proposed_price", { ascending: true, nullsFirst: false }).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("documents").select(DOCUMENT_COLUMNS).eq("account_id", currentAccount.id).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("mission_tracking_events").select(TRACKING_EVENT_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
          supabase.from("mission_tracking_photos").select(TRACKING_PHOTO_COLUMNS).order("created_at", { ascending: false }).limit(DATA_PAGE_SIZE),
        ]);
        for (const r of [publicResult, privateResult, requestsResult, applicationsResult, documentsResult, trackingEventsResult, trackingPhotosResult]) {
          if (r.error) throw r.error;
        }
        const [signedDocuments, signedPhotos] = await Promise.all([
          signDocuments(documentsResult.data),
          hydrateSignedFileUrls((trackingPhotosResult.data || []).map(trackingPhotoFromDb), "mission-photos", 120),
        ]);
        if (!isCurrentLoad()) return;
        setPublicMissions((publicResult.data || []).map(publicMissionFromDb));
        setMissions((privateResult.data || []).map(missionFromDb));
        setRequests((requestsResult.data || []).map(requestFromDb));
        setApplications((applicationsResult.data || []).map(applicationFromDb));
        setTransporters([]);
        setDocuments(signedDocuments);
        setTrackingEvents((trackingEventsResult.data || []).map(trackingEventFromDb));
        setTrackingPhotos(signedPhotos);
      }
    } catch (err) {
      if (isCurrentLoad() && !silent) {
        setError(err.message || "Erreur lors du chargement Supabase.");
      }
    } finally {
      if (isCurrentLoad() && !silent) setLoading(false);
    }
  }

  /* ---------- Actions ADMIN ---------- */
  async function createMission(e) {
    e.preventDefault(); setError(""); setNotice("");
    try {
      await runLocked("mission:create:admin", async () => {
        const payload = missionToDb(missionForm, { status: "published", createdByRole: "admin" });
        delete payload.public_ref;
        const { data, error } = await supabase.rpc("secoto_create_mission", {
          p_payload: payload,
          p_idempotency_key: randomIdempotencyKey(),
        });
        if (error) throw error;
        const created = missionFromDb(Array.isArray(data) ? data[0] : data);
        setMissions((prev) => [created, ...prev.filter((mission) => mission.id !== created.id)]);
        setMissionForm(emptyMissionForm);
        setNotice("Mission publiée avec succès.");
        setAdminTab("published");
      });
    } catch (err) { setError(err.message || "Erreur lors de la création de mission."); }
  }

  /* ---------- Actions CLIENT ---------- */
  async function createClientCourse(e) {
    e.preventDefault(); setError(""); setNotice("");
    try {
      await runLocked("mission:create:client", async () => {
        const enriched = {
          ...clientForm,
          clientName: clientForm.clientName || account.fullName || account.companyName || "",
          clientContact: clientForm.clientContact || account.email || "",
          clientPhone: clientForm.clientPhone || account.phone || "",
        };
        const payload = missionToDb(enriched, {
          status: "published",
          createdByRole: "client",
          clientAccountId: account.id,
        });
        delete payload.public_ref;
        delete payload.client_account_id;
        const { data, error } = await supabase.rpc("secoto_create_client_mission", {
          p_payload: payload,
          p_idempotency_key: randomIdempotencyKey(),
        });
        if (error) throw error;
        const created = missionFromDb(Array.isArray(data) ? data[0] : data);
        setMissions((prev) => [created, ...prev.filter((mission) => mission.id !== created.id)]);
        setClientForm(emptyMissionForm);
        setNotice("Votre course est publiée et visible par les transporteurs.");
        setClientTab("courses");
      });
    } catch (err) { setError(err.message || "Erreur lors de la publication de la course."); }
  }

  async function createMissionRequest(e) {
    e.preventDefault(); setError(""); setNotice("");
    try {
      await runLocked("request:create", async () => {
        if (!account?.isVerified) throw new Error("Votre compte transporteur doit être vérifié pour proposer une mission.");
        const payload = requestToDb(requestForm, account);
        delete payload.public_ref;
        delete payload.requester_id;
        delete payload.requester_name;
        delete payload.requester_company;
        const { data, error } = await supabase.rpc("secoto_create_transporter_request", {
          p_payload: payload,
          p_idempotency_key: randomIdempotencyKey(),
        });
        if (error) throw error;
        const created = requestFromDb(Array.isArray(data) ? data[0] : data);
        setRequests((prev) => [created, ...prev.filter((request) => request.id !== created.id)]);
        setRequestForm(emptyMissionForm);
        setNotice("Demande envoyée à SECOTO pour validation.");
        setTransporterTab("requests");
      });
    } catch (err) { setError(err.message || "Erreur lors de la demande de mise en ligne."); }
  }

  async function applyToMission(missionId) {
    setError(""); setNotice("");
    try {
      await runLocked(`application:${missionId}`, async () => {
        if (!account?.isVerified) throw new Error("Votre compte transporteur doit être vérifié par SECOTO pour candidater.");
        const alreadyApplied = applications.some((a) => a.missionId === missionId && a.transporterId === account.id);
        if (alreadyApplied) throw new Error("Vous avez déjà candidaté à cette mission.");
        const rawPrice = applicationPrices[missionId];
        const proposedPrice = Number(rawPrice);
        if (!rawPrice || Number.isNaN(proposedPrice) || proposedPrice <= 0) throw new Error("Veuillez indiquer un tarif proposé valide.");
        const { data, error } = await supabase.rpc("secoto_apply_to_mission", {
          p_mission_id: missionId,
          p_proposed_price: proposedPrice,
          p_message: applicationMessages[missionId] || null,
          p_idempotency_key: randomIdempotencyKey(),
        });
        if (error) throw error;
        const created = applicationFromDb(Array.isArray(data) ? data[0] : data);
        setApplications((prev) => [created, ...prev.filter((application) => application.id !== created.id)]);
        setApplicationMessages((prev) => ({ ...prev, [missionId]: "" }));
        setApplicationPrices((prev) => ({ ...prev, [missionId]: "" }));
        setNotice("Candidature envoyée avec votre tarif.");
        setTransporterTab("applications");
      });
    } catch (err) { setError(err.message || "Erreur lors de la candidature."); }
  }

  async function assignMission(missionId, application) {
    setError(""); setNotice("");
    try {
      await runLocked(`mission:assign:${missionId}`, async () => {
        const { error } = await supabase.rpc("secoto_assign_mission", {
          p_mission_id: missionId,
          p_application_id: application.id,
          p_idempotency_key: randomIdempotencyKey(),
        });
        if (error) throw error;
        await loadAllData(account);
        setNotice("Mission attribuée. Le devis part au client et le bon de mission suivra dès sa signature.");
        setAdminTab("assigned");
      });
    } catch (err) { setError(err.message || "Erreur lors de l’attribution."); }
  }

  async function markMissionCompleted(missionId) {
    setError(""); setNotice("");
    try {
      await runLocked(`mission:complete:${missionId}`, async () => {
        const { error } = await supabase.rpc("secoto_transition_mission", {
          p_mission_id: missionId,
          p_target_status: "completed",
          p_idempotency_key: randomIdempotencyKey(),
        });
        if (error) throw error;
        await loadAllData(account);
        setNotice("Mission marquée comme terminée.");
        setAdminTab("completed");
      });
    } catch (err) { setError(err.message || "Erreur lors du changement de statut."); }
  }

  async function deleteMission(missionId, { confirmLabel = "Supprimer définitivement cette annonce ?" } = {}) {
    if (typeof window !== "undefined" && !window.confirm(confirmLabel)) return;
    setError(""); setNotice("");
    try {
      await runLocked(`mission:delete:${missionId}`, async () => {
        const { error } = await supabase.rpc("secoto_delete_unstarted_mission", {
          p_mission_id: missionId,
          p_idempotency_key: randomIdempotencyKey(),
        });
        if (error) throw error;
        setMissions((prev) => prev.filter((m) => m.id !== missionId));
        setNotice("Annonce supprimée.");
      });
    } catch (err) {
      setError(err.message || "Erreur lors de la suppression de l’annonce.");
    }
  }

  async function approveRequest(request) {
    setError(""); setNotice("");
    try {
      await runLocked(`request:approve:${request.id}`, async () => {
        const { error } = await supabase.rpc("secoto_approve_request", {
          p_request_id: request.id,
          p_idempotency_key: randomIdempotencyKey(),
        });
        if (error) throw error;
        await loadAllData(account);
        setNotice("Demande validée et mission publiée.");
        setAdminTab("published");
      });
    } catch (err) { setError(err.message || "Erreur lors de la validation de la demande."); }
  }

  async function rejectRequest(requestId) {
    setError(""); setNotice("");
    try {
      await runLocked(`request:reject:${requestId}`, async () => {
        const { error } = await supabase.rpc("secoto_reject_request", {
          p_request_id: requestId,
          p_idempotency_key: randomIdempotencyKey(),
        });
        if (error) throw error;
        await loadAllData(account);
        setNotice("Demande refusée.");
      });
    } catch (err) { setError(err.message || "Erreur lors du refus de la demande."); }
  }

  async function updateTransporterStatus(transporterId, updates) {
    setError(""); setNotice("");
    try {
      await runLocked(`transporter:status:${transporterId}`, async () => {
        const { error } = await supabase.rpc("secoto_admin_set_transporter_status", {
          p_transporter_id: transporterId,
          p_status: updates.status,
          p_is_verified: Boolean(updates.is_verified),
          p_docs_count: Number.isFinite(updates.docs_count) ? updates.docs_count : null,
          p_idempotency_key: randomIdempotencyKey(),
        });
        if (error) throw error;
        await loadAllData(account);
        setNotice("Statut transporteur mis à jour.");
      });
    } catch (err) { setError(err.message || "Erreur lors de la mise à jour du transporteur."); }
  }

  async function updateDocumentStatus(documentId, status) {
    setError(""); setNotice("");
    try {
      await runLocked(`document:status:${documentId}`, async () => {
        const { error } = await supabase.rpc("secoto_admin_set_document_status", {
          p_document_id: documentId,
          p_status: status,
          p_idempotency_key: randomIdempotencyKey(),
        });
        if (error) throw error;
        await loadAllData(account);
        setNotice("Document mis à jour.");
      });
    } catch (err) { setError(err.message || "Erreur lors de la mise à jour du document."); }
  }

  async function uploadTransporterDocument() {
    if (!account || documentFiles.length !== 1) {
      setError("Sélectionnez une pièce avant l’envoi.");
      return;
    }
    const validation = validateFiles(documentFiles, {
      allowPdf: true,
      maxFiles: 1,
      maxSizeBytes: 12 * 1024 * 1024,
      minFiles: 1,
    });
    if (!validation.ok) {
      setError(validation.errors.join(" "));
      return;
    }
    setError(""); setNotice("");
    try {
      await runLocked("document:upload", async () => {
        const file = documentFiles[0];
        const path = await buildPrivateFilePath({
          accountId: account.id,
          operationId: documentOperationId,
          index: 0,
          file,
        });
        setUploadProgress((previous) => ({ ...previous, document: 0 }));
        await uploadPrivateFile({
          bucket: "documents",
          path,
          file,
          onProgress: (progress) => setUploadProgress((previous) => ({ ...previous, document: progress })),
        });
        const { data, error } = await supabase.rpc("secoto_register_transporter_document", {
          p_document_type: documentType,
          p_file_name: file.name,
          p_file_path: path,
          p_mime_type: file.type,
          p_size_bytes: file.size,
          p_idempotency_key: documentOperationId,
        });
        if (error) throw error;
        const mapped = documentFromDb(Array.isArray(data) ? data[0] : data);
        const signed = {
          ...mapped,
          fileUrl: await createShortSignedUrl("documents", path, 120),
        };
        setDocuments((previous) => [signed, ...previous.filter((document) => document.id !== signed.id)]);
        setDocumentFiles([]);
        setDocumentOperationId(randomIdempotencyKey());
        setUploadProgress((previous) => ({ ...previous, document: null }));
        setNotice("Pièce justificative envoyée.");
      });
    } catch (err) {
      setError(err.message || "Erreur lors de l’envoi du document. Vous pouvez réessayer sans créer de doublon.");
    }
  }

  // Pièces justificatives déposées par un compte (jamais les documents générés).
  function getDocumentsForAccount(accountId) {
    return documents.filter((doc) => doc.accountId === accountId && !doc.docType);
  }
  // Documents générés pour une mission (devis / bon de mission / facture).
  function getGeneratedDocs(missionId) {
    return documents.filter((doc) => doc.missionId === missionId && doc.docType);
  }
  function getTrackingEventsForMission(missionId) { return trackingEvents.filter((event) => event.missionId === missionId); }
  function getTrackingPhotosForEvent(eventId) { return trackingPhotos.filter((photo) => photo.trackingEventId === eventId); }
  function trackingKey(missionId, eventType) { return `${missionId}-${eventType}`; }

  function getTrackingForm(missionId, eventType) {
    return trackingForms[trackingKey(missionId, eventType)] || {
      comment: "",
      odometerKm: "",
      fuelLevel: "unknown",
      issueType: "autre",
      issueSeverity: "moyen",
      photoType: "general",
      files: [],
      location: null,
      operationId: null,
    };
  }
  function updateTrackingForm(missionId, eventType, patch) {
    const key = trackingKey(missionId, eventType);
    const next = {
      ...getTrackingForm(missionId, eventType),
      ...patch,
    };
    setTrackingForms((prev) => ({ ...prev, [key]: next }));
    if (account?.id) {
      const owner = account.id;
      const previousTimer = draftTimersRef.current.get(key);
      if (previousTimer) clearTimeout(previousTimer);
      draftTimersRef.current.set(key, setTimeout(() => {
        draftTimersRef.current.delete(key);
        saveTrackingDraft(owner, missionId, eventType, next).catch(() => {
          if (accountRef.current?.id === owner) {
            setError("Le brouillon reste utilisable, mais sa sauvegarde chiffrée a échoué.");
          }
        });
      }, 350));
    }
  }

  async function captureTrackingLocation(missionId, eventType) {
    setNotice("La position est facultative et sera capturée une seule fois pour cette étape.");
    const result = await getOneTimeLocation();
    if (!result.ok) {
      setNotice("");
      if (result.reason === "denied") {
        setError("Position refusée : vous pouvez continuer et saisir les informations manuellement.");
      } else {
        setError("Position indisponible : le parcours reste utilisable sans géolocalisation.");
      }
      return;
    }
    updateTrackingForm(missionId, eventType, { location: result });
    setError("");
    setNotice("Position ponctuelle ajoutée à cette étape.");
  }

  async function refreshPendingSyncCount() {
    if (!account?.id) return;
    try {
      const pending = await listPendingActions(account.id);
      setPendingSyncCount(pending.length);
    } catch {
      setPendingSyncCount(0);
    }
  }

  async function submitTrackingEvent(mission, eventType, { fromQueue = false } = {}) {
    const form = getTrackingForm(mission.id, eventType);
    const files = form.files || [];
    const requiresProof = eventType === "pickup_inspection" || eventType === "delivery_inspection";
    const validation = validateFiles(files, {
      allowPdf: eventType === "road_incident",
      maxFiles: 10,
      maxSizeBytes: 12 * 1024 * 1024,
      minFiles: requiresProof ? 1 : 0,
      requireImage: requiresProof,
    });
    if (!validation.ok) {
      setError(validation.errors.join(" "));
      return false;
    }

    const operationId = form.operationId || randomIdempotencyKey();
    if (!form.operationId) updateTrackingForm(mission.id, eventType, { operationId });
    setError(""); setNotice("");

    if (typeof navigator !== "undefined" && !navigator.onLine) {
      await queueTrackingAction(account.id, mission.id, eventType, operationId);
      await saveTrackingDraft(account.id, mission.id, eventType, { ...form, operationId });
      await refreshPendingSyncCount();
      setNotice("Hors ligne : l’étape et ses photos sont chiffrées sur l’appareil et seront reprises au retour du réseau.");
      return false;
    }

    try {
      const result = await runLocked(`tracking:${mission.id}:${eventType}`, async () => {
        const progressKey = `${mission.id}:${eventType}`;
        const uploadedFiles = [];
        for (let index = 0; index < files.length; index += 1) {
          const file = files[index];
          const path = await buildPrivateFilePath({
            accountId: account.id,
            missionId: mission.id,
            operationId,
            index,
            file,
          });
          await uploadPrivateFile({
            bucket: "mission-photos",
            path,
            file,
            onProgress: (fileProgress) => {
              const aggregate = Math.round(((index + fileProgress / 100) / Math.max(files.length, 1)) * 100);
              setUploadProgress((previous) => ({ ...previous, [progressKey]: aggregate }));
            },
          });
          uploadedFiles.push({
            file_name: file.name,
            file_path: path,
            photo_type: form.photoType || "general",
            mime_type: file.type,
            size_bytes: file.size,
          });
        }

        const location = form.location || null;
        const { error: rpcError } = await supabase.rpc("secoto_finalize_tracking_event", {
          p_mission_id: mission.id,
          p_event_type: eventType,
          p_payload: {
            comment: form.comment || null,
            odometer_km: form.odometerKm ? Number(form.odometerKm) : null,
            fuel_level: form.fuelLevel || "unknown",
            issue_type: eventType === "road_incident" ? form.issueType : null,
            issue_severity: eventType === "road_incident" ? form.issueSeverity : null,
            latitude: location?.latitude ?? null,
            longitude: location?.longitude ?? null,
            location_accuracy_m: location?.accuracy ?? null,
            expected_progress_status: progressFromTrackingEvent(eventType),
          },
          p_files: uploadedFiles,
          p_idempotency_key: operationId,
        });
        if (rpcError) throw rpcError;

        const draftKey = trackingKey(mission.id, eventType);
        const draftTimer = draftTimersRef.current.get(draftKey);
        if (draftTimer) clearTimeout(draftTimer);
        draftTimersRef.current.delete(draftKey);
        await removeTrackingDraft(account.id, mission.id, eventType).catch(() => {});
        await removeEncryptedRecord(`queue:${account.id}:${operationId}`).catch(() => {});
        setTrackingForms((previous) => {
          const next = { ...previous };
          delete next[trackingKey(mission.id, eventType)];
          return next;
        });
        setUploadProgress((previous) => ({ ...previous, [progressKey]: null }));
        await refreshPendingSyncCount();
        await loadAllData(account);
        setNotice(
          eventType === "delivery_inspection"
            ? "Livraison validée et état des lieux d’arrivée transmis."
            : `${labelTrackingEventType(eventType)} transmis.`,
        );
        return true;
      });
      return Boolean(result && !result.skipped);
    } catch (err) {
      const networkError =
        (typeof navigator !== "undefined" && !navigator.onLine) ||
        err instanceof TypeError ||
        /network|réseau|fetch|interrompu|timeout/i.test(err?.message || "");
      if (networkError) {
        await queueTrackingAction(account.id, mission.id, eventType, operationId).catch(() => {});
        await saveTrackingDraft(account.id, mission.id, eventType, { ...form, operationId }).catch(() => {});
        await refreshPendingSyncCount();
        setNotice("Envoi interrompu : les éléments restent chiffrés sur l’appareil et seront réessayés.");
        if (!fromQueue) setError("");
      } else {
        setError(err.message || "Erreur lors de l’envoi du suivi mission.");
      }
      return false;
    }
  }

  async function resumePendingTrackingActions() {
    if (!account?.id || !networkConnected || pendingSyncRef.current) return;
    pendingSyncRef.current = true;
    try {
      const pending = await listPendingActions(account.id);
      setPendingSyncCount(pending.length);
      for (const item of pending) {
        const action = item.value;
        if (action?.type !== "tracking") continue;
        let mission = missions.find((candidate) => candidate.id === action.missionId);
        if (!mission) {
          const { data } = await supabase
            .from("secoto_missions_transporter_v2")
            .select(MISSION_TRANSPORTER_COLUMNS)
            .eq("id", action.missionId)
            .maybeSingle();
          mission = data ? missionFromDb(data) : null;
        }
        if (!mission || isMissionDeliveryValidated(mission)) {
          await removeEncryptedRecord(item.key).catch(() => {});
          await removeTrackingDraft(account.id, action.missionId, action.eventType).catch(() => {});
          continue;
        }
        await submitTrackingEvent(mission, action.eventType, { fromQueue: true });
      }
      await refreshPendingSyncCount();
    } finally {
      pendingSyncRef.current = false;
    }
  }

  useEffect(() => {
    if (!account?.id || !networkConnected || pendingSyncCount === 0 || missions.length === 0) return undefined;
    const timer = setTimeout(() => {
      resumePendingTrackingActions().catch(() => {});
    }, 600);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [account?.id, networkConnected, pendingSyncCount, missions.length]);

  function hasDeliveryInspection(missionId) {
    return trackingEvents.some((event) => event.missionId === missionId && event.eventType === "delivery_inspection");
  }
  function isMissionDeliveryValidated(mission) {
    return mission.progressStatus === "delivery_completed" || mission.progressStatus === "completed" || mission.status === "completed" || hasDeliveryInspection(mission.id);
  }

  function renderTrackingTimeline(mission) {
    const events = getTrackingEventsForMission(mission.id);
    return (
      <div className="applications-box">
        <h4>Suivi & preuves terrain</h4>
        {events.length === 0 && <p className="muted">Aucun suivi transmis pour cette mission.</p>}
        {events.map((event) => {
          const photos = getTrackingPhotosForEvent(event.id);
          return (
            <div className="mission-card" key={event.id}>
              <div className="card-top">
                <span className="badge">{labelTrackingEventType(event.eventType)}</span>
                <span className="status">{formatDateTime(event.createdAt)}</span>
              </div>
              <div className="card-section">
                {event.odometerKm && <p><strong>Kilométrage :</strong> {event.odometerKm} km</p>}
                <p><strong>Carburant :</strong> {labelFuelLevel(event.fuelLevel)}</p>
                {event.issueType && <p><strong>Problème :</strong> {event.issueType} — {event.issueSeverity}</p>}
                <p><strong>Commentaire :</strong> {event.comment || "Aucun commentaire"}</p>
              </div>
              <div className="cards" style={{ marginTop: 12 }}>
                {photos.length === 0 && <p className="muted">Aucune photo jointe.</p>}
                {photos.map((photo) => {
                  const isImage = /\.(png|jpg|jpeg|webp|gif)$/i.test(photo.fileName || photo.fileUrl || "");
                  return (
                    <article className="mission-card" key={photo.id}>
                      <div className="card-top">
                        <span className="badge">{photo.photoType || "photo"}</span>
                        <a className="btn ghost small" href={photo.fileUrl} target="_blank" rel="noreferrer">Ouvrir</a>
                      </div>
                      {isImage && (
                        <a href={photo.fileUrl} target="_blank" rel="noreferrer">
                          <img src={photo.fileUrl} alt={photo.fileName || "Photo état des lieux"} style={{ width: "100%", maxHeight: 220, objectFit: "cover", borderRadius: 16, marginTop: 12, border: "1px solid var(--border)" }} />
                        </a>
                      )}
                      <p className="muted" style={{ marginTop: 10 }}>{photo.fileName}</p>
                    </article>
                  );
                })}
              </div>
            </div>
          );
        })}
      </div>
    );
  }

  function renderTrackingForm(mission, eventType) {
    const form = getTrackingForm(mission.id, eventType);
    const isIncident = eventType === "road_incident";
    const isDelivery = eventType === "delivery_inspection";
    const body = (
      <div className="form-grid track-form" style={{ marginTop: 12 }}>
        <Field label="Kilométrage" name="odometerKm" type="number" value={form.odometerKm} onChange={(e) => updateTrackingForm(mission.id, eventType, { odometerKm: e.target.value })} />
        <label className="field">
          <span>Niveau carburant</span>
          <select value={form.fuelLevel} onChange={(e) => updateTrackingForm(mission.id, eventType, { fuelLevel: e.target.value })}>
            <option value="unknown">Non renseigné</option>
            <option value="reserve">Réserve</option>
            <option value="1/4">1/4</option>
            <option value="1/2">1/2</option>
            <option value="3/4">3/4</option>
            <option value="full">Plein</option>
          </select>
        </label>
        {isIncident && (
          <>
            <label className="field">
              <span>Type de problème</span>
              <select value={form.issueType} onChange={(e) => updateTrackingForm(mission.id, eventType, { issueType: e.target.value })}>
                <option value="panne">Panne</option>
                <option value="accident">Accident</option>
                <option value="retard">Retard</option>
                <option value="client_absent">Client absent</option>
                <option value="document_manquant">Document manquant</option>
                <option value="dommage_constate">Dommage constaté</option>
                <option value="probleme_mecanique">Problème mécanique</option>
                <option value="autre">Autre</option>
              </select>
            </label>
            <label className="field">
              <span>Gravité</span>
              <select value={form.issueSeverity} onChange={(e) => updateTrackingForm(mission.id, eventType, { issueSeverity: e.target.value })}>
                <option value="faible">Faible</option>
                <option value="moyen">Moyen</option>
                <option value="important">Important</option>
                <option value="critique">Critique</option>
              </select>
            </label>
          </>
        )}
        <SecureFilePicker
          files={form.files}
          onChange={(files) => updateTrackingForm(mission.id, eventType, { files })}
          label={`Photos${isDelivery ? " de livraison" : ""}${isIncident ? " / justificatifs" : " (au moins une photo obligatoire)"}`}
          allowPdf={isIncident}
          maxFiles={10}
          disabled={actionLoading}
          progress={uploadProgress[`${mission.id}:${eventType}`]}
        />
        <div className="field field-full location-box">
          <span>Position ponctuelle (facultative)</span>
          <small>Uniquement au moment de cette prise en charge, de cet incident ou de cette livraison. Aucun suivi en arrière-plan.</small>
          <div className="actions-row">
            <button
              className="btn ghost small"
              type="button"
              onClick={() => captureTrackingLocation(mission.id, eventType)}
              disabled={actionLoading}
            >
              {form.location ? "Actualiser la position" : "Ajouter ma position"}
            </button>
            {form.location && (
              <span className="status status-accepted">
                Position ajoutée · précision {Math.round(form.location.accuracy || 0)} m
              </span>
            )}
          </div>
        </div>
        <label className="field field-full">
          <span>Commentaire</span>
          <textarea value={form.comment} onChange={(e) => updateTrackingForm(mission.id, eventType, { comment: e.target.value })} placeholder="État du véhicule, réserves ou problème constaté." />
        </label>
        {isDelivery ? (
          <button className="btn primary field-full track-submit deliver" type="button" disabled={actionLoading} onClick={() => submitTrackingEvent(mission, eventType)}>
            Valider la livraison
          </button>
        ) : (
          <button className="btn primary field-full track-submit" type="button" disabled={actionLoading} onClick={() => submitTrackingEvent(mission, eventType)}>
            Transmettre {labelTrackingEventType(eventType)}
          </button>
        )}
      </div>
    );

    // Incident : occasionnel -> replie derriere un triangle rouge, deplie au clic.
    if (isIncident) {
      return (
        <details className="incident-block">
          <summary className="incident-summary">
            <svg className="tri" viewBox="0 0 24 24" width="20" height="20" aria-hidden="true">
              <path d="M12 3.4 22.3 21H1.7z" />
              <path d="M12 10.2v4.4" stroke="#fff" strokeWidth="2" strokeLinecap="round" fill="none" />
              <circle cx="12" cy="17.6" r="1.05" fill="#fff" stroke="none" />
            </svg>
            <span className="incident-label">Signaler un incident</span>
            <span className="incident-hint">occasionnel</span>
            <span className="incident-caret" aria-hidden="true">+</span>
          </summary>
          {body}
        </details>
      );
    }

    return (
      <div className="track-card">
        <div className="track-head"><h3>{labelTrackingEventType(eventType)}</h3></div>
        {body}
      </div>
    );
  }

  async function openPrivateDocument(doc) {
    try {
      setError(""); setNotice("");
      if (!doc?.filePath) throw new Error("Chemin du document introuvable.");
      const bucket = doc.docType ? "documents-pdf" : "documents";
      const signedUrl = await createShortSignedUrl(bucket, doc.filePath, 120);
      await shareOrOpen({
        title: doc.fileName || "Document SECOTO",
        text: "Document SECOTO — lien temporaire sécurisé",
        url: signedUrl,
      });
    } catch (err) { setError(err.message || "Impossible d’ouvrir le document sécurisé."); }
  }

  async function signOut() {
    accountLoadGenerationRef.current += 1;
    dataGenerationRef.current += 1;
    notificationGenerationRef.current += 1;
    for (const timer of draftTimersRef.current.values()) clearTimeout(timer);
    draftTimersRef.current.clear();
    const owner = account?.id;
    await disablePush(account?.id);
    await supabase.auth.signOut();
    supabase.removeAllChannels();
    if (owner) await clearEncryptedAccountData(owner).catch(() => {});
    setSession(null); setAccount(null);
    setMissions([]); setPublicMissions([]); setRequests([]); setApplications([]);
    setTransporters([]); setDocuments([]); setTrackingEvents([]); setTrackingPhotos([]);
    setTrackingForms({}); setNotifications([]);
    setPushState("idle");
  }

  // Suppression via une fonction serveur authentifiee : Storage, donnees
  // personnelles, tokens et Auth sont traites sans exposer service_role.
  async function deleteAccount() {
    const ok = window.confirm(
      "Supprimer définitivement votre compte et vos données ? Cette action est irréversible."
    );
    if (!ok) return;
    const confirmation = window.prompt("Pour confirmer, saisissez SUPPRIMER");
    if (confirmation !== "SUPPRIMER") {
      setError("Suppression annulée : confirmation incorrecte.");
      return;
    }
    setError("");
    try {
      const { data } = await supabase.auth.getSession();
      const accessToken = data?.session?.access_token;
      if (!accessToken) throw new Error("Session expirée. Reconnectez-vous avant cette action.");
      const response = await fetch(getServerFunctionUrl("request-account-deletion"), {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify({ idempotencyKey: randomIdempotencyKey() }),
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload.error || "Demande de suppression refusée.");
      await signOut();
      window.alert("Votre demande est enregistrée. Les données non soumises à conservation sont supprimées ; les pièces légales sont anonymisées et conservées selon la durée annoncée.");
    } catch (e) {
      setError(e.message || "Suppression du compte impossible. Réessayez ou contactez le support.");
    }
  }

  function getMissionApplications(missionId) {
    return applications.filter((a) => a.missionId === missionId).sort((a, b) => Number(a.proposedPrice || 999999) - Number(b.proposedPrice || 999999));
  }
  function hasCurrentTransporterApplied(missionId) {
    return applications.some((a) => a.missionId === missionId && a.transporterId === account?.id);
  }

  function renderMissionCard(mission, options = {}) {
    const missionApplications = getMissionApplications(mission.id);
    // La liste est déjà triée du moins cher au plus cher : la 1re ligne avec un
    // tarif renseigné est donc la meilleure offre.
    const bestApplicationId = missionApplications.find((a) => Number(a.proposedPrice) > 0)?.id || null;
    return (
      <article
        className={`mission-card ${focusMissionId === mission.id ? "is-focused" : ""}`}
        key={mission.id}
        id={`mission-${mission.id}`}
      >
        <div className="card-top">
          <span className="badge">{mission.publicRef}</span>
          <span className={`status status-${mission.status}`}>{labelStatus(mission.status)}</span>
        </div>
        <h3>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
        <PublicMissionInfo mission={mission} />
        {options.showPrivate && <PrivateMissionInfo mission={mission} showPricing={isAdmin && !!options.showPricing} />}
        {mission.assignedTransporterName && <p className="assigned">Transporteur attribué : {mission.assignedTransporterName}</p>}
        {options.canComplete && mission.status === "assigned" && (
          <button className="btn primary" onClick={() => markMissionCompleted(mission.id)}>Marquer terminée</button>
        )}
        {options.canDelete && (
          <div className="actions-row">
            <button className="btn danger small" onClick={() => deleteMission(mission.id)}>Supprimer l’annonce</button>
          </div>
        )}
        {options.showApplications && (
          <div className="applications-box">
            <h4>Candidatures {missionApplications.length > 1 && <span className="muted" style={{ fontWeight: 500 }}>· triées du moins cher au plus cher</span>}</h4>
            {missionApplications.length === 0 && <p className="muted">Aucune candidature.</p>}
            {missionApplications.map((application) => (
              <div className={`application-row ${application.id === bestApplicationId ? "is-best" : ""}`} key={application.id}>
                <div>
                  <strong>{application.transporterName}</strong>
                  {application.id === bestApplicationId && <span className="best-price-badge">Meilleur prix</span>}
                  <p className="muted">{application.transporterCompany} — {application.transporterStatus}</p>
                  <p className="price-line"><strong>Tarif proposé :</strong> {application.proposedPrice ? `${Number(application.proposedPrice).toFixed(0)} €` : "Non renseigné"}</p>
                  {application.message && <p>{application.message}</p>}
                  <span className={`status status-${application.status}`}>{labelStatus(application.status)}</span>
                </div>
                {mission.status === "published" && application.status === "pending" && (
                  <button className="btn primary small" onClick={() => assignMission(mission.id, application)}>Attribuer</button>
                )}
              </div>
            ))}
          </div>
        )}
        {options.showTracking && renderTrackingTimeline(mission)}
        {isAdmin && options.showPrivate && (
          <div className="actions-row" style={{ marginTop: 12, flexWrap: "wrap" }}>
            <span className="muted" style={{ width: "100%", fontSize: "0.8rem" }}>Documents :</span>
            <button className="btn ghost small" onClick={() => openMissionDoc("devis", mission)}>Devis</button>
            <button className="btn ghost small" onClick={() => openMissionDoc("bon", mission)}>Bon de mission</button>
            <button className="btn ghost small" onClick={() => openMissionDoc("facture", mission)}>Facture</button>
          </div>
        )}
      </article>
    );
  }

  // Ouvre la fenêtre "Documents" : champs remplissables, aperçu A4, impression
  // PDF et téléchargement — le tout DANS l'app (bouton Fermer toujours visible).
  function openMissionDoc(kind, mission) {
    const t = transporters.find((x) => x.id === mission.assignedTransporterId);
    setDocModal({
      kind,
      mission,
      transporter: {
        name: t?.fullName || mission.assignedTransporterName || "",
        address: t?.city || "",
        siret: "",
        phone: t?.phone || "",
      },
    });
  }

  // Envoi (ou renvoi) du devis au client + préparation du bon de mission.
  // Rejouable à tout moment depuis la fiche mission : si l'envoi automatique
  // au moment de l'attribution a échoué, un clic suffit à le relancer.
  async function sendMissionDocs(mission) {
    setActionLoading(true); setError(""); setNotice("");
    try {
      setNotice(await emitMissionDocuments(mission.id));
      await loadAllData(account);
    } catch (e) {
      setError(e.message || "Envoi des documents impossible.");
    } finally { setActionLoading(false); }
  }

  // Envoi manuel de la facture au client : elle apparaît aussitôt dans son
  // espace « Mes documents » avec une notification.
  async function sendFacture(mission) {
    setActionLoading(true); setError(""); setNotice("");
    try {
      setNotice(await emitFacture(mission.id));
      await loadAllData(account);
    } catch (e) {
      setError(e.message || "Envoi de la facture impossible.");
    } finally { setActionLoading(false); }
  }

  function renderCompactDeliveredMissionCard(mission) {
    return (
      <details
        className={`mission-card ${focusMissionId === mission.id ? "is-focused" : ""}`}
        key={mission.id}
        id={`mission-${mission.id}`}
        open={focusMissionId === mission.id}
      >
        <summary style={{ cursor: "pointer" }}>
          <div className="card-top">
            <span className="badge">{mission.publicRef}</span>
            <span className="status status-completed">Livraison validée</span>
          </div>
          <h3 style={{ marginTop: 12 }}>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
          <p className="muted" style={{ marginTop: 8 }}>Carte archivée. Cliquez pour revoir le détail, les photos et les preuves terrain.</p>
        </summary>
        <div style={{ marginTop: 14 }}>
          <PublicMissionInfo mission={mission} />
          <PrivateMissionInfo mission={mission} pricingView="transporter" />
          {renderTrackingTimeline(mission)}
        </div>
      </details>
    );
  }

  function renderCompactAdminMissionCard(mission, { delivered = false } = {}) {
    const events = getTrackingEventsForMission(mission.id);
    const photosCount = events.reduce((total, event) => total + getTrackingPhotosForEvent(event.id).length, 0);
    return (
      <details
        className={`mission-card ${focusMissionId === mission.id ? "is-focused" : ""}`}
        key={mission.id}
        id={`mission-${mission.id}`}
        open={focusMissionId === mission.id}
      >
        <summary style={{ cursor: "pointer" }}>
          <div className="card-top">
            <span className="badge">{mission.publicRef}</span>
            <span className={delivered ? "status status-completed" : `status status-${mission.status}`}>{delivered ? "Livraison validée" : labelStatus(mission.status)}</span>
          </div>
          <h3 style={{ marginTop: 12 }}>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
          <div className="card-section" style={{ marginTop: 12 }}>
            <p><strong>Transporteur :</strong> {mission.assignedTransporterName || "Non renseigné"}</p>
            <p><strong>Véhicule :</strong> {mission.vehicle || "Non renseigné"}</p>
            <p><strong>Photos / preuves :</strong> {photosCount}</p>
          </div>
          <p className="muted" style={{ marginTop: 10 }}>Cliquez pour développer la mission, les informations privées et les photos d’état des lieux.</p>
        </summary>
        <div style={{ marginTop: 14 }}>
          <PublicMissionInfo mission={mission} />
          <PrivateMissionInfo mission={mission} showPricing={isAdmin} />
          {renderTrackingTimeline(mission)}
          {isAdmin && (
            <div className="actions-row" style={{ marginTop: 12, flexWrap: "wrap" }}>
              <span className="muted" style={{ width: "100%", fontSize: "0.8rem" }}>Circuit de signature :</span>
              <div style={{ width: "100%", marginBottom: 6 }}>
                {getGeneratedDocs(mission.id).length === 0 && (
                  <p className="muted" style={{ margin: 0 }}>Aucun document émis pour cette mission.</p>
                )}
                {getGeneratedDocs(mission.id).map((d) => (
                  <p key={d.id} style={{ margin: "2px 0" }}>
                    <strong>{DOC_LABEL_FR[d.docType] || "Document"} {d.numero} :</strong>{" "}
                    <span className={`status status-${d.statut === "signe" ? "validated" : "pending"}`}>
                      {d.statut === "signe" ? "signé" : d.statut === "brouillon" ? "en attente de la signature du devis" : "envoyé, en attente de signature"}
                    </span>
                  </p>
                ))}
              </div>
              <span className="muted" style={{ width: "100%", fontSize: "0.8rem" }}>Documents (aperçu imprimable) :</span>
              <button className="btn ghost small" onClick={() => openMissionDoc("devis", mission)}>Devis</button>
              <button className="btn ghost small" onClick={() => openMissionDoc("bon", mission)}>Bon de mission</button>
              <button className="btn ghost small" onClick={() => openMissionDoc("facture", mission)}>Facture</button>
              <span className="muted" style={{ width: "100%", fontSize: "0.8rem", marginTop: 8 }}>Envoi dans l’application :</span>
              <button className="btn primary small" disabled={actionLoading} onClick={() => sendMissionDocs(mission)}>
                {getGeneratedDocs(mission.id).some((d) => d.docType === "devis")
                  ? "Renvoyer le devis au client"
                  : "Envoyer le devis au client"}
              </button>
              <button className="btn primary small" disabled={actionLoading} onClick={() => sendFacture(mission)}>
                Envoyer la facture au client
              </button>
            </div>
          )}
          {!delivered && mission.status === "assigned" && (
            <button className="btn primary" onClick={() => markMissionCompleted(mission.id)}>Marquer terminée</button>
          )}
        </div>
      </details>
    );
  }

  /* ---------- Navigation latérale ---------- */
  function NavIc({ name }) {
    const p = {
      plus: "M12 5v14M5 12h14",
      truck: "M1 3h15v13H1zM16 8h4l3 3v5h-7M5.5 19a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3zM18.5 19a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3z",
      user: "M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z",
      users: "M17 21v-2a4 4 0 0 0-3-3.87M9 21v-2a4 4 0 0 0-4-4H4M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM19 8a3 3 0 1 1-2 5",
      megaphone: "M3 11l14-7v16L3 13v-2zM7 12v5a2 2 0 0 0 4 0",
      check: "M20 6L9 17l-5-5",
      inbox: "M22 12h-6l-2 3h-4l-2-3H2M5 5h14l3 7v6a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-6l3-7z",
      hand: "M18 11V6a2 2 0 0 0-4 0M14 10V4a2 2 0 0 0-4 0v2M10 10.5V6a2 2 0 0 0-4 0v8M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2a8 8 0 0 1-8-8",
      settings: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z",
      phone: "M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.13.96.36 1.9.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0 1 22 16.92z",
    }[name] || "M12 5v14M5 12h14";
    return (
      <svg className="nav-ic" width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
        <path d={p} />
      </svg>
    );
  }

  function getNavModel() {
    if (account.role === "client") {
      return {
        active: clientTab, setActive: setClientTab,
        sections: [
          { title: "Transport", items: [
            { key: "post", label: "Nouvelle course", icon: "plus" },
            { key: "courses", label: "Mes courses", icon: "truck", count: clientMissions.length },
            { key: "documents", label: "Mes documents", icon: "inbox", count: docsToSignCount || undefined },
          ] },
          { title: "Compte", items: [
            { key: "contact", label: "Contact SECOTO", icon: "phone" },
            { key: "profile", label: "Profil", icon: "user" },
          ] },
        ],
      };
    }
    if (account.role === "admin" && mode === "admin") {
      return {
        active: adminTab, setActive: setAdminTab,
        sections: [
          { title: "Missions", items: [
            { key: "create", label: "Créer une mission", icon: "plus" },
            { key: "published", label: "Publiées", icon: "megaphone", count: publishedMissions.length },
            { key: "assigned", label: "Attribuées", icon: "truck", count: activeAssignedMissions.length },
            { key: "completed", label: "Terminées", icon: "check", count: completedOrDeliveredMissions.length },
          ] },
          { title: "Flux entrant", items: [
            { key: "requests", label: "Demandes", icon: "inbox", count: pendingRequests.length },
            { key: "applications", label: "Candidatures", icon: "hand", count: pendingApplications.length },
            { key: "frais", label: "Frais réels", icon: "settings" },
          ] },
          { title: "Réseau", items: [
            { key: "transporters", label: "Transporteurs", icon: "users", count: transporters.length },
            { key: "clients", label: "Clients", icon: "user" },
          ] },
        ],
      };
    }
    return {
      active: transporterTab, setActive: setTransporterTab,
      sections: [
        { title: "Missions", items: [
          { key: "available", label: "Disponibles", icon: "megaphone", count: (account.role === "admin" ? publishedMissions : publicMissions).length },
          { key: "assigned", label: "Mes missions", icon: "truck", count: assignedToCurrentTransporter.length },
        ] },
        { title: "Mon activité", items: [
          { key: "applications", label: "Mes candidatures", icon: "hand", count: currentTransporterApplications.length },
          { key: "request", label: "Proposer une mission", icon: "plus" },
          { key: "requests", label: "Mes demandes", icon: "inbox", count: currentTransporterRequests.length },
          { key: "frais", label: "Mes frais", icon: "settings" },
          { key: "documents", label: "Mes documents", icon: "check", count: docsToSignCount || undefined },
        ] },
        { title: "Compte", items: [
          { key: "contact", label: "Contact SECOTO", icon: "phone" },
          { key: "profile", label: "Profil", icon: "user" },
        ] },
      ],
    };
  }

  function renderSidebar() {
    const nav = getNavModel();
    const initials = (account.fullName || account.email || "?").trim().charAt(0).toUpperCase();
    const roleTxt = account.role === "admin" ? "Direction SECOTO" : account.role === "client" ? (account.clientType === "pro" ? "Client pro" : "Client") : labelTransporterType(account.transporterType);

    return (
      <>
        {navOpen && <div className="nav-backdrop" onClick={() => setNavOpen(false)} />}
        <aside className={`sidebar ${navOpen ? "open" : ""}`}>
          <div className="sidebar-brand">
            <span className="dot" />
            <strong>SECOTO</strong>
          </div>

          {account.role === "admin" && (
            <div className="sidebar-switch">
              <button className={mode === "admin" ? "active" : ""} onClick={() => { setMode("admin"); setNavOpen(false); }}>Admin</button>
              <button className={mode === "transporter" ? "active" : ""} onClick={() => { setMode("transporter"); setNavOpen(false); }}>Transporteur</button>
            </div>
          )}

          {nav.sections.map((section) => (
            <div className="nav-section" key={section.title}>
              <div className="nav-section-title">{section.title}</div>
              {section.items.map((item) => (
                <button
                  key={item.key}
                  className={`nav-item ${nav.active === item.key ? "active" : ""}`}
                  onClick={() => { nav.setActive(item.key); setNavOpen(false); }}
                >
                  <NavIc name={item.icon} />
                  <span className="nav-label">{item.label}</span>
                  {typeof item.count === "number" && <span className="nav-count">{item.count}</span>}
                </button>
              ))}
            </div>
          ))}

          <div className="sidebar-foot">
            <div className="sidebar-userline">
              <span className="avatar">{initials}</span>
              <span className="who">
                <strong>{account.fullName || account.email}</strong>
                <span>{roleTxt}</span>
              </span>
            </div>
            <button className="btn ghost small" onClick={() => { loadAllData(account); loadNotifications(account); setNavOpen(false); }}>Actualiser</button>
            {/* Toujours accessible : indispensable quand plusieurs comptes se
                partagent le même téléphone. */}
            {pushSupported() && (
              <button
                className={`btn ${pushState === "enabled" ? "ghost" : "primary"} small`}
                onClick={() => { handleEnablePush(); setNavOpen(false); }}
              >
                {pushState === "enabled" ? "Notifications activées ✓" : "Activer les notifications"}
              </button>
            )}
            <button className="btn danger small" onClick={signOut}>Déconnexion</button>
          </div>
        </aside>
      </>
    );
  }

  /* ---------- Rendu principal ---------- */
  if (bootLoading) {
    return (
      <main className="app-shell">
        <div className="alert">Chargement de la session SECOTO…</div>
        {error && <div className="alert error">{error}</div>}
      </main>
    );
  }

  if (passwordRecovery && session) {
    return <PasswordRecoveryScreen onDone={() => setPasswordRecovery(false)} />;
  }

  if (!session) return <PublicEntry />;

  if (!account) {
    // Tant que le profil n'a pas fini d'etre verifie, on montre un chargement
    // (evite le flash de l'erreur au demarrage).
    if (!accountChecked) {
      return (
        <main className="app-shell">
          <div className="alert">Chargement de votre profil SECOTO…</div>
        </main>
      );
    }
    return (
      <main className="app-shell">
        <div className="alert error">Session connectée, mais aucun profil SECOTO valide n’est relié à ce compte.</div>
        {error && <div className="alert error">{error}</div>}
        <div className="actions-row">
          <button className="btn ghost" onClick={() => loadAccount(session.user.id)}>Réessayer</button>
          <button className="btn danger" onClick={signOut}>Se déconnecter</button>
        </div>
      </main>
    );
  }

  const isAdmin = account.role === "admin";
  const isTransporter = account.role === "transporter";
  const isClient = account.role === "client";
  const visiblePublicMissions = isAdmin ? publishedMissions : publicMissions;


  return (
    <main className="app-shell">
      <div className="toast-stack">
        {toasts.map((t) => (
          <div className="toast" key={t.id}>
            <strong>{t.title}</strong>
            {t.body && <p>{t.body}</p>}
          </div>
        ))}
      </div>

      <header className="topbar">
        <button className="hamburger" aria-label="Ouvrir le menu" onClick={() => setNavOpen(true)}>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
            <path d="M3 6h18M3 12h18M3 18h18" />
          </svg>
        </button>
        <div className="topbar-title">
          <p className="eyebrow">SECOTO</p>
          <h1>{isClient ? "Mes transports" : isAdmin && mode === "admin" ? "Direction SECOTO" : "Espace transporteur"}</h1>
        </div>
        <div className="topbar-actions">
          <NotificationBell
            notifications={notifications}
            unreadCount={unreadCount}
            open={notifOpen}
            setOpen={setNotifOpen}
            onMarkAll={markAllNotificationsRead}
            onOpenItem={openNotification}
          />
          <ThemeToggle />
        </div>
      </header>

      {pushSupported() && pushState === "idle" && (
        <div className="push-banner">
          <p><strong>Activez les notifications</strong> pour être alerté {isClient ? "à chaque étape de votre transport" : "dès qu’une nouvelle course est disponible"}.</p>
          <div className="actions-row" style={{ marginTop: 0 }}>
            <button className="btn primary small" onClick={handleEnablePush}>Activer</button>
            <button className="btn ghost small" onClick={() => setPushState("dismissed")}>Plus tard</button>
          </div>
        </div>
      )}

      <div className="app-layout">
        {renderSidebar()}
        <div className="content">

      {loading && <div className="alert">Synchronisation des données SECOTO…</div>}
      {actionLoading && <div className="alert">Traitement en cours…</div>}
      {!networkConnected && (
        <div className="alert">
          Mode hors ligne : les brouillons terrain et photos en attente sont conservés chiffrés sur cet appareil.
        </div>
      )}
      {pendingSyncCount > 0 && (
        <div className="alert">
          {pendingSyncCount} action{pendingSyncCount > 1 ? "s" : ""} en attente de synchronisation.
          {networkConnected && (
            <button className="btn ghost small" type="button" onClick={resumePendingTrackingActions}>
              Réessayer maintenant
            </button>
          )}
        </div>
      )}
      {error && <div className="alert error">{error}</div>}
      {notice && <div className="alert success">{notice}</div>}

      {/* ===================== CLIENT ===================== */}
      {isClient && (
        <>
          {clientTab === "post" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Publier une demande de transport</h2>
                <p className="muted" style={{ marginBottom: 14 }}>Votre course sera immédiatement visible par les transporteurs. Vous recevrez une notification à chaque étape.</p>
                <ClientCourseForm form={clientForm} setForm={setClientForm} onSubmit={createClientCourse} submitLabel="Publier ma course" disabled={actionLoading} />
              </div>
            </section>
          )}

          {clientTab === "courses" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Mes courses & suivi</h2>
                {clientMissions.length === 0 && (
                  <div className="empty-state"><strong>Aucune course pour le moment</strong>Publiez votre première demande de transport en quelques secondes.</div>
                )}
                <div className="cards">
                  {clientMissions.map((mission) => (
                    <article
                      id={`mission-${mission.id}`}
                      className={`mission-card${focusMissionId === mission.id ? " is-focused" : ""}`}
                      key={mission.id}
                    >
                      <div className="card-top">
                        <span className="badge">{mission.publicRef}</span>
                        <span className={`status status-${mission.status}`}>{labelStatus(mission.status)}</span>
                      </div>
                      <h3>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
                      <PublicMissionInfo mission={mission} />
                      <div className="card-section">
                        <p><strong>Avancement :</strong> {labelProgress(mission.progressStatus)}</p>
                        {mission.proposedPrice ? <p><strong>Budget indiqué :</strong> {mission.proposedPrice} €</p> : null}
                      </div>
                      <ClientTrackingTimeline mission={mission} events={getTrackingEventsForMission(mission.id)} getPhotos={getTrackingPhotosForEvent} />
                      {mission.status === "published" && (
                        <div className="actions-row">
                          <button className="btn danger small" onClick={() => deleteMission(mission.id, { confirmLabel: "Supprimer cette course ?" })}>Supprimer ma course</button>
                        </div>
                      )}
                    </article>
                  ))}
                </div>
              </div>
            </section>
          )}

          {clientTab === "documents" && (
            <section className="layout">
              <MyDocumentsPanel account={account} focusMissionId={focusMissionId} />
            </section>
          )}

          {clientTab === "contact" && (
            <section className="layout">
              <div className="panel-full"><ContactPanel /></div>
            </section>
          )}

          {clientTab === "profile" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Mon profil</h2>
                <div className="profile-card">
                  <div className="card-section">
                    <p><strong>Nom :</strong> {account.fullName || "Non renseigné"}</p>
                    <p><strong>Type :</strong> {account.clientType === "pro" ? "Professionnel" : "Particulier"}</p>
                    {account.companyName && <p><strong>Société :</strong> {account.companyName}</p>}
                    <p><strong>Email :</strong> {account.email}</p>
                    <p><strong>Téléphone :</strong> {account.phone || "Non renseigné"}</p>
                    <p><strong>Ville :</strong> {account.city || "Non renseignée"}</p>
                  </div>
                </div>
                <AccountDangerZone onDelete={deleteAccount} />
              </div>
            </section>
          )}
        </>
      )}

      {/* ===================== ADMIN ===================== */}
      {isAdmin && mode === "admin" && (
        <>
          <KpiGrid stats={adminStats} />

          {adminTab === "create" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Créer une mission</h2>
                <MissionForm form={missionForm} setForm={setMissionForm} onSubmit={createMission} submitLabel="Publier la mission" showPricing disabled={actionLoading} />
              </div>
            </section>
          )}

          {adminTab === "requests" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Demandes de mise en ligne</h2>
                {requests.length === 0 && <p className="muted">Aucune demande transporteur pour le moment.</p>}
                <div className="cards">
                  {requests.map((request) => (
                    <article className="mission-card" key={request.id}>
                      <div className="card-top">
                        <span className="badge">{request.publicRef}</span>
                        <span className={`status status-${request.status}`}>{labelStatus(request.status)}</span>
                      </div>
                      <h3>{request.fromCity || "Départ"} → {request.toCity || "Arrivée"}</h3>
                      <p className="muted">
                        Demandée par {request.requesterName}{request.requesterCompany ? ` — ${request.requesterCompany}` : ""}{" "}
                        {request.createdByRole === "guest" && <span className="type-badge type-vl">Client web</span>}
                      </p>
                      {request.clientPhone && (
                        <p className="assigned"><strong>☎ Rappeler :</strong> <a href={`tel:${request.clientPhone}`} style={{ textDecoration: "underline" }}>{request.clientPhone}</a></p>
                      )}
                      <PublicMissionInfo mission={request} />
                      <PrivateMissionInfo mission={request} />
                      {request.status === "pending" && (
                        <div className="actions-row">
                          <button className="btn primary small" onClick={() => approveRequest(request)}>Valider et publier</button>
                          <button className="btn danger small" onClick={() => rejectRequest(request.id)}>Refuser</button>
                        </div>
                      )}
                    </article>
                  ))}
                </div>
              </div>
            </section>
          )}

          {adminTab === "published" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Missions publiées</h2>
                {publishedMissions.length === 0 && <p className="muted">Aucune mission publiée.</p>}
                <div className="cards">{publishedMissions.map((mission) => renderMissionCard(mission, { showPrivate: true, showApplications: true, canDelete: true }))}</div>
              </div>
            </section>
          )}

          {adminTab === "applications" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Candidatures reçues</h2>
                {pendingApplications.length === 0 && <p className="muted">Aucune candidature en attente.</p>}
                <div className="cards">
                  {missions.filter((mission) => getMissionApplications(mission.id).some((a) => a.status === "pending")).map((mission) => renderMissionCard(mission, { showPrivate: true, showApplications: true }))}
                </div>
              </div>
            </section>
          )}

          {adminTab === "assigned" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Missions attribuées</h2>
                {activeAssignedMissions.length === 0 && <div className="alert success">Aucune mission attribuée en cours.</div>}
                {activeAssignedMissions.length > 0 && (
                  <div className="cards">{activeAssignedMissions.map((mission) => renderCompactAdminMissionCard(mission, { delivered: false }))}</div>
                )}
              </div>
            </section>
          )}

          {adminTab === "completed" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Missions terminées</h2>
                {completedOrDeliveredMissions.length === 0 && <p className="muted">Aucune mission terminée.</p>}
                <div className="cards">{completedOrDeliveredMissions.map((mission) => renderCompactAdminMissionCard(mission, { delivered: true }))}</div>
              </div>
            </section>
          )}

          {adminTab === "transporters" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Transporteurs inscrits</h2>
                <div className="tabs" style={{ marginTop: 6 }}>
                  {[{ value: "all", label: "Tous" }, ...TRANSPORTER_TYPES.map((t) => ({ value: t.value, label: t.label }))].map((f) => (
                    <button key={f.value} type="button" className={transporterFilter === f.value ? "active" : ""} onClick={() => setTransporterFilter(f.value)}>{f.label}</button>
                  ))}
                </div>
                {filteredTransporters.length === 0 && <p className="muted">Aucun transporteur pour ce filtre.</p>}
                <div className="cards">
                  {filteredTransporters.map((transporter) => {
                    const transporterDocs = getDocumentsForAccount(transporter.id);
                    return (
                      <article className="mission-card" key={transporter.id}>
                        <div className="card-top">
                          <span className="badge">{transporter.isVerified ? "VÉRIFIÉ" : "À VÉRIFIER"}</span>
                          <span className={`status status-${transporter.status}`}>{labelStatus(transporter.status)}</span>
                        </div>
                        <h3>{transporter.fullName || "Transporteur sans nom"}</h3>
                        <div style={{ margin: "6px 0 4px" }}><TransporterTypeBadge type={transporter.transporterType} /></div>
                        <div className="card-section">
                          <p><strong>Société :</strong> {transporter.companyName || "Non renseignée"}</p>
                          <p><strong>Email :</strong> {transporter.email || "Non renseigné"}</p>
                          <p><strong>Téléphone :</strong> {transporter.phone || "Non renseigné"}</p>
                          <p><strong>Ville :</strong> {transporter.city || "Non renseignée"}</p>
                          <p><strong>Documents :</strong> {transporterDocs.length}</p>
                        </div>
                        <div className="applications-box">
                          <h4>Pièces justificatives</h4>
                          {transporterDocs.length === 0 && <p className="muted">Aucune pièce justificative envoyée.</p>}
                          {transporterDocs.map((doc) => (
                            <div className="application-row" key={doc.id}>
                              <div>
                                <strong>{doc.type}</strong>
                                <p>{doc.fileName}</p>
                                <span className={`status status-${doc.status}`}>{labelStatus(doc.status)}</span>
                              </div>
                              <div className="actions-row" style={{ marginTop: 0 }}>
                                <button className="btn ghost small" type="button" onClick={() => openPrivateDocument(doc)}>Ouvrir</button>
                                {doc.status !== "validated" && <button className="btn primary small" onClick={() => updateDocumentStatus(doc.id, "validated")}>Valider</button>}
                                {doc.status !== "rejected" && <button className="btn danger small" onClick={() => updateDocumentStatus(doc.id, "rejected")}>Refuser</button>}
                              </div>
                            </div>
                          ))}
                        </div>
                        <div className="actions-row">
                          <button className="btn primary small" onClick={() => updateTransporterStatus(transporter.id, { status: "active", is_verified: true, docs_count: transporterDocs.length })}>Valider</button>
                          <button className="btn ghost small" onClick={() => updateTransporterStatus(transporter.id, { status: "pending", is_verified: false })}>En attente</button>
                          <button className="btn danger small" onClick={() => updateTransporterStatus(transporter.id, { status: "suspended", is_verified: false })}>Suspendre</button>
                        </div>
                      </article>
                    );
                  })}
                </div>
              </div>
            </section>
          )}

          {adminTab === "frais" && (
            <section className="layout">
              <div className="panel-full">
                <FraisPanel account={account} isAdmin />
              </div>
            </section>
          )}

          {adminTab === "clients" && (
            <section className="layout">
              <ClientsPanel />
            </section>
          )}
        </>
      )}

      {/* ===================== TRANSPORTEUR ===================== */}
      {(isTransporter || isAdmin) && mode === "transporter" && (
        <>
          {transporterTab === "available" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Missions disponibles</h2>
                {isAdmin && <div className="alert">Prévisualisation admin de la vue transporteur.</div>}
                {!isAdmin && !account.isVerified && <div className="alert error">Compte non vérifié : vous pouvez consulter les missions, mais pas encore candidater.</div>}
                {visiblePublicMissions.length === 0 && <p className="muted">Aucune mission disponible actuellement.</p>}
                <div className="cards">
                  {visiblePublicMissions.map((mission) => (
                    <article
                      id={`mission-${mission.id}`}
                      className={`mission-card${focusMissionId === mission.id ? " is-focused" : ""}`}
                      key={mission.id}
                    >
                      <div className="card-top">
                        <span className="badge">{mission.publicRef}</span>
                        <span className={`status status-${mission.status}`}>{labelStatus(mission.status)}</span>
                      </div>
                      <h3>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
                      <PublicMissionInfo mission={mission} />
                      <div className="private-locked">Détails client, immatriculation et consignes visibles uniquement après attribution par SECOTO.</div>
                      {!isAdmin && (
                        <>
                          <input className="message-box" type="number" min="1" step="1" placeholder="Votre tarif proposé (€) — obligatoire" value={applicationPrices[mission.id] || ""} onChange={(e) => setApplicationPrices((prev) => ({ ...prev, [mission.id]: e.target.value }))} />
                          <textarea className="message-box" placeholder="Message optionnel pour SECOTO…" value={applicationMessages[mission.id] || ""} onChange={(e) => setApplicationMessages((prev) => ({ ...prev, [mission.id]: e.target.value }))} />
                          <button className="btn primary" disabled={hasCurrentTransporterApplied(mission.id) || !account.isVerified} onClick={() => applyToMission(mission.id)}>
                            {hasCurrentTransporterApplied(mission.id) ? "Candidature envoyée" : "Candidater"}
                          </button>
                        </>
                      )}
                    </article>
                  ))}
                </div>
              </div>
            </section>
          )}

          {transporterTab === "applications" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Mes candidatures</h2>
                {isAdmin && <p className="muted">Prévisualisation admin.</p>}
                {!isAdmin && currentTransporterApplications.length === 0 && <p className="muted">Aucune candidature envoyée.</p>}
                <div className="cards">
                  {!isAdmin && currentTransporterApplications.map((application) => {
                    const mission = missions.find((i) => i.id === application.missionId) || publicMissions.find((i) => i.id === application.missionId);
                    return (
                      <article className="mission-card" key={application.id}>
                        <div className="card-top">
                          <span className="badge">{mission?.publicRef || "Mission"}</span>
                          <span className={`status status-${application.status}`}>{labelStatus(application.status)}</span>
                        </div>
                        <p className="price-line"><strong>Tarif proposé :</strong> {application.proposedPrice ? `${Number(application.proposedPrice).toFixed(0)} €` : "Non renseigné"}</p>
                        {mission ? (<><h3>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3><PublicMissionInfo mission={mission} /></>) : <p>Mission introuvable.</p>}
                      </article>
                    );
                  })}
                </div>
              </div>
            </section>
          )}

          {transporterTab === "assigned" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Mes missions attribuées</h2>
                {isAdmin && <p className="muted">Prévisualisation admin.</p>}
                {!isAdmin && assignedToCurrentTransporter.length === 0 && <p className="muted">Aucune mission attribuée.</p>}
                {!isAdmin && assignedToCurrentTransporter.length > 0 && (() => {
                  const activeMissions = assignedToCurrentTransporter.filter((m) => !isMissionDeliveryValidated(m));
                  const deliveredMissions = assignedToCurrentTransporter.filter((m) => isMissionDeliveryValidated(m));
                  return (
                    <>
                      <div className="cards">
                        {activeMissions.length === 0 && <div className="alert success">Aucune mission en cours.</div>}
                        {activeMissions.map((mission) => (
                          <article
                            id={`mission-${mission.id}`}
                            className={`mission-card${focusMissionId === mission.id ? " is-focused" : ""}`}
                            key={mission.id}
                          >
                            <div className="card-top">
                              <span className="badge">{mission.publicRef}</span>
                              <span className={`status status-${mission.status}`}>{labelStatus(mission.status)}</span>
                            </div>
                            <h3>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
                            <PublicMissionInfo mission={mission} />
                            <PrivateMissionInfo mission={mission} pricingView="transporter" />
                            <div className="actions-row">
                              <button
                                className="btn ghost small"
                                type="button"
                                onClick={() => openRoute({ address: mission.pickupAddress || mission.fromCity })}
                              >
                                Itinéraire vers la prise en charge
                              </button>
                              <button
                                className="btn ghost small"
                                type="button"
                                onClick={() => openRoute({ address: mission.deliveryAddress || mission.toCity })}
                              >
                                Itinéraire vers la livraison
                              </button>
                            </div>
                            {renderTrackingTimeline(mission)}
                            <div className="applications-box">
                              <h4>Actions terrain</h4>
                              {renderTrackingForm(mission, "pickup_inspection")}
                              {renderTrackingForm(mission, "road_incident")}
                              {renderTrackingForm(mission, "delivery_inspection")}
                            </div>
                          </article>
                        ))}
                      </div>
                      {deliveredMissions.length > 0 && (
                        <div className="applications-box">
                          <h4>Missions livrées / archives</h4>
                          <div className="cards">{deliveredMissions.map((mission) => renderCompactDeliveredMissionCard(mission))}</div>
                        </div>
                      )}
                    </>
                  );
                })()}
              </div>
            </section>
          )}

          {transporterTab === "request" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Proposer une mission à publier</h2>
                {isAdmin ? <p className="muted">Prévisualisation admin.</p> : (
                  <>
                    {!account.isVerified && <div className="alert error">Compte non vérifié : impossible de proposer une mission.</div>}
                    <MissionForm form={requestForm} setForm={setRequestForm} onSubmit={createMissionRequest} submitLabel="Envoyer à SECOTO" showPricing={false} disabled={actionLoading || !account.isVerified} />
                  </>
                )}
              </div>
            </section>
          )}

          {transporterTab === "requests" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Mes demandes de publication</h2>
                {isAdmin && <p className="muted">Prévisualisation admin.</p>}
                {!isAdmin && currentTransporterRequests.length === 0 && <p className="muted">Aucune demande envoyée.</p>}
                <div className="cards">
                  {!isAdmin && currentTransporterRequests.map((request) => (
                    <article className="mission-card" key={request.id}>
                      <div className="card-top">
                        <span className="badge">{request.publicRef}</span>
                        <span className={`status status-${request.status}`}>{labelStatus(request.status)}</span>
                      </div>
                      <h3>{request.fromCity || "Départ"} → {request.toCity || "Arrivée"}</h3>
                      <PublicMissionInfo mission={request} />
                    </article>
                  ))}
                </div>
              </div>
            </section>
          )}

          {transporterTab === "frais" && (
            <section className="layout">
              <div className="panel-full">
                <FraisPanel account={account} isAdmin={false} missions={assignedToCurrentTransporter} />
              </div>
            </section>
          )}

          {transporterTab === "documents" && (
            <section className="layout">
              <MyDocumentsPanel account={account} focusMissionId={focusMissionId} />
            </section>
          )}

          {transporterTab === "contact" && (
            <section className="layout">
              <div className="panel-full"><ContactPanel /></div>
            </section>
          )}

          {transporterTab === "profile" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Profil transporteur</h2>
                {isAdmin ? <p className="muted">Prévisualisation admin.</p> : (
                  <>
                    <div className="profile-card">
                      <div style={{ marginBottom: 10 }}><TransporterTypeBadge type={account.transporterType} /></div>
                      <div className="card-section">
                        <p><strong>Nom :</strong> {account.fullName || "Non renseigné"}</p>
                        <p><strong>Société :</strong> {account.companyName || "Non renseigné"}</p>
                        <p><strong>Email :</strong> {account.email}</p>
                        <p><strong>Téléphone :</strong> {account.phone || "Non renseigné"}</p>
                        <p><strong>Ville :</strong> {account.city || "Non renseignée"}</p>
                        <p><strong>Statut :</strong> {labelStatus(account.status)}</p>
                        <p><strong>Vérifié :</strong> {account.isVerified ? "Oui" : "Non"}</p>
                      </div>
                    </div>

                    <div className="panel" style={{ marginTop: 18 }}>
                      <h2>Pièces justificatives</h2>
                      <p className="muted">Ajoutez : assurance RC pro, extrait Kbis/SIREN, licence transport, carte grise, pièce d’identité ou attestation utile.</p>
                      <div className="form-grid">
                        <label className="field">
                          <span>Type de document</span>
                          <select value={documentType} onChange={(e) => setDocumentType(e.target.value)}>
                            <option value="assurance_rc_pro">Assurance RC pro</option>
                            <option value="kbis_siren">Kbis / SIREN</option>
                            <option value="licence_transport">Licence transport</option>
                            <option value="piece_identite">Pièce d’identité</option>
                            <option value="carte_grise">Carte grise / véhicule</option>
                            <option value="autre">Autre document</option>
                          </select>
                        </label>
                        <SecureFilePicker
                          files={documentFiles}
                          onChange={(files) => {
                            setDocumentFiles(files.slice(0, 1));
                            setDocumentOperationId(randomIdempotencyKey());
                          }}
                          label="Fichier PDF ou image"
                          allowPdf
                          maxFiles={1}
                          disabled={actionLoading}
                          progress={uploadProgress.document}
                        />
                        <button
                          className="btn primary field-full"
                          type="button"
                          onClick={uploadTransporterDocument}
                          disabled={actionLoading || documentFiles.length !== 1}
                        >
                          Envoyer la pièce privée
                        </button>
                      </div>
                      <div className="cards" style={{ marginTop: 18 }}>
                        {documents.length === 0 && <p className="muted">Aucun document envoyé.</p>}
                        {documents.map((doc) => (
                          <article className="mission-card" key={doc.id}>
                            <div className="card-top">
                              <span className="badge">{doc.type}</span>
                              <span className={`status status-${doc.status}`}>{labelStatus(doc.status)}</span>
                            </div>
                            <h3>{doc.fileName}</h3>
                            <button className="btn ghost small" type="button" onClick={() => openPrivateDocument(doc)}>Ouvrir le document</button>
                          </article>
                        ))}
                      </div>
                    </div>
                    <AccountDangerZone onDelete={deleteAccount} />
                  </>
                )}
              </div>
            </section>
          )}
        </>
      )}

        </div>
      </div>

      {docModal && (
        <DocumentModal
          kind={docModal.kind}
          mission={docModal.mission}
          transporter={docModal.transporter}
          onClose={() => setDocModal(null)}
        />
      )}

      {isClient && clientTab !== "post" && (
        <button className="fab" onClick={() => setClientTab("post")} aria-label="Nouvelle course">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"><path d="M12 5v14M5 12h14" /></svg>
          Nouvelle course
        </button>
      )}
    </main>
  );
}

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
  generatePublicRef,
  labelTransporterType,
  labelTrackingEventType,
  labelFuelLevel,
  labelStatus,
  labelMissionType,
  labelProgress,
  formatDateTime,
} from "./lib/mappers";
import { enablePush, triggerPush, pushSupported } from "./push";
import { computeClientPrice, computeCarrierPay, computeMargin, formatAmount } from "./lib/pricing";
import { renderDevisHtml, renderBonMissionHtml, renderFactureHtml, openDocumentForPrint } from "./lib/documents";
import FraisPanel from "./FraisPanel";
import AddressAutocomplete from "./AddressAutocomplete";
import ContactPanel from "./ContactPanel";
import "./index.css";

/* ============================================================
   Petits composants UI
============================================================ */

function Field({ label, name, value, onChange, type = "text", placeholder = "", required = false }) {
  return (
    <label className="field">
      <span>{label}{required ? " *" : ""}</span>
      <input type={type} name={name} value={value ?? ""} placeholder={placeholder} onChange={onChange} aria-label={label} />
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

function MissionForm({ form, setForm, onSubmit, submitLabel }) {
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
      <BaremeBox form={form} />
      <label className="field field-full">
        <span>Notes internes</span>
        <textarea name="notes" value={form.notes} onChange={update} />
      </label>
      <button className="btn primary field-full" type="submit">{submitLabel}</button>
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

function PrivateMissionInfo({ mission, showPricing = false }) {
  return (
    <div className="card-section private-box">
      <p><strong>Date :</strong> {formatDateTime(mission.missionDate)}</p>
      <p><strong>Client :</strong> {mission.clientName || "Non renseigné"}</p>
      <p><strong>Contact :</strong> {mission.clientContact || "Non renseigné"}</p>
      <p><strong>Téléphone :</strong> {mission.clientPhone || "Non renseigné"}</p>
      <p><strong>Immatriculation :</strong> {mission.plate || "Non renseignée"}</p>
      {/* Montants visibles uniquement par l'admin (cloisonnement marge/coût). */}
      {showPricing && (
        <>
          <p><strong>Prix client :</strong> {formatAmount(computeClientPrice(mission))}</p>
          <p><strong>Rémunération transporteur :</strong> {formatAmount(computeCarrierPay(mission))}</p>
          <p><strong>Marge SECOTO :</strong> {formatAmount(computeMargin(mission))}</p>
        </>
      )}
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

  const ordered = ["published", "assigned"].includes(mission.status) && !byType.pickup_inspection;

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

  async function handleSignup(e) {
    e.preventDefault();
    setLoading(true); setError(""); setNotice("");

    if (role === "client" && clientType === "pro" && !companyName.trim()) {
      setError("Merci d’indiquer le nom de votre société.");
      setLoading(false);
      return;
    }

    const cleanEmail = email.trim().toLowerCase();
    const { data, error } = await supabase.auth.signUp({
      email: cleanEmail,
      password,
      options: {
        data: {
          role,
          full_name: fullName || "",
          company_name: companyName || "",
          phone: phone || "",
          city: city || "",
          transporter_type: role === "transporter" ? transporterType : "",
          client_type: role === "client" ? clientType : "",
        },
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

      <Tabs
        active={authMode}
        onChange={setAuthMode}
        items={[
          { value: "login", label: "Connexion" },
          { value: "signup", label: "Créer un compte" },
        ]}
      />

      <section className="layout">
        <div className="panel panel-full">
          {authMode === "login" ? (
            <>
              <h2>Connexion</h2>
              <form className="form-grid" onSubmit={handleLogin}>
                <Field label="Email" name="email" value={email} onChange={(e) => setEmail(e.target.value)} type="email" />
                <Field label="Mot de passe" name="password" value={password} onChange={(e) => setPassword(e.target.value)} type="password" />
                <button className="btn primary field-full" type="submit" disabled={loading}>{loading ? "Connexion…" : "Se connecter"}</button>
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
                <Field label="Nom complet" name="fullName" value={fullName} onChange={(e) => setFullName(e.target.value)} />
                <Field label={role === "client" && clientType === "particulier" ? "Société (optionnel)" : "Société"} name="companyName" value={companyName} onChange={(e) => setCompanyName(e.target.value)} required={role === "transporter" || (role === "client" && clientType === "pro")} />
                <Field label="Email" name="email" value={email} onChange={(e) => setEmail(e.target.value)} type="email" />
                <Field label="Mot de passe" name="password" value={password} onChange={(e) => setPassword(e.target.value)} type="password" />
                <Field label="Téléphone" name="phone" value={phone} onChange={(e) => setPhone(e.target.value)} />
                <Field label="Ville" name="city" value={city} onChange={(e) => setCity(e.target.value)} />
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
    setForm((prev) => ({ ...prev, ...Object.fromEntries(Object.entries(patch).filter(([, v]) => v !== "")) , type: patch.type }));
    if (patch.clientContact || patch.distanceKm || patch.missionDate || patch.notes) setShowDetails(true);
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
      const { error } = await supabase.from("mission_requests").insert(row);
      if (error) throw error;
      setDone({ ref: row.public_ref, phone: form.clientPhone.trim() });
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

  const [notifications, setNotifications] = useState([]);
  const [notifOpen, setNotifOpen] = useState(false);
  const [navOpen, setNavOpen] = useState(false);
  const [toasts, setToasts] = useState([]);
  const [pushState, setPushState] = useState(() => {
    // Mémorise le choix ("enabled" / "dismissed") pour ne PAS re-afficher le
    // bandeau notifications à chaque rafraîchissement de page.
    try { return localStorage.getItem("secoto-push-state") || "idle"; } catch { return "idle"; }
  }); // idle | enabled | dismissed
  useEffect(() => {
    try { localStorage.setItem("secoto-push-state", pushState); } catch { /* ignore */ }
  }, [pushState]);

  const [loading, setLoading] = useState(false);
  const [actionLoading, setActionLoading] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const accountRef = useRef(null);
  useEffect(() => { accountRef.current = account; }, [account]);

  /* ---------- Boot / session ---------- */
  useEffect(() => {
    let mounted = true;
    const timer = setTimeout(() => {
      if (mounted) {
        setBootLoading(false);
        setSession(null);
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

    const { data: listener } = supabase.auth.onAuthStateChange((_event, newSession) => {
      setSession(newSession || null);
      if (newSession?.user?.id) loadAccount(newSession.user.id);
      else setAccount(null);
    });

    return () => { mounted = false; clearTimeout(timer); listener?.subscription?.unsubscribe(); };
  }, []);

  useEffect(() => {
    if (account) {
      setMode(account.role === "admin" ? "admin" : account.role === "client" ? "client" : "transporter");
      loadAllData(account);
      loadNotifications(account);
      subscribeRealtime(account);
    }
    return () => { supabase.removeAllChannels(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [account?.id]);

  async function loadAccount(userId) {
    setError("");
    try {
      const timeout = new Promise((_, reject) => setTimeout(() => reject(new Error("Timeout chargement profil SECOTO")), 8000));
      const query = supabase.from("accounts").select("*").eq("id", userId).single();
      const { data, error } = await Promise.race([query, timeout]);
      if (error) throw error;
      setAccount(accountFromDb(data));
    } catch (err) {
      setError(err.message || "Profil SECOTO introuvable ou bloqué par RLS.");
      setAccount(null);
    }
  }

  /* ---------- Notifications ---------- */
  async function loadNotifications(currentAccount = account) {
    if (!currentAccount) return;
    try {
      const { data, error } = await supabase
        .from("notifications")
        .select("*")
        .eq("account_id", currentAccount.id)
        .order("created_at", { ascending: false })
        .limit(50);
      if (error) throw error;
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

  // Crée une notification persistée pour un compte cible.
  async function notifyAccount(accountId, { type = "info", title, body, missionId = null, audience = null }) {
    if (!accountId) return;
    try {
      await supabase.from("notifications").insert({
        account_id: accountId, type, title, body: body || null, mission_id: missionId, audience,
      });
    } catch { /* migration non exécutée : ignoré */ }
  }

  function subscribeRealtime(currentAccount) {
    supabase.removeAllChannels();

    // Mes notifications en temps réel
    supabase
      .channel(`notif-${currentAccount.id}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "notifications", filter: `account_id=eq.${currentAccount.id}` },
        (payload) => {
          const n = notificationFromDb(payload.new);
          setNotifications((prev) => [n, ...prev.filter((x) => x.id !== n.id)]);
          pushToast(n.title, n.body);
        })
      .subscribe();

    // Nouvelles courses publiées (pour les transporteurs)
    if (currentAccount.role === "transporter") {
      supabase
        .channel("missions-feed")
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "missions" },
          (payload) => {
            const m = missionFromDb(payload.new);
            if (m.status === "published") {
              pushToast("Nouvelle course disponible", `${m.fromCity || "Départ"} → ${m.toCity || "Arrivée"}`);
              notifyAccount(currentAccount.id, {
                type: "new_course",
                title: "Nouvelle course disponible",
                body: `${m.fromCity || "Départ"} → ${m.toCity || "Arrivée"} · ${labelMissionType(m.type)}`,
                missionId: m.id,
              });
              loadAllData(accountRef.current || currentAccount);
            }
          })
        .subscribe();
    }

    // Nouvelles demandes déposées depuis la landing (pour l'admin)
    if (currentAccount.role === "admin") {
      supabase
        .channel("requests-feed")
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "mission_requests" },
          (payload) => {
            const r = requestFromDb(payload.new);
            pushToast("Nouvelle demande client", `${r.fromCity || "Départ"} → ${r.toCity || "Arrivée"}${r.clientPhone ? " · " + r.clientPhone : ""}`);
            loadAllData(accountRef.current || currentAccount);
          })
        .subscribe();
    }

    // Suivi d'étapes (pour l'admin et pour rafraîchir)
    supabase
      .channel("tracking-feed")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "mission_tracking_events" },
        () => { loadAllData(accountRef.current || currentAccount); })
      .subscribe();
  }

  async function markAllNotificationsRead() {
    setNotifications((prev) => prev.map((n) => ({ ...n, isRead: true })));
    try {
      await supabase.from("notifications").update({ is_read: true }).eq("account_id", account.id).eq("is_read", false);
    } catch { /* ignore */ }
  }

  async function openNotification(n) {
    if (!n.isRead) {
      setNotifications((prev) => prev.map((x) => (x.id === n.id ? { ...x, isRead: true } : x)));
      try { await supabase.from("notifications").update({ is_read: true }).eq("id", n.id); } catch { /* ignore */ }
    }
    setNotifOpen(false);
    // Route vers l'onglet pertinent
    if (account.role === "transporter") setTransporterTab("available");
    if (account.role === "client") setClientTab("courses");
    if (account.role === "admin") setMode("admin");
  }

  async function handleEnablePush() {
    const res = await enablePush(account);
    if (res.ok) { setPushState("enabled"); setNotice("Notifications push activées sur cet appareil."); }
    else if (res.reason === "no_vapid") { setPushState("dismissed"); setNotice("Notifications temps réel actives. (Le push système sera disponible une fois les clés VAPID configurées.)"); }
    else if (res.reason === "denied") { setPushState("dismissed"); setError("Notifications refusées par le navigateur."); }
    else setPushState("dismissed");
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
  async function loadAllData(currentAccount = account) {
    if (!currentAccount) return;
    setLoading(true); setError("");

    try {
      if (currentAccount.role === "admin") {
        const [missionsResult, requestsResult, applicationsResult, transportersResult, documentsResult, trackingEventsResult, trackingPhotosResult] = await Promise.all([
          supabase.from("missions").select("*").order("created_at", { ascending: false }),
          supabase.from("mission_requests").select("*").order("created_at", { ascending: false }),
          supabase.from("mission_applications").select("*").order("proposed_price", { ascending: true, nullsFirst: false }).order("created_at", { ascending: false }),
          supabase.from("accounts").select("*").eq("role", "transporter").order("created_at", { ascending: false }),
          supabase.from("documents").select("*").order("created_at", { ascending: false }),
          supabase.from("mission_tracking_events").select("*").order("created_at", { ascending: false }),
          supabase.from("mission_tracking_photos").select("*").order("created_at", { ascending: false }),
        ]);
        for (const r of [missionsResult, requestsResult, applicationsResult, transportersResult, documentsResult, trackingEventsResult, trackingPhotosResult]) {
          if (r.error) throw r.error;
        }
        setMissions((missionsResult.data || []).map(missionFromDb));
        setPublicMissions([]);
        setRequests((requestsResult.data || []).map(requestFromDb));
        setApplications((applicationsResult.data || []).map(applicationFromDb));
        setTransporters((transportersResult.data || []).map(accountFromDb));
        setDocuments((documentsResult.data || []).map(documentFromDb));
        setTrackingEvents((trackingEventsResult.data || []).map(trackingEventFromDb));
        setTrackingPhotos((trackingPhotosResult.data || []).map(trackingPhotoFromDb));
      } else if (currentAccount.role === "client") {
        const [missionsResult, trackingEventsResult, trackingPhotosResult] = await Promise.all([
          supabase.from("missions").select("*").order("created_at", { ascending: false }),
          supabase.from("mission_tracking_events").select("*").order("created_at", { ascending: false }),
          supabase.from("mission_tracking_photos").select("*").order("created_at", { ascending: false }),
        ]);
        for (const r of [missionsResult, trackingEventsResult, trackingPhotosResult]) { if (r.error) throw r.error; }
        setMissions((missionsResult.data || []).map(missionFromDb));
        setTrackingEvents((trackingEventsResult.data || []).map(trackingEventFromDb));
        setTrackingPhotos((trackingPhotosResult.data || []).map(trackingPhotoFromDb));
        setPublicMissions([]); setRequests([]); setApplications([]); setTransporters([]); setDocuments([]);
      } else {
        const [publicResult, privateResult, requestsResult, applicationsResult, documentsResult, trackingEventsResult, trackingPhotosResult] = await Promise.all([
          supabase.from("public_missions").select("*").order("created_at", { ascending: false }),
          supabase.from("missions").select("*").order("created_at", { ascending: false }),
          supabase.from("mission_requests").select("*").order("created_at", { ascending: false }),
          supabase.from("mission_applications").select("*").order("proposed_price", { ascending: true, nullsFirst: false }).order("created_at", { ascending: false }),
          supabase.from("documents").select("*").eq("account_id", currentAccount.id).order("created_at", { ascending: false }),
          supabase.from("mission_tracking_events").select("*").order("created_at", { ascending: false }),
          supabase.from("mission_tracking_photos").select("*").order("created_at", { ascending: false }),
        ]);
        for (const r of [publicResult, privateResult, requestsResult, applicationsResult, documentsResult, trackingEventsResult, trackingPhotosResult]) {
          if (r.error) throw r.error;
        }
        setPublicMissions((publicResult.data || []).map(publicMissionFromDb));
        setMissions((privateResult.data || []).map(missionFromDb));
        setRequests((requestsResult.data || []).map(requestFromDb));
        setApplications((applicationsResult.data || []).map(applicationFromDb));
        setTransporters([]);
        setDocuments((documentsResult.data || []).map(documentFromDb));
        setTrackingEvents((trackingEventsResult.data || []).map(trackingEventFromDb));
        setTrackingPhotos((trackingPhotosResult.data || []).map(trackingPhotoFromDb));
      }
    } catch (err) {
      setError(err.message || "Erreur lors du chargement Supabase.");
    } finally {
      setLoading(false);
    }
  }

  /* ---------- Actions ADMIN ---------- */
  async function createMission(e) {
    e.preventDefault(); setActionLoading(true); setError(""); setNotice("");
    try {
      const { data, error } = await supabase.from("missions").insert(
        missionToDb(missionForm, { status: "published", createdByRole: "admin" })
      ).select("*").single();
      if (error) throw error;
      const created = missionFromDb(data);
      setMissions((prev) => [created, ...prev]);
      setMissionForm(emptyMissionForm);
      setNotice("Mission publiée avec succès.");
      setAdminTab("published");
      triggerPush({ audience: "transporter", title: "Nouvelle course disponible", body: `${created.fromCity || "Départ"} → ${created.toCity || "Arrivée"}`, url: "/", missionId: created.id });
    } catch (err) { setError(err.message || "Erreur lors de la création de mission."); }
    finally { setActionLoading(false); }
  }

  /* ---------- Actions CLIENT ---------- */
  async function createClientCourse(e) {
    e.preventDefault(); setActionLoading(true); setError(""); setNotice("");
    try {
      const enriched = {
        ...clientForm,
        clientName: clientForm.clientName || account.fullName || account.companyName || "",
        clientContact: clientForm.clientContact || account.email || "",
        clientPhone: clientForm.clientPhone || account.phone || "",
      };
      const { data, error } = await supabase.from("missions").insert(
        missionToDb(enriched, { status: "published", createdByRole: "client", clientAccountId: account.id })
      ).select("*").single();
      if (error) throw error;
      const created = missionFromDb(data);
      setMissions((prev) => [created, ...prev]);
      setClientForm(emptyMissionForm);
      setNotice("Votre course est publiée et visible par les transporteurs.");
      setClientTab("courses");
      // Notification/push vers les transporteurs
      triggerPush({ audience: "transporter", title: "Nouvelle course disponible", body: `${created.fromCity || "Départ"} → ${created.toCity || "Arrivée"} · ${labelMissionType(created.type)}`, url: "/", missionId: created.id });
      notifyAccount(account.id, { type: "system", title: "Course publiée", body: `${created.fromCity || "Départ"} → ${created.toCity || "Arrivée"}`, missionId: created.id });
    } catch (err) { setError(err.message || "Erreur lors de la publication de la course."); }
    finally { setActionLoading(false); }
  }

  async function createMissionRequest(e) {
    e.preventDefault(); setActionLoading(true); setError(""); setNotice("");
    try {
      if (!account?.isVerified) throw new Error("Votre compte transporteur doit être vérifié pour proposer une mission.");
      const { data, error } = await supabase.from("mission_requests").insert(requestToDb(requestForm, account)).select("*").single();
      if (error) throw error;
      setRequests((prev) => [requestFromDb(data), ...prev]);
      setRequestForm(emptyMissionForm);
      setNotice("Demande envoyée à SECOTO pour validation.");
      setTransporterTab("requests");
    } catch (err) { setError(err.message || "Erreur lors de la demande de mise en ligne."); }
    finally { setActionLoading(false); }
  }

  async function applyToMission(missionId) {
    setActionLoading(true); setError(""); setNotice("");
    try {
      if (!account?.isVerified) throw new Error("Votre compte transporteur doit être vérifié par SECOTO pour candidater.");
      const alreadyApplied = applications.some((a) => a.missionId === missionId && a.transporterId === account.id);
      if (alreadyApplied) throw new Error("Vous avez déjà candidaté à cette mission.");
      const rawPrice = applicationPrices[missionId];
      const proposedPrice = Number(rawPrice);
      if (!rawPrice || Number.isNaN(proposedPrice) || proposedPrice <= 0) throw new Error("Veuillez indiquer un tarif proposé valide.");

      const { data, error } = await supabase.from("mission_applications").insert({
        mission_id: missionId,
        transporter_id: account.id,
        transporter_name: account.fullName,
        transporter_company: account.companyName,
        transporter_status: account.isVerified ? "verified" : "unverified",
        message: applicationMessages[missionId] || null,
        proposed_price: proposedPrice,
        price_note: applicationMessages[missionId] || null,
        status: "pending",
      }).select("*").single();
      if (error) throw error;
      setApplications((prev) => [applicationFromDb(data), ...prev]);
      setApplicationMessages((prev) => ({ ...prev, [missionId]: "" }));
      setApplicationPrices((prev) => ({ ...prev, [missionId]: "" }));
      setNotice("Candidature envoyée avec votre tarif.");
      setTransporterTab("applications");
    } catch (err) { setError(err.message || "Erreur lors de la candidature."); }
    finally { setActionLoading(false); }
  }

  async function assignMission(missionId, application) {
    setActionLoading(true); setError(""); setNotice("");
    try {
      const { error: missionError } = await supabase.from("missions").update({
        status: "assigned",
        assigned_transporter_id: application.transporterId,
        assigned_transporter_name: application.transporterName,
      }).eq("id", missionId);
      if (missionError) throw missionError;
      const { error: acceptError } = await supabase.from("mission_applications").update({ status: "accepted" }).eq("id", application.id);
      if (acceptError) throw acceptError;
      const { error: rejectError } = await supabase.from("mission_applications").update({ status: "rejected" }).eq("mission_id", missionId).neq("id", application.id);
      if (rejectError) throw rejectError;

      const mission = missions.find((m) => m.id === missionId);
      notifyAccount(application.transporterId, { type: "course_assigned", title: "Mission attribuée", body: "Une mission vous a été attribuée par SECOTO.", missionId });
      triggerPush({ accountId: application.transporterId, title: "Mission attribuée", body: "Vous avez une nouvelle mission SECOTO.", url: "/", missionId });
      if (mission?.clientAccountId) {
        notifyAccount(mission.clientAccountId, { type: "course_assigned", title: "Un transporteur a été attribué", body: `${application.transporterName} prend en charge votre course.`, missionId });
        triggerPush({ accountId: mission.clientAccountId, title: "Transporteur attribué", body: `${application.transporterName} prend en charge votre course.`, url: "/", missionId });
      }
      await loadAllData(account);
      setNotice("Mission attribuée au transporteur.");
      setAdminTab("assigned");
    } catch (err) { setError(err.message || "Erreur lors de l’attribution."); }
    finally { setActionLoading(false); }
  }

  async function markMissionCompleted(missionId) {
    setActionLoading(true); setError(""); setNotice("");
    try {
      const { error } = await supabase.from("missions").update({ status: "completed" }).eq("id", missionId);
      if (error) throw error;
      await loadAllData(account);
      setNotice("Mission marquée comme terminée.");
      setAdminTab("completed");
    } catch (err) { setError(err.message || "Erreur lors du changement de statut."); }
    finally { setActionLoading(false); }
  }

  async function deleteMission(missionId, { confirmLabel = "Supprimer définitivement cette annonce ?" } = {}) {
    if (typeof window !== "undefined" && !window.confirm(confirmLabel)) return;
    setActionLoading(true); setError(""); setNotice("");
    try {
      // Nettoyage des dépendances (les policies/FK peuvent l'exiger)
      await supabase.from("mission_applications").delete().eq("mission_id", missionId);
      const { error } = await supabase.from("missions").delete().eq("id", missionId);
      if (error) throw error;
      setMissions((prev) => prev.filter((m) => m.id !== missionId));
      setNotice("Annonce supprimée.");
    } catch (err) {
      setError(err.message || "Erreur lors de la suppression de l’annonce.");
    } finally { setActionLoading(false); }
  }

  async function approveRequest(request) {
    setActionLoading(true); setError(""); setNotice("");
    try {
      const { data: createdMission, error: missionError } = await supabase.from("missions").insert(
        missionToDb(request, { status: "published", createdByRole: "transporter_request", sourceRequestId: request.id })
      ).select("*").single();
      if (missionError) throw missionError;
      const { error: requestError } = await supabase.from("mission_requests").update({ status: "approved", approved_mission_id: createdMission.id }).eq("id", request.id);
      if (requestError) throw requestError;
      await loadAllData(account);
      setNotice("Demande validée et mission publiée.");
      setAdminTab("published");
    } catch (err) { setError(err.message || "Erreur lors de la validation de la demande."); }
    finally { setActionLoading(false); }
  }

  async function rejectRequest(requestId) {
    setActionLoading(true); setError(""); setNotice("");
    try {
      const { error } = await supabase.from("mission_requests").update({ status: "rejected" }).eq("id", requestId);
      if (error) throw error;
      await loadAllData(account);
      setNotice("Demande refusée.");
    } catch (err) { setError(err.message || "Erreur lors du refus de la demande."); }
    finally { setActionLoading(false); }
  }

  async function updateTransporterStatus(transporterId, updates) {
    setActionLoading(true); setError(""); setNotice("");
    try {
      const { error } = await supabase.from("accounts").update(updates).eq("id", transporterId);
      if (error) throw error;
      if (updates.is_verified) {
        notifyAccount(transporterId, { type: "system", title: "Compte validé", body: "Votre compte transporteur est vérifié : vous pouvez candidater aux missions." });
      }
      await loadAllData(account);
      setNotice("Statut transporteur mis à jour.");
    } catch (err) { setError(err.message || "Erreur lors de la mise à jour du transporteur."); }
    finally { setActionLoading(false); }
  }

  async function updateDocumentStatus(documentId, status) {
    setActionLoading(true); setError(""); setNotice("");
    try {
      const { error } = await supabase.from("documents").update({ status }).eq("id", documentId);
      if (error) throw error;
      await loadAllData(account);
      setNotice("Document mis à jour.");
    } catch (err) { setError(err.message || "Erreur lors de la mise à jour du document."); }
    finally { setActionLoading(false); }
  }

  async function uploadTransporterDocument(e) {
    const file = e.target.files?.[0];
    if (!file || !account) return;
    setActionLoading(true); setError(""); setNotice("");
    try {
      const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_");
      const path = `${account.id}/${Date.now()}-${safeName}`;
      const { error: uploadError } = await supabase.storage.from("documents").upload(path, file, { upsert: false });
      if (uploadError) throw uploadError;
      const { data: publicUrlData } = supabase.storage.from("documents").getPublicUrl(path);
      const { data, error: insertError } = await supabase.from("documents").insert({
        account_id: account.id, type: documentType, document_type: documentType,
        file_name: file.name, file_path: path, file_url: publicUrlData.publicUrl, status: "uploaded",
      }).select("*").single();
      if (insertError) throw insertError;
      setDocuments((prev) => [documentFromDb(data), ...prev]);
      setNotice("Pièce justificative envoyée.");
      e.target.value = "";
    } catch (err) { setError(err.message || "Erreur lors de l’envoi du document."); }
    finally { setActionLoading(false); }
  }

  function getDocumentsForAccount(accountId) { return documents.filter((doc) => doc.accountId === accountId); }
  function getTrackingEventsForMission(missionId) { return trackingEvents.filter((event) => event.missionId === missionId); }
  function getTrackingPhotosForEvent(eventId) { return trackingPhotos.filter((photo) => photo.trackingEventId === eventId); }
  function trackingKey(missionId, eventType) { return `${missionId}-${eventType}`; }

  function getTrackingForm(missionId, eventType) {
    return trackingForms[trackingKey(missionId, eventType)] || {
      comment: "", odometerKm: "", fuelLevel: "unknown", issueType: "autre", issueSeverity: "moyen", photoType: "general", files: [],
    };
  }
  function updateTrackingForm(missionId, eventType, patch) {
    const key = trackingKey(missionId, eventType);
    setTrackingForms((prev) => ({ ...prev, [key]: { ...getTrackingForm(missionId, eventType), ...patch } }));
  }
  function progressFromEventType(eventType) {
    if (eventType === "pickup_inspection") return "pickup_completed";
    if (eventType === "road_incident") return "incident_reported";
    if (eventType === "delivery_inspection") return "delivery_completed";
    return "assigned_pending";
  }

  async function submitTrackingEvent(mission, eventType) {
    const form = getTrackingForm(mission.id, eventType);
    const files = form.files || [];
    setActionLoading(true); setError(""); setNotice("");
    try {
      const { data: createdEvent, error: eventError } = await supabase.from("mission_tracking_events").insert({
        mission_id: mission.id, transporter_id: account.id, event_type: eventType,
        title: labelTrackingEventType(eventType), comment: form.comment || null,
        odometer_km: form.odometerKm ? Number(form.odometerKm) : null, fuel_level: form.fuelLevel || "unknown",
        issue_type: eventType === "road_incident" ? form.issueType : null,
        issue_severity: eventType === "road_incident" ? form.issueSeverity : null,
      }).select("*").single();
      if (eventError) throw eventError;

      const createdPhotos = [];
      for (const file of files) {
        const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_");
        const path = `${mission.id}/${createdEvent.id}/${Date.now()}-${safeName}`;
        const { error: uploadError } = await supabase.storage.from("mission-photos").upload(path, file, { upsert: false });
        if (uploadError) throw uploadError;
        const { data: publicUrlData } = supabase.storage.from("mission-photos").getPublicUrl(path);
        const { data: createdPhoto, error: photoError } = await supabase.from("mission_tracking_photos").insert({
          tracking_event_id: createdEvent.id, mission_id: mission.id, transporter_id: account.id,
          photo_type: form.photoType || "general", file_name: file.name, file_path: path, file_url: publicUrlData.publicUrl,
        }).select("*").single();
        if (photoError) throw photoError;
        createdPhotos.push(trackingPhotoFromDb(createdPhoto));
      }

      const missionPatch = { progress_status: progressFromEventType(eventType), last_tracking_event_at: new Date().toISOString() };
      if (eventType === "delivery_inspection") missionPatch.status = "completed";
      const { error: missionUpdateError } = await supabase.from("missions").update(missionPatch).eq("id", mission.id);
      if (missionUpdateError) throw missionUpdateError;

      setTrackingEvents((prev) => [trackingEventFromDb(createdEvent), ...prev]);
      setTrackingPhotos((prev) => [...createdPhotos, ...prev]);
      updateTrackingForm(mission.id, eventType, { comment: "", odometerKm: "", files: [] });

      // Notifier le client de l'avancement
      if (mission.clientAccountId) {
        const stepLabel = eventType === "pickup_inspection" ? "Véhicule pris en charge"
          : eventType === "delivery_inspection" ? "Véhicule livré"
          : "Incident signalé sur votre transport";
        notifyAccount(mission.clientAccountId, { type: eventType === "delivery_inspection" ? "delivered" : "tracking_update", title: stepLabel, body: `${mission.fromCity || "Départ"} → ${mission.toCity || "Arrivée"}`, missionId: mission.id });
        triggerPush({ accountId: mission.clientAccountId, title: stepLabel, body: `${mission.fromCity || "Départ"} → ${mission.toCity || "Arrivée"}`, url: "/", missionId: mission.id });
      }

      setNotice(eventType === "delivery_inspection" ? "Livraison validée et état des lieux d’arrivée transmis." : `${labelTrackingEventType(eventType)} transmis.`);
      await loadAllData(account);
    } catch (err) { setError(err.message || "Erreur lors de l’envoi du suivi mission."); }
    finally { setActionLoading(false); }
  }

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
        <label className="field field-full">
          <span>Photos{isDelivery ? " de livraison" : ""}</span>
          <input type="file" accept="image/*,.pdf" multiple onChange={(e) => updateTrackingForm(mission.id, eventType, { files: Array.from(e.target.files || []) })} />
        </label>
        <label className="field field-full">
          <span>Commentaire</span>
          <textarea value={form.comment} onChange={(e) => updateTrackingForm(mission.id, eventType, { comment: e.target.value })} placeholder="État du véhicule, réserves ou problème constaté." />
        </label>
        {isDelivery ? (
          <button className="btn primary field-full track-submit deliver" type="button" onClick={() => submitTrackingEvent(mission, eventType)}>
            Valider la livraison
          </button>
        ) : (
          <button className="btn primary field-full track-submit" type="button" onClick={() => submitTrackingEvent(mission, eventType)}>
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
      const { data, error } = await supabase.storage.from("documents").createSignedUrl(doc.filePath, 120);
      if (error) throw error;
      if (!data?.signedUrl) throw new Error("Lien sécurisé impossible à générer.");
      window.open(data.signedUrl, "_blank", "noopener,noreferrer");
    } catch (err) { setError(err.message || "Impossible d’ouvrir le document sécurisé."); }
  }

  async function signOut() {
    await supabase.auth.signOut();
    supabase.removeAllChannels();
    setSession(null); setAccount(null);
    setMissions([]); setPublicMissions([]); setRequests([]); setApplications([]);
    setTransporters([]); setDocuments([]); setTrackingEvents([]); setTrackingPhotos([]);
    setTrackingForms({}); setNotifications([]);
  }

  function getMissionApplications(missionId) {
    return applications.filter((a) => a.missionId === missionId).sort((a, b) => Number(a.proposedPrice || 999999) - Number(b.proposedPrice || 999999));
  }
  function hasCurrentTransporterApplied(missionId) {
    return applications.some((a) => a.missionId === missionId && a.transporterId === account?.id);
  }

  function renderMissionCard(mission, options = {}) {
    const missionApplications = getMissionApplications(mission.id);
    return (
      <article className="mission-card" key={mission.id}>
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
            <h4>Candidatures</h4>
            {missionApplications.length === 0 && <p className="muted">Aucune candidature.</p>}
            {missionApplications.map((application) => (
              <div className="application-row" key={application.id}>
                <div>
                  <strong>{application.transporterName}</strong>
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
      </article>
    );
  }

  // Génère un document (aperçu imprimable A4) depuis une mission. Réservé admin.
  // Numéros provisoires en aperçu ; l'émission définitive (numéro atomique +
  // signature + archivage PDF) se fait via le flux dédié.
  function openMissionDoc(kind, mission) {
    try {
      let html;
      if (kind === "devis") html = renderDevisHtml(mission);
      else if (kind === "bon") html = renderBonMissionHtml(mission, { name: mission.assignedTransporterName });
      else html = renderFactureHtml(mission, {});
      openDocumentForPrint(html);
    } catch (e) {
      setError(e.message || "Génération du document impossible.");
    }
  }

  function renderCompactDeliveredMissionCard(mission) {
    return (
      <details className="mission-card" key={mission.id}>
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
          <PrivateMissionInfo mission={mission} showPricing={isAdmin} />
          {renderTrackingTimeline(mission)}
        </div>
      </details>
    );
  }

  function renderCompactAdminMissionCard(mission, { delivered = false } = {}) {
    const events = getTrackingEventsForMission(mission.id);
    const photosCount = events.reduce((total, event) => total + getTrackingPhotosForEvent(event.id).length, 0);
    return (
      <details className="mission-card" key={mission.id}>
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
              <span className="muted" style={{ width: "100%", fontSize: "0.8rem" }}>Documents (aperçu imprimable) :</span>
              <button className="btn ghost small" onClick={() => openMissionDoc("devis", mission)}>Devis</button>
              <button className="btn ghost small" onClick={() => openMissionDoc("bon", mission)}>Bon de mission</button>
              <button className="btn ghost small" onClick={() => openMissionDoc("facture", mission)}>Facture</button>
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

  if (!session) return <PublicEntry />;

  if (!account) {
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
                    <article className="mission-card" key={mission.id}>
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
                <MissionForm form={missionForm} setForm={setMissionForm} onSubmit={createMission} submitLabel="Publier la mission" />
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
                    <article className="mission-card" key={mission.id}>
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
                          <article className="mission-card" key={mission.id}>
                            <div className="card-top">
                              <span className="badge">{mission.publicRef}</span>
                              <span className={`status status-${mission.status}`}>{labelStatus(mission.status)}</span>
                            </div>
                            <h3>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
                            <PublicMissionInfo mission={mission} />
                            <PrivateMissionInfo mission={mission} showPricing={isAdmin} />
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
                    <MissionForm form={requestForm} setForm={setRequestForm} onSubmit={createMissionRequest} submitLabel="Envoyer à SECOTO" />
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
                        <label className="field">
                          <span>Fichier PDF / image</span>
                          <input type="file" accept=".pdf,.png,.jpg,.jpeg,.webp" onChange={uploadTransporterDocument} />
                        </label>
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
                  </>
                )}
              </div>
            </section>
          )}
        </>
      )}

        </div>
      </div>

      {isClient && clientTab !== "post" && (
        <button className="fab" onClick={() => setClientTab("post")} aria-label="Nouvelle course">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"><path d="M12 5v14M5 12h14" /></svg>
          Nouvelle course
        </button>
      )}
    </main>
  );
}

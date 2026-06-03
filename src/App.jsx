import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabaseClient";
import "./index.css";

const emptyMissionForm = {
  type: "convoyage",
  fromCity: "",
  toCity: "",
  pickupAddress: "",
  deliveryAddress: "",
  missionDate: "",
  vehicle: "",
  plate: "",
  distanceKm: "",
  clientName: "",
  clientContact: "",
  clientPhone: "",
  priceMode: "fixed",
  proposedPrice: "",
  notes: "",
};

function generatePublicRef(prefix = "SECOTO") {
  return `${prefix}-${new Date().getFullYear()}-${Math.floor(1000 + Math.random() * 9000)}`;
}

function accountFromDb(row) {
  return {
    id: row.id,
    role: row.role,
    fullName: row.full_name,
    companyName: row.company_name,
    email: row.email,
    phone: row.phone,
    city: row.city,
    status: row.status,
    docsCount: row.docs_count,
    isVerified: row.is_verified,
  };
}

function missionFromDb(row) {
  return {
    id: row.id,
    publicRef: row.public_ref,
    type: row.type,
    status: row.status,
    progressStatus: row.progress_status,
    fromCity: row.from_city,
    toCity: row.to_city,
    pickupAddress: row.pickup_address,
    deliveryAddress: row.delivery_address,
    missionDate: row.mission_date,
    vehicle: row.vehicle,
    plate: row.plate,
    distanceKm: row.distance_km,
    clientName: row.client_name,
    clientContact: row.client_contact,
    clientPhone: row.client_phone,
    priceMode: row.price_mode,
    proposedPrice: row.proposed_price,
    notes: row.notes,
    createdByRole: row.created_by_role,
    assignedTransporterId: row.assigned_transporter_id,
    assignedTransporterName: row.assigned_transporter_name,
    sourceRequestId: row.source_request_id,
    createdAt: row.created_at,
  };
}

function publicMissionFromDb(row) {
  return {
    id: row.id,
    publicRef: row.public_ref,
    type: row.type,
    status: row.status,
    progressStatus: row.progress_status,
    fromCity: row.from_city,
    toCity: row.to_city,
    pickupAddress: row.pickup_address,
    deliveryAddress: row.delivery_address,
    vehicle: row.vehicle,
    distanceKm: row.distance_km,
    createdAt: row.created_at,
  };
}

function applicationFromDb(row) {
  return {
    id: row.id,
    missionId: row.mission_id,
    transporterId: row.transporter_id,
    transporterName: row.transporter_name,
    transporterCompany: row.transporter_company,
    transporterStatus: row.transporter_status,
    message: row.message,
    proposedPrice: row.proposed_price,
    priceNote: row.price_note,
    status: row.status,
    createdAt: row.created_at,
  };
}

function documentFromDb(row) {
  return {
    id: row.id,
    missionId: row.mission_id,
    accountId: row.account_id,
    type: row.type,
    fileName: row.file_name,
    filePath: row.file_path,
    fileUrl: row.file_url,
    status: row.status,
    createdAt: row.created_at,
  };
}

function trackingEventFromDb(row) {
  return {
    id: row.id,
    missionId: row.mission_id,
    transporterId: row.transporter_id,
    eventType: row.event_type,
    title: row.title,
    comment: row.comment,
    odometerKm: row.odometer_km,
    fuelLevel: row.fuel_level,
    issueType: row.issue_type,
    issueSeverity: row.issue_severity,
    createdAt: row.created_at,
  };
}

function trackingPhotoFromDb(row) {
  return {
    id: row.id,
    trackingEventId: row.tracking_event_id,
    missionId: row.mission_id,
    transporterId: row.transporter_id,
    photoType: row.photo_type,
    fileName: row.file_name,
    filePath: row.file_path,
    fileUrl: row.file_url,
    createdAt: row.created_at,
  };
}

function labelTrackingEventType(type) {
  if (type === "pickup_inspection") return "État des lieux départ";
  if (type === "road_incident") return "Incident / problème";
  if (type === "delivery_inspection") return "État des lieux arrivée";
  return type || "Suivi mission";
}

function labelFuelLevel(level) {
  const labels = {
    reserve: "Réserve",
    "1/4": "1/4",
    "1/2": "1/2",
    "3/4": "3/4",
    full: "Plein",
    unknown: "Non renseigné",
  };
  return labels[level] || "Non renseigné";
}

function requestFromDb(row) {
  return {
    id: row.id,
    publicRef: row.public_ref,
    status: row.status,
    requesterId: row.requester_id,
    requesterName: row.requester_name,
    requesterCompany: row.requester_company,
    type: row.type,
    fromCity: row.from_city,
    toCity: row.to_city,
    pickupAddress: row.pickup_address,
    deliveryAddress: row.delivery_address,
    missionDate: row.mission_date,
    vehicle: row.vehicle,
    plate: row.plate,
    distanceKm: row.distance_km,
    clientName: row.client_name,
    clientContact: row.client_contact,
    clientPhone: row.client_phone,
    priceMode: row.price_mode,
    proposedPrice: row.proposed_price,
    notes: row.notes,
    approvedMissionId: row.approved_mission_id,
    createdAt: row.created_at,
  };
}

function missionToDb(form, extra = {}) {
  return {
    public_ref: extra.publicRef || generatePublicRef("MIS"),
    type: form.type || "convoyage",
    status: extra.status || "published",
    from_city: form.fromCity || null,
    to_city: form.toCity || null,
    pickup_address: form.pickupAddress || null,
    delivery_address: form.deliveryAddress || null,
    mission_date: form.missionDate || null,
    vehicle: form.vehicle || null,
    plate: form.plate || null,
    distance_km: form.distanceKm ? Number(form.distanceKm) : null,
    client_name: form.clientName || null,
    client_contact: form.clientContact || null,
    client_phone: form.clientPhone || null,
    price_mode: form.priceMode || "fixed",
    proposed_price: form.proposedPrice ? Number(form.proposedPrice) : null,
    notes: form.notes || null,
    created_by_role: extra.createdByRole || "admin",
    assigned_transporter_id: extra.assignedTransporterId || null,
    assigned_transporter_name: extra.assignedTransporterName || null,
    source_request_id: extra.sourceRequestId || null,
  };
}

function requestToDb(form, account) {
  return {
    ...missionToDb(form, {}),
    public_ref: generatePublicRef("REQ"),
    status: "pending",
    requester_id: account.id,
    requester_name: account.fullName,
    requester_company: account.companyName,
    approved_mission_id: null,
  };
}

function Field({ label, name, value, onChange, type = "text", placeholder = "" }) {
  return (
    <label className="field">
      <span>{label}</span>
      <input type={type} name={name} value={value ?? ""} placeholder={placeholder} onChange={onChange} />
    </label>
  );
}

function Tabs({ items, active, onChange }) {
  return (
    <div className="tabs">
      {items.map((item) => (
        <button key={item.value} type="button" className={active === item.value ? "active" : ""} onClick={() => onChange(item.value)}>
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
      <Field label="Ville de départ" name="fromCity" value={form.fromCity} onChange={update} />
      <Field label="Ville d’arrivée" name="toCity" value={form.toCity} onChange={update} />
      <Field label="Adresse de départ" name="pickupAddress" value={form.pickupAddress} onChange={update} />
      <Field label="Adresse d’arrivée" name="deliveryAddress" value={form.deliveryAddress} onChange={update} />
      <Field label="Date / heure" name="missionDate" value={form.missionDate} onChange={update} type="datetime-local" />
      <Field label="Véhicule" name="vehicle" value={form.vehicle} onChange={update} placeholder="Ex : Renault Clio" />
      <Field label="Immatriculation" name="plate" value={form.plate} onChange={update} />
      <Field label="Distance km" name="distanceKm" value={form.distanceKm} onChange={update} type="number" />
      <Field label="Nom client" name="clientName" value={form.clientName} onChange={update} />
      <Field label="Contact client" name="clientContact" value={form.clientContact} onChange={update} />
      <Field label="Téléphone client" name="clientPhone" value={form.clientPhone} onChange={update} />
      <label className="field">
        <span>Mode de prix</span>
        <select name="priceMode" value={form.priceMode} onChange={update}>
          <option value="fixed">Prix fixe</option>
          <option value="negotiable">À négocier</option>
          <option value="hidden">Masqué</option>
        </select>
      </label>
      <Field label="Prix proposé €" name="proposedPrice" value={form.proposedPrice} onChange={update} type="number" />
      <label className="field field-full">
        <span>Notes internes</span>
        <textarea name="notes" value={form.notes} onChange={update} />
      </label>
      <button className="btn primary field-full" type="submit">{submitLabel}</button>
    </form>
  );
}

function PublicMissionInfo({ mission }) {
  return (
    <div className="card-section">
      <p><strong>Départ :</strong> {mission.pickupAddress || mission.fromCity || "Non renseigné"}</p>
      <p><strong>Arrivée :</strong> {mission.deliveryAddress || mission.toCity || "Non renseigné"}</p>
      <p><strong>Type de transport :</strong> {mission.type === "plateau" ? "Transport par plateau" : "Convoyage"}</p>
      <p><strong>Type de véhicule :</strong> {mission.vehicle || "Non renseigné"}</p>
      <p><strong>Distance :</strong> {mission.distanceKm ? `${mission.distanceKm} km` : "Non renseignée"}</p>
    </div>
  );
}

function PrivateMissionInfo({ mission }) {
  return (
    <div className="card-section private-box">
      <p><strong>Date :</strong> {mission.missionDate || "Non renseignée"}</p>
      <p><strong>Client :</strong> {mission.clientName || "Non renseigné"}</p>
      <p><strong>Contact :</strong> {mission.clientContact || "Non renseigné"}</p>
      <p><strong>Téléphone :</strong> {mission.clientPhone || "Non renseigné"}</p>
      <p><strong>Immatriculation :</strong> {mission.plate || "Non renseignée"}</p>
      <p><strong>Prix proposé :</strong> {mission.proposedPrice ? `${mission.proposedPrice} €` : "Non renseigné"}</p>
      <p><strong>Notes internes :</strong> {mission.notes || "Aucune note"}</p>
    </div>
  );
}

function AuthScreen() {
  const [authMode, setAuthMode] = useState("login");
  const [email, setEmail] = useState("contact.secoto@gmail.com");
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
    setLoading(true);
    setError("");
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) setError(error.message);
    setLoading(false);
  }

  async function handleSignup(e) {
    e.preventDefault();
    setLoading(true);
    setError("");
    setNotice("");

    const cleanEmail = email.trim().toLowerCase();

    const { data, error } = await supabase.auth.signUp({
      email: cleanEmail,
      password,
      options: {
        data: {
          role: "transporter",
          full_name: fullName || "",
          company_name: companyName || "",
          phone: phone || "",
          city: city || "",
        },
      },
    });

    if (error) {
      setError(error.message);
      setLoading(false);
      return;
    }

    if (!data.user) {
      setNotice("Compte créé. Vérifiez l’email si Supabase demande une confirmation.");
      setLoading(false);
      return;
    }

    setNotice("Compte transporteur créé. Il devra être validé par SECOTO avant candidature.");

    setLoading(false);
  }

  return (
    <main className="app-shell">
      <header className="app-header">
        <div>
          <p className="eyebrow">SECOTO</p>
          <h1>Connexion plateforme</h1>
          <p className="subtitle">Accès sécurisé admin et transporteurs via Supabase Auth.</p>
        </div>
      </header>

      {error && <div className="alert error">{error}</div>}
      {notice && <div className="alert success">{notice}</div>}

      <Tabs
        active={authMode}
        onChange={setAuthMode}
        items={[
          { value: "login", label: "Connexion" },
          { value: "signup", label: "Inscription transporteur" },
        ]}
      />

      <section className="layout">
        <div className="panel panel-full">
          {authMode === "login" && (
            <>
              <h2>Connexion</h2>
              <form className="form-grid" onSubmit={handleLogin}>
                <Field label="Email" name="email" value={email} onChange={(e) => setEmail(e.target.value)} type="email" />
                <Field label="Mot de passe" name="password" value={password} onChange={(e) => setPassword(e.target.value)} type="password" />
                <button className="btn primary field-full" type="submit" disabled={loading}>{loading ? "Connexion..." : "Se connecter"}</button>
              </form>
            </>
          )}

          {authMode === "signup" && (
            <>
              <h2>Inscription transporteur</h2>
              <form className="form-grid" onSubmit={handleSignup}>
                <Field label="Nom complet" name="fullName" value={fullName} onChange={(e) => setFullName(e.target.value)} />
                <Field label="Société" name="companyName" value={companyName} onChange={(e) => setCompanyName(e.target.value)} />
                <Field label="Email" name="email" value={email} onChange={(e) => setEmail(e.target.value)} type="email" />
                <Field label="Mot de passe" name="password" value={password} onChange={(e) => setPassword(e.target.value)} type="password" />
                <Field label="Téléphone" name="phone" value={phone} onChange={(e) => setPhone(e.target.value)} />
                <Field label="Ville" name="city" value={city} onChange={(e) => setCity(e.target.value)} />
                <button className="btn primary field-full" type="submit" disabled={loading}>{loading ? "Création..." : "Créer mon compte"}</button>
              </form>
            </>
          )}
        </div>
      </section>
    </main>
  );
}

export default function App() {
  const [session, setSession] = useState(null);
  const [account, setAccount] = useState(null);
  const [bootLoading, setBootLoading] = useState(true);

  const [mode, setMode] = useState("admin");
  const [adminTab, setAdminTab] = useState("create");
  const [transporterTab, setTransporterTab] = useState("available");

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
  const [applicationMessages, setApplicationMessages] = useState({});
  const [applicationPrices, setApplicationPrices] = useState({});
  const [documentType, setDocumentType] = useState("assurance_rc_pro");

  const [loading, setLoading] = useState(false);
  const [actionLoading, setActionLoading] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  useEffect(() => {
    let mounted = true;

    const timer = setTimeout(() => {
      if (mounted) {
        setBootLoading(false);
        setSession(null);
        setAccount(null);
        setError("Chargement trop long. Session réinitialisée côté interface.");
      }
    }, 3000);

    async function boot() {
      try {
        const { data, error } = await supabase.auth.getSession();
        if (error) throw error;
        if (!mounted) return;

        clearTimeout(timer);
        const currentSession = data?.session || null;
        setSession(currentSession);
        setBootLoading(false);

        if (currentSession?.user?.id) {
          loadAccount(currentSession.user.id);
        }
      } catch (err) {
        if (mounted) {
          clearTimeout(timer);
          setError(err.message || "Erreur au chargement de la session Supabase.");
          setSession(null);
          setAccount(null);
          setBootLoading(false);
        }
      }
    }

    boot();

    const { data: listener } = supabase.auth.onAuthStateChange((_event, newSession) => {
      setSession(newSession || null);
      if (newSession?.user?.id) loadAccount(newSession.user.id);
      else setAccount(null);
    });

    return () => {
      mounted = false;
      clearTimeout(timer);
      listener?.subscription?.unsubscribe();
    };
  }, []);

  useEffect(() => {
    if (account) {
      setMode(account.role === "admin" ? "admin" : "transporter");
      loadAllData(account);
    }
  }, [account]);

  async function loadAccount(userId) {
    setError("");
    try {
      const timeout = new Promise((_, reject) => setTimeout(() => reject(new Error("Timeout chargement profil SECOTO")), 3000));
      const query = supabase.from("accounts").select("*").eq("id", userId).single();
      const { data, error } = await Promise.race([query, timeout]);
      if (error) throw error;
      setAccount(accountFromDb(data));
    } catch (err) {
      setError(err.message || "Profil SECOTO introuvable ou bloqué par RLS.");
      setAccount(null);
    }
  }

  const publishedMissions = useMemo(() => missions.filter((m) => m.status === "published"), [missions]);
  const assignedMissions = useMemo(() => missions.filter((m) => m.status === "assigned"), [missions]);
  const completedMissions = useMemo(() => missions.filter((m) => m.status === "completed"), [missions]);

  const pendingRequests = useMemo(() => requests.filter((r) => r.status === "pending"), [requests]);
  const pendingApplications = useMemo(() => applications.filter((a) => a.status === "pending"), [applications]);

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
    [assignedMissions, trackingEvents]
  );

  const completedOrDeliveredMissions = useMemo(() => {
    const completedMap = new Map();
    completedMissions.forEach((mission) => completedMap.set(mission.id, mission));
    assignedMissions
      .filter((mission) => isMissionDeliveryValidated(mission))
      .forEach((mission) => completedMap.set(mission.id, mission));
    return Array.from(completedMap.values());
  }, [assignedMissions, completedMissions, trackingEvents]);

  const adminStats = useMemo(() => ({
    total: missions.length,
    published: publishedMissions.length,
    assigned: activeAssignedMissions.length,
    completed: completedOrDeliveredMissions.length,
    pendingRequests: pendingRequests.length,
    pendingApplications: pendingApplications.length,
  }), [missions.length, publishedMissions.length, activeAssignedMissions.length, completedOrDeliveredMissions.length, pendingRequests.length, pendingApplications.length]);

  async function loadAllData(currentAccount = account) {
    if (!currentAccount) return;
    setLoading(true);
    setError("");
    setNotice("");

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

        if (missionsResult.error) throw missionsResult.error;
        if (requestsResult.error) throw requestsResult.error;
        if (applicationsResult.error) throw applicationsResult.error;
        if (transportersResult.error) throw transportersResult.error;
        if (documentsResult.error) throw documentsResult.error;
        if (trackingEventsResult.error) throw trackingEventsResult.error;
        if (trackingPhotosResult.error) throw trackingPhotosResult.error;

        setMissions((missionsResult.data || []).map(missionFromDb));
        setPublicMissions([]);
        setRequests((requestsResult.data || []).map(requestFromDb));
        setApplications((applicationsResult.data || []).map(applicationFromDb));
        setTransporters((transportersResult.data || []).map(accountFromDb));
        setDocuments((documentsResult.data || []).map(documentFromDb));
        setTrackingEvents((trackingEventsResult.data || []).map(trackingEventFromDb));
        setTrackingPhotos((trackingPhotosResult.data || []).map(trackingPhotoFromDb));
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

        if (publicResult.error) throw publicResult.error;
        if (privateResult.error) throw privateResult.error;
        if (requestsResult.error) throw requestsResult.error;
        if (applicationsResult.error) throw applicationsResult.error;
        if (documentsResult.error) throw documentsResult.error;
        if (trackingEventsResult.error) throw trackingEventsResult.error;
        if (trackingPhotosResult.error) throw trackingPhotosResult.error;

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

  async function createMission(e) {
    e.preventDefault();
    setActionLoading(true);
    setError("");
    setNotice("");

    try {
      const { data, error } = await supabase.from("missions").insert(
        missionToDb(missionForm, { status: "published", createdByRole: "admin" })
      ).select("*").single();

      if (error) throw error;
      setMissions((prev) => [missionFromDb(data), ...prev]);
      setMissionForm(emptyMissionForm);
      setNotice("Mission publiée avec succès.");
      setAdminTab("published");
    } catch (err) {
      setError(err.message || "Erreur lors de la création de mission.");
    } finally {
      setActionLoading(false);
    }
  }

  async function createMissionRequest(e) {
    e.preventDefault();
    setActionLoading(true);
    setError("");
    setNotice("");

    try {
      if (!account?.isVerified) throw new Error("Votre compte transporteur doit être vérifié pour proposer une mission.");

      const { data, error } = await supabase.from("mission_requests").insert(requestToDb(requestForm, account)).select("*").single();
      if (error) throw error;

      setRequests((prev) => [requestFromDb(data), ...prev]);
      setRequestForm(emptyMissionForm);
      setNotice("Demande envoyée à SECOTO pour validation.");
      setTransporterTab("requests");
    } catch (err) {
      setError(err.message || "Erreur lors de la demande de mise en ligne.");
    } finally {
      setActionLoading(false);
    }
  }

  async function applyToMission(missionId) {
    setActionLoading(true);
    setError("");
    setNotice("");

    try {
      if (!account?.isVerified) throw new Error("Votre compte transporteur doit être vérifié par SECOTO pour candidater.");

      const alreadyApplied = applications.some((a) => a.missionId === missionId && a.transporterId === account.id);
      if (alreadyApplied) throw new Error("Vous avez déjà candidaté à cette mission.");

      const rawPrice = applicationPrices[missionId];
      const proposedPrice = Number(rawPrice);

      if (!rawPrice || Number.isNaN(proposedPrice) || proposedPrice <= 0) {
        throw new Error("Veuillez indiquer un tarif proposé valide.");
      }

      const { data, error } = await supabase
        .from("mission_applications")
        .insert({
          mission_id: missionId,
          transporter_id: account.id,
          transporter_name: account.fullName,
          transporter_company: account.companyName,
          transporter_status: account.isVerified ? "verified" : "unverified",
          message: applicationMessages[missionId] || null,
          proposed_price: proposedPrice,
          price_note: applicationMessages[missionId] || null,
          status: "pending",
        })
        .select("*")
        .single();

      if (error) throw error;
      setApplications((prev) => [applicationFromDb(data), ...prev]);
      setApplicationMessages((prev) => ({ ...prev, [missionId]: "" }));
      setApplicationPrices((prev) => ({ ...prev, [missionId]: "" }));
      setNotice("Candidature envoyée avec votre tarif.");
      setTransporterTab("applications");
    } catch (err) {
      setError(err.message || "Erreur lors de la candidature.");
    } finally {
      setActionLoading(false);
    }
  }

  async function assignMission(missionId, application) {
    setActionLoading(true);
    setError("");
    setNotice("");

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

      await loadAllData(account);
      setNotice("Mission attribuée au transporteur.");
      setAdminTab("assigned");
    } catch (err) {
      setError(err.message || "Erreur lors de l’attribution.");
    } finally {
      setActionLoading(false);
    }
  }

  async function markMissionCompleted(missionId) {
    setActionLoading(true);
    setError("");
    setNotice("");

    try {
      const { error } = await supabase.from("missions").update({ status: "completed" }).eq("id", missionId);
      if (error) throw error;
      await loadAllData(account);
      setNotice("Mission marquée comme terminée.");
      setAdminTab("completed");
    } catch (err) {
      setError(err.message || "Erreur lors du changement de statut.");
    } finally {
      setActionLoading(false);
    }
  }

  async function approveRequest(request) {
    setActionLoading(true);
    setError("");
    setNotice("");

    try {
      const { data: createdMission, error: missionError } = await supabase.from("missions").insert(
        missionToDb(request, { status: "published", createdByRole: "transporter_request", sourceRequestId: request.id })
      ).select("*").single();

      if (missionError) throw missionError;

      const { error: requestError } = await supabase.from("mission_requests").update({
        status: "approved",
        approved_mission_id: createdMission.id,
      }).eq("id", request.id);

      if (requestError) throw requestError;

      await loadAllData(account);
      setNotice("Demande validée et mission publiée.");
      setAdminTab("published");
    } catch (err) {
      setError(err.message || "Erreur lors de la validation de la demande.");
    } finally {
      setActionLoading(false);
    }
  }

  async function rejectRequest(requestId) {
    setActionLoading(true);
    setError("");
    setNotice("");

    try {
      const { error } = await supabase.from("mission_requests").update({ status: "rejected" }).eq("id", requestId);
      if (error) throw error;
      await loadAllData(account);
      setNotice("Demande refusée.");
    } catch (err) {
      setError(err.message || "Erreur lors du refus de la demande.");
    } finally {
      setActionLoading(false);
    }
  }

  async function updateTransporterStatus(transporterId, updates) {
    setActionLoading(true);
    setError("");
    setNotice("");

    try {
      const { error } = await supabase
        .from("accounts")
        .update(updates)
        .eq("id", transporterId);

      if (error) throw error;

      await loadAllData(account);
      setNotice("Statut transporteur mis à jour.");
    } catch (err) {
      setError(err.message || "Erreur lors de la mise à jour du transporteur.");
    } finally {
      setActionLoading(false);
    }
  }

  async function updateDocumentStatus(documentId, status) {
    setActionLoading(true);
    setError("");
    setNotice("");

    try {
      const { error } = await supabase
        .from("documents")
        .update({ status })
        .eq("id", documentId);

      if (error) throw error;

      await loadAllData(account);
      setNotice("Document mis à jour.");
    } catch (err) {
      setError(err.message || "Erreur lors de la mise à jour du document.");
    } finally {
      setActionLoading(false);
    }
  }

  async function uploadTransporterDocument(e) {
    const file = e.target.files?.[0];
    if (!file || !account) return;

    setActionLoading(true);
    setError("");
    setNotice("");

    try {
      const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_");
      const path = `${account.id}/${Date.now()}-${safeName}`;

      const { error: uploadError } = await supabase.storage
        .from("documents")
        .upload(path, file, { upsert: false });

      if (uploadError) throw uploadError;

      const { data: publicUrlData } = supabase.storage
        .from("documents")
        .getPublicUrl(path);

      const { data, error: insertError } = await supabase
        .from("documents")
        .insert({
          account_id: account.id,
          type: documentType,
          document_type: documentType,
          file_name: file.name,
          file_path: path,
          file_url: publicUrlData.publicUrl,
          status: "uploaded",
        })
        .select("*")
        .single();

      if (insertError) throw insertError;

      setDocuments((prev) => [documentFromDb(data), ...prev]);
      setNotice("Pièce justificative envoyée.");
      e.target.value = "";
    } catch (err) {
      setError(err.message || "Erreur lors de l’envoi du document.");
    } finally {
      setActionLoading(false);
    }
  }

  function getDocumentsForAccount(accountId) {
    return documents.filter((doc) => doc.accountId === accountId);
  }

  function getTrackingEventsForMission(missionId) {
    return trackingEvents.filter((event) => event.missionId === missionId);
  }

  function getTrackingPhotosForEvent(eventId) {
    return trackingPhotos.filter((photo) => photo.trackingEventId === eventId);
  }

  function trackingKey(missionId, eventType) {
    return `${missionId}-${eventType}`;
  }

  function getTrackingForm(missionId, eventType) {
    return trackingForms[trackingKey(missionId, eventType)] || {
      comment: "",
      odometerKm: "",
      fuelLevel: "unknown",
      issueType: "autre",
      issueSeverity: "moyen",
      photoType: "general",
      files: [],
    };
  }

  function updateTrackingForm(missionId, eventType, patch) {
    const key = trackingKey(missionId, eventType);
    setTrackingForms((prev) => ({
      ...prev,
      [key]: {
        ...getTrackingForm(missionId, eventType),
        ...patch,
      },
    }));
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

    setActionLoading(true);
    setError("");
    setNotice("");

    try {
      const { data: createdEvent, error: eventError } = await supabase
        .from("mission_tracking_events")
        .insert({
          mission_id: mission.id,
          transporter_id: account.id,
          event_type: eventType,
          title: labelTrackingEventType(eventType),
          comment: form.comment || null,
          odometer_km: form.odometerKm ? Number(form.odometerKm) : null,
          fuel_level: form.fuelLevel || "unknown",
          issue_type: eventType === "road_incident" ? form.issueType : null,
          issue_severity: eventType === "road_incident" ? form.issueSeverity : null,
        })
        .select("*")
        .single();

      if (eventError) throw eventError;

      const createdPhotos = [];

      for (const file of files) {
        const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_");
        const path = `${mission.id}/${createdEvent.id}/${Date.now()}-${safeName}`;

        const { error: uploadError } = await supabase.storage
          .from("mission-photos")
          .upload(path, file, { upsert: false });

        if (uploadError) throw uploadError;

        const { data: publicUrlData } = supabase.storage
          .from("mission-photos")
          .getPublicUrl(path);

        const { data: createdPhoto, error: photoError } = await supabase
          .from("mission_tracking_photos")
          .insert({
            tracking_event_id: createdEvent.id,
            mission_id: mission.id,
            transporter_id: account.id,
            photo_type: form.photoType || "general",
            file_name: file.name,
            file_path: path,
            file_url: publicUrlData.publicUrl,
          })
          .select("*")
          .single();

        if (photoError) throw photoError;
        createdPhotos.push(trackingPhotoFromDb(createdPhoto));
      }

      const missionPatch = {
        progress_status: progressFromEventType(eventType),
        last_tracking_event_at: new Date().toISOString(),
      };

      if (eventType === "delivery_inspection") {
        missionPatch.status = "completed";
      }

      const { error: missionUpdateError } = await supabase
        .from("missions")
        .update(missionPatch)
        .eq("id", mission.id);

      if (missionUpdateError) throw missionUpdateError;

      setTrackingEvents((prev) => [trackingEventFromDb(createdEvent), ...prev]);
      setTrackingPhotos((prev) => [...createdPhotos, ...prev]);
      updateTrackingForm(mission.id, eventType, { comment: "", odometerKm: "", files: [] });
      setNotice(
        eventType === "delivery_inspection"
          ? "Livraison validée et état des lieux d’arrivée transmis."
          : `${labelTrackingEventType(eventType)} transmis.`
      );
      await loadAllData(account);
    } catch (err) {
      setError(err.message || "Erreur lors de l’envoi du suivi mission.");
    } finally {
      setActionLoading(false);
    }
  }

  function hasDeliveryInspection(missionId) {
    return trackingEvents.some(
      (event) => event.missionId === missionId && event.eventType === "delivery_inspection"
    );
  }

  function isMissionDeliveryValidated(mission) {
    return (
      mission.progressStatus === "delivery_completed" ||
      mission.progressStatus === "completed" ||
      mission.status === "completed" ||
      hasDeliveryInspection(mission.id)
    );
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
                <span className="status">{new Date(event.createdAt).toLocaleString("fr-FR")}</span>
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
                        <a className="btn ghost" href={photo.fileUrl} target="_blank" rel="noreferrer">Ouvrir</a>
                      </div>

                      {isImage && (
                        <a href={photo.fileUrl} target="_blank" rel="noreferrer">
                          <img
                            src={photo.fileUrl}
                            alt={photo.fileName || "Photo état des lieux"}
                            style={{
                              width: "100%",
                              maxHeight: "220px",
                              objectFit: "cover",
                              borderRadius: "18px",
                              marginTop: "12px",
                              border: "1px solid rgba(255,255,255,0.12)",
                            }}
                          />
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

    return (
      <div className="mission-card">
        <div className="card-top">
          <h3>{labelTrackingEventType(eventType)}</h3>
          <span className="badge">Photos terrain</span>
        </div>

        <div className="form-grid" style={{ marginTop: 14 }}>
          <Field
            label="Kilométrage"
            name="odometerKm"
            type="number"
            value={form.odometerKm}
            onChange={(e) => updateTrackingForm(mission.id, eventType, { odometerKm: e.target.value })}
          />

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

          <label className="field">
            <span>Type de photo</span>
            <select value={form.photoType} onChange={(e) => updateTrackingForm(mission.id, eventType, { photoType: e.target.value })}>
              <option value="general">Général</option>
              <option value="avant_gauche">Avant gauche</option>
              <option value="avant_droit">Avant droit</option>
              <option value="arriere_gauche">Arrière gauche</option>
              <option value="arriere_droit">Arrière droit</option>
              <option value="interieur">Intérieur</option>
              <option value="compteur">Compteur / kilométrage</option>
              <option value="carburant">Carburant</option>
              <option value="dommage">Dommage visible</option>
              <option value="document">Document véhicule</option>
              <option value="livraison">Preuve livraison</option>
            </select>
          </label>

          <label className="field">
            <span>Photos</span>
            <input
              type="file"
              accept="image/*,.pdf"
              multiple
              onChange={(e) => updateTrackingForm(mission.id, eventType, { files: Array.from(e.target.files || []) })}
            />
          </label>

          <label className="field field-full">
            <span>Commentaire</span>
            <textarea
              value={form.comment}
              onChange={(e) => updateTrackingForm(mission.id, eventType, { comment: e.target.value })}
              placeholder="Décrivez l’état du véhicule, les réserves ou le problème constaté."
            />
          </label>

          {isDelivery ? (
            <button
              className="btn field-full"
              type="button"
              onClick={() => submitTrackingEvent(mission, eventType)}
              style={{
                minHeight: "68px",
                marginTop: "8px",
                borderRadius: "22px",
                border: "1px solid rgba(34, 197, 94, 0.65)",
                background: "linear-gradient(135deg, rgba(34,197,94,1), rgba(21,128,61,1))",
                boxShadow: "0 20px 55px rgba(34,197,94,0.28), inset 0 1px 0 rgba(255,255,255,0.25)",
                color: "#ffffff",
                fontSize: "1.08rem",
                letterSpacing: "-0.02em",
                textTransform: "uppercase",
              }}
            >
              ✅ Valider la livraison
            </button>
          ) : (
            <button className="btn primary field-full" type="button" onClick={() => submitTrackingEvent(mission, eventType)}>
              Transmettre {labelTrackingEventType(eventType)}
            </button>
          )}
        </div>
      </div>
    );
  }

  async function signOut() {
    await supabase.auth.signOut();
    setSession(null);
    setAccount(null);
    setMissions([]);
    setPublicMissions([]);
    setRequests([]);
    setApplications([]);
    setTransporters([]);
    setDocuments([]);
    setTrackingEvents([]);
    setTrackingPhotos([]);
    setTrackingForms({});
  }

  function getMissionApplications(missionId) {
    return applications
      .filter((application) => application.missionId === missionId)
      .sort((a, b) => {
        const priceA = Number(a.proposedPrice || 999999);
        const priceB = Number(b.proposedPrice || 999999);
        return priceA - priceB;
      });
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
          <span className={`status status-${mission.status}`}>{mission.status}</span>
        </div>

        <h3>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
        <PublicMissionInfo mission={mission} />
        {options.showPrivate && <PrivateMissionInfo mission={mission} />}

        {mission.assignedTransporterName && (
          <p className="assigned">Transporteur attribué : {mission.assignedTransporterName}</p>
        )}

        {options.canComplete && mission.status === "assigned" && (
          <button className="btn primary" onClick={() => markMissionCompleted(mission.id)}>Marquer terminée</button>
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
                  <p className="price-line">
                    <strong>Tarif proposé :</strong>{" "}
                    {application.proposedPrice ? `${Number(application.proposedPrice).toFixed(0)} €` : "Non renseigné"}
                  </p>
                  {application.message && <p>{application.message}</p>}
                  <span className={`status status-${application.status}`}>{application.status}</span>
                </div>

                {mission.status === "published" && application.status === "pending" && (
                  <button className="btn primary" onClick={() => assignMission(mission.id, application)}>Attribuer</button>
                )}
              </div>
            ))}
          </div>
        )}

        {options.showTracking && renderTrackingTimeline(mission)}
      </article>
    );
  }

  function renderCompactDeliveredMissionCard(mission) {
    return (
      <details className="mission-card" key={mission.id}>
        <summary style={{ cursor: "pointer", listStyle: "none" }}>
          <div className="card-top">
            <span className="badge">{mission.publicRef}</span>
            <span className="status status-completed">Livraison validée</span>
          </div>
          <h3 style={{ marginTop: 12 }}>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
          <p className="muted" style={{ marginTop: 8 }}>
            Carte archivée. Cliquez pour revoir le détail, les photos et les preuves terrain.
          </p>
        </summary>

        <div style={{ marginTop: 14 }}>
          <PublicMissionInfo mission={mission} />
          <PrivateMissionInfo mission={mission} />
          {renderTrackingTimeline(mission)}
        </div>
      </details>
    );
  }

  function renderCompactAdminMissionCard(mission, { delivered = false } = {}) {
    const events = getTrackingEventsForMission(mission.id);
    const photosCount = events.reduce((total, event) => {
      return total + getTrackingPhotosForEvent(event.id).length;
    }, 0);

    return (
      <details className="mission-card" key={mission.id}>
        <summary style={{ cursor: "pointer", listStyle: "none" }}>
          <div className="card-top">
            <span className="badge">{mission.publicRef}</span>
            <span className={delivered ? "status status-completed" : `status status-${mission.status}`}>
              {delivered ? "Livraison validée" : mission.status}
            </span>
          </div>

          <h3 style={{ marginTop: 12 }}>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>

          <div className="card-section" style={{ marginTop: 12 }}>
            <p><strong>Transporteur :</strong> {mission.assignedTransporterName || "Non renseigné"}</p>
            <p><strong>Véhicule :</strong> {mission.vehicle || "Non renseigné"}</p>
            <p><strong>Photos / preuves :</strong> {photosCount}</p>
          </div>

          <p className="muted" style={{ marginTop: 10 }}>
            Cliquez pour développer la mission, les informations privées et les photos d’état des lieux.
          </p>
        </summary>

        <div style={{ marginTop: 14 }}>
          <PublicMissionInfo mission={mission} />
          <PrivateMissionInfo mission={mission} />
          {renderTrackingTimeline(mission)}

          {!delivered && mission.status === "assigned" && (
            <button className="btn primary" onClick={() => markMissionCompleted(mission.id)}>
              Marquer terminée
            </button>
          )}
        </div>
      </details>
    );
  }

  if (bootLoading) {
    return (
      <main className="app-shell">
        <div className="alert">Chargement de la session...</div>
        {error && <div className="alert error">{error}</div>}
      </main>
    );
  }

  if (!session) {
    return <AuthScreen />;
  }

  if (!account) {
    return (
      <main className="app-shell">
        <div className="alert error">Session connectée, mais aucun profil SECOTO valide n’est relié à ce compte.</div>
        {error && <div className="alert error">{error}</div>}
        <button className="btn ghost" onClick={() => loadAccount(session.user.id)}>Réessayer</button>
        <button className="btn danger" onClick={signOut}>Se déconnecter</button>
      </main>
    );
  }

  const isAdmin = account.role === "admin";
  const isTransporter = account.role === "transporter";
  const visiblePublicMissions = isAdmin ? publishedMissions : publicMissions;

  return (
    <main className="app-shell">
      <header className="app-header">
        <div>
          <p className="eyebrow">SECOTO</p>
          <h1>Plateforme missions transport</h1>
          <p className="subtitle">
            Connecté : {account.fullName || account.email} — {isAdmin ? "Admin SECOTO" : "Transporteur"}
          </p>
        </div>

        <div className="header-actions">
          {isAdmin && (
            <>
              <button className={mode === "admin" ? "btn primary" : "btn ghost"} onClick={() => setMode("admin")}>Admin SECOTO</button>
              <button className={mode === "transporter" ? "btn primary" : "btn ghost"} onClick={() => setMode("transporter")}>Vue transporteur</button>
            </>
          )}

          {isTransporter && (
            <button className={mode === "transporter" ? "btn primary" : "btn ghost"} onClick={() => setMode("transporter")}>Transporteur</button>
          )}

          <button className="btn ghost" onClick={() => loadAllData(account)}>Actualiser</button>
          <button className="btn danger" onClick={signOut}>Déconnexion</button>
        </div>
      </header>

      {loading && <div className="alert">Chargement Supabase...</div>}
      {actionLoading && <div className="alert">Action en cours...</div>}
      {error && <div className="alert error">{error}</div>}
      {notice && <div className="alert success">{notice}</div>}

      {isAdmin && mode === "admin" && (
        <>
          <KpiGrid stats={adminStats} />

          <Tabs
            active={adminTab}
            onChange={setAdminTab}
            items={[
              { value: "create", label: "Créer mission" },
              { value: "requests", label: "Demandes", count: pendingRequests.length },
              { value: "published", label: "Publiées", count: publishedMissions.length },
              { value: "applications", label: "Candidatures", count: pendingApplications.length },
              { value: "assigned", label: "Attribuées", count: activeAssignedMissions.length },
              { value: "completed", label: "Terminées", count: completedOrDeliveredMissions.length },
              { value: "transporters", label: "Transporteurs", count: transporters.length },
            ]}
          />

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
                        <span className={`status status-${request.status}`}>{request.status}</span>
                      </div>
                      <h3>{request.fromCity || "Départ"} → {request.toCity || "Arrivée"}</h3>
                      <p className="muted">Demandée par {request.requesterName} — {request.requesterCompany}</p>
                      <PublicMissionInfo mission={request} />
                      <PrivateMissionInfo mission={request} />
                      {request.status === "pending" && (
                        <div className="actions-row">
                          <button className="btn primary" onClick={() => approveRequest(request)}>Valider et publier</button>
                          <button className="btn danger" onClick={() => rejectRequest(request.id)}>Refuser</button>
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
                <div className="cards">
                  {publishedMissions.map((mission) => renderMissionCard(mission, { showPrivate: true, showApplications: true }))}
                </div>
              </div>
            </section>
          )}

          {adminTab === "applications" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Candidatures reçues</h2>
                {pendingApplications.length === 0 && <p className="muted">Aucune candidature en attente.</p>}
                <div className="cards">
                  {missions
                    .filter((mission) => getMissionApplications(mission.id).some((application) => application.status === "pending"))
                    .map((mission) => renderMissionCard(mission, { showPrivate: true, showApplications: true }))}
                </div>
              </div>
            </section>
          )}

          {adminTab === "assigned" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Missions attribuées</h2>
                {activeAssignedMissions.length === 0 && (
                  <div className="alert success">
                    Aucune mission attribuée en cours. Les missions livrées sont désormais visibles uniquement dans l’onglet Terminées.
                  </div>
                )}
                {activeAssignedMissions.length > 0 && (
                  <div className="cards">
                    {activeAssignedMissions.map((mission) =>
                      renderCompactAdminMissionCard(mission, { delivered: false })
                    )}
                  </div>
                )}
              </div>
            </section>
          )}

          {adminTab === "completed" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Missions terminées</h2>
                {completedOrDeliveredMissions.length === 0 && <p className="muted">Aucune mission terminée.</p>}
                <div className="cards">
                  {completedOrDeliveredMissions.map((mission) =>
                    renderCompactAdminMissionCard(mission, { delivered: true })
                  )}
                </div>
              </div>
            </section>
          )}

          {adminTab === "transporters" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Transporteurs inscrits</h2>
                {transporters.length === 0 && <p className="muted">Aucun transporteur inscrit.</p>}

                <div className="cards">
                  {transporters.map((transporter) => {
                    const transporterDocs = getDocumentsForAccount(transporter.id);

                    return (
                      <article className="mission-card" key={transporter.id}>
                        <div className="card-top">
                          <span className="badge">{transporter.isVerified ? "VÉRIFIÉ" : "À VÉRIFIER"}</span>
                          <span className={`status status-${transporter.status}`}>{transporter.status}</span>
                        </div>

                        <h3>{transporter.fullName || "Transporteur sans nom"}</h3>

                        <div className="card-section">
                          <p><strong>Société :</strong> {transporter.companyName || "Non renseignée"}</p>
                          <p><strong>Email :</strong> {transporter.email || "Non renseigné"}</p>
                          <p><strong>Téléphone :</strong> {transporter.phone || "Non renseigné"}</p>
                          <p><strong>Ville :</strong> {transporter.city || "Non renseignée"}</p>
                          <p><strong>Documents :</strong> {transporterDocs.length}</p>
                          <p><strong>Vérifié :</strong> {transporter.isVerified ? "Oui" : "Non"}</p>
                        </div>

                        <div className="applications-box">
                          <h4>Pièces justificatives</h4>
                          {transporterDocs.length === 0 && <p className="muted">Aucune pièce justificative envoyée.</p>}

                          {transporterDocs.map((doc) => (
                            <div className="application-row" key={doc.id}>
                              <div>
                                <strong>{doc.type}</strong>
                                <p>{doc.fileName}</p>
                                <span className={`status status-${doc.status}`}>{doc.status}</span>
                              </div>

                              <div className="actions-row">
                                <a className="btn ghost" href={doc.fileUrl} target="_blank" rel="noreferrer">Ouvrir</a>

                                {doc.status !== "validated" && (
                                  <button className="btn primary" onClick={() => updateDocumentStatus(doc.id, "validated")}>
                                    Valider document
                                  </button>
                                )}

                                {doc.status !== "rejected" && (
                                  <button className="btn danger" onClick={() => updateDocumentStatus(doc.id, "rejected")}>
                                    Refuser
                                  </button>
                                )}
                              </div>
                            </div>
                          ))}
                        </div>

                        <div className="actions-row">
                          <button
                            className="btn primary"
                            onClick={() => updateTransporterStatus(transporter.id, { status: "active", is_verified: true, docs_count: transporterDocs.length })}
                          >
                            Valider transporteur
                          </button>

                          <button
                            className="btn ghost"
                            onClick={() => updateTransporterStatus(transporter.id, { status: "pending", is_verified: false })}
                          >
                            Remettre en attente
                          </button>

                          <button
                            className="btn danger"
                            onClick={() => updateTransporterStatus(transporter.id, { status: "suspended", is_verified: false })}
                          >
                            Suspendre
                          </button>
                        </div>
                      </article>
                    );
                  })}
                </div>
              </div>
            </section>
          )}
        </>
      )}

      {(isTransporter || isAdmin) && mode === "transporter" && (
        <>
          <Tabs
            active={transporterTab}
            onChange={setTransporterTab}
            items={[
              { value: "available", label: "Disponibles", count: visiblePublicMissions.length },
              { value: "applications", label: "Mes candidatures", count: currentTransporterApplications.length },
              { value: "assigned", label: "Attribuées", count: assignedToCurrentTransporter.length },
              { value: "request", label: "Proposer" },
              { value: "requests", label: "Mes demandes", count: currentTransporterRequests.length },
              { value: "profile", label: "Profil" },
            ]}
          />

          {transporterTab === "available" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Missions publiques disponibles</h2>
                {isAdmin && <div className="alert">Prévisualisation admin de la vue transporteur.</div>}
                {!isAdmin && !account.isVerified && (
                  <div className="alert error">Compte non vérifié : vous pouvez consulter les missions, mais pas encore candidater.</div>
                )}
                {visiblePublicMissions.length === 0 && <p className="muted">Aucune mission disponible actuellement.</p>}
                <div className="cards">
                  {visiblePublicMissions.map((mission) => (
                    <article className="mission-card" key={mission.id}>
                      <div className="card-top">
                        <span className="badge">{mission.publicRef}</span>
                        <span className={`status status-${mission.status}`}>{mission.status}</span>
                      </div>
                      <h3>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
                      <PublicMissionInfo mission={mission} />
                      <div className="private-locked">Les informations privées seront visibles uniquement si SECOTO vous attribue la mission.</div>

                      {!isAdmin && (
                        <>
                          <input
                            className="message-box"
                            type="number"
                            min="1"
                            step="1"
                            placeholder="Votre tarif proposé (€) — obligatoire"
                            value={applicationPrices[mission.id] || ""}
                            onChange={(e) => setApplicationPrices((prev) => ({ ...prev, [mission.id]: e.target.value }))}
                          />
                          <textarea
                            className="message-box"
                            placeholder="Message optionnel pour SECOTO..."
                            value={applicationMessages[mission.id] || ""}
                            onChange={(e) => setApplicationMessages((prev) => ({ ...prev, [mission.id]: e.target.value }))}
                          />
                          <button
                            className="btn primary"
                            disabled={hasCurrentTransporterApplied(mission.id) || !account.isVerified}
                            onClick={() => applyToMission(mission.id)}
                          >
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
                {isAdmin && <p className="muted">Prévisualisation admin : les candidatures réelles apparaissent uniquement sur un compte transporteur.</p>}
                {!isAdmin && currentTransporterApplications.length === 0 && <p className="muted">Aucune candidature envoyée.</p>}
                <div className="cards">
                  {!isAdmin && currentTransporterApplications.map((application) => {
                    const publicMission = publicMissions.find((item) => item.id === application.missionId);
                    const privateMission = missions.find((item) => item.id === application.missionId);
                    const mission = privateMission || publicMission;

                    return (
                      <article className="mission-card" key={application.id}>
                        <div className="card-top">
                          <span className="badge">{mission?.publicRef || "Mission"}</span>
                          <span className={`status status-${application.status}`}>{application.status}</span>
                        </div>
                        <p className="price-line"><strong>Tarif proposé :</strong> {application.proposedPrice ? `${Number(application.proposedPrice).toFixed(0)} €` : "Non renseigné"}</p>
                        {mission ? (
                          <>
                            <h3>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
                            <PublicMissionInfo mission={mission} />
                          </>
                        ) : (
                          <p>Mission introuvable.</p>
                        )}
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
                {isAdmin && <p className="muted">Prévisualisation admin : les missions attribuées réelles apparaissent uniquement sur le compte transporteur assigné.</p>}

                {!isAdmin && assignedToCurrentTransporter.length === 0 && (
                  <p className="muted">Aucune mission attribuée.</p>
                )}

                {!isAdmin && assignedToCurrentTransporter.length > 0 && (() => {
                  const activeMissions = assignedToCurrentTransporter.filter(
                    (mission) => !isMissionDeliveryValidated(mission)
                  );
                  const deliveredMissions = assignedToCurrentTransporter.filter(
                    (mission) => isMissionDeliveryValidated(mission)
                  );

                  return (
                    <>
                      <div className="cards">
                        {activeMissions.length === 0 && (
                          <div className="alert success">
                            Aucune mission en cours. Les missions livrées sont rangées en petites cartes ci-dessous.
                          </div>
                        )}

                        {activeMissions.map((mission) => (
                          <article className="mission-card" key={mission.id}>
                            <div className="card-top">
                              <span className="badge">{mission.publicRef}</span>
                              <span className={`status status-${mission.status}`}>{mission.status}</span>
                            </div>
                            <h3>{mission.fromCity || "Départ"} → {mission.toCity || "Arrivée"}</h3>
                            <PublicMissionInfo mission={mission} />
                            <PrivateMissionInfo mission={mission} />
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
                          <div className="cards">
                            {deliveredMissions.map((mission) => renderCompactDeliveredMissionCard(mission))}
                          </div>
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
                {isAdmin ? (
                  <p className="muted">Prévisualisation admin : cette action est réservée aux transporteurs vérifiés.</p>
                ) : (
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
                {isAdmin && <p className="muted">Prévisualisation admin : les demandes propres au transporteur apparaissent sur son compte.</p>}
                {!isAdmin && currentTransporterRequests.length === 0 && <p className="muted">Aucune demande envoyée.</p>}
                <div className="cards">
                  {!isAdmin && currentTransporterRequests.map((request) => (
                    <article className="mission-card" key={request.id}>
                      <div className="card-top">
                        <span className="badge">{request.publicRef}</span>
                        <span className={`status status-${request.status}`}>{request.status}</span>
                      </div>
                      <h3>{request.fromCity || "Départ"} → {request.toCity || "Arrivée"}</h3>
                      <PublicMissionInfo mission={request} />
                    </article>
                  ))}
                </div>
              </div>
            </section>
          )}

          {transporterTab === "profile" && (
            <section className="layout">
              <div className="panel panel-full">
                <h2>Profil transporteur</h2>
                {isAdmin ? (
                  <p className="muted">Prévisualisation admin : connecte-toi avec un compte transporteur pour voir son profil réel.</p>
                ) : (
                  <>
                    <div className="profile-card">
                      <p><strong>Nom :</strong> {account.fullName || "Non renseigné"}</p>
                      <p><strong>Société :</strong> {account.companyName || "Non renseigné"}</p>
                      <p><strong>Email :</strong> {account.email}</p>
                      <p><strong>Téléphone :</strong> {account.phone || "Non renseigné"}</p>
                      <p><strong>Ville :</strong> {account.city || "Non renseignée"}</p>
                      <p><strong>Statut :</strong> {account.status}</p>
                      <p><strong>Vérifié :</strong> {account.isVerified ? "Oui" : "Non"}</p>
                    </div>

                    <div className="panel" style={{ marginTop: 18 }}>
                      <h2>Pièces justificatives</h2>
                      <p className="muted">
                        Ajoutez les documents nécessaires : assurance RC pro, extrait Kbis/SIREN, licence transport, carte grise, pièce d’identité ou attestation utile.
                      </p>

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
                              <span className={`status status-${doc.status}`}>{doc.status}</span>
                            </div>
                            <h3>{doc.fileName}</h3>
                            <a className="btn ghost" href={doc.fileUrl} target="_blank" rel="noreferrer">Ouvrir le document</a>
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
    </main>
  );
}

import { useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import { accountFromDb, labelStatus, formatDateTime } from "./lib/mappers";

// Ecran admin : liste des comptes clients + leurs infos + total.
export default function ClientsPanel() {
  const [clients, setClients] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    (async () => {
      try {
        const { data, error } = await supabase
          .from("accounts")
          .select("*")
          .eq("role", "client")
          .order("created_at", { ascending: false });
        if (error) throw error;
        setClients((data || []).map(accountFromDb));
      } catch (e) {
        setError(e.message || "Chargement des clients impossible.");
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  return (
    <div className="panel panel-full">
      <h2>Clients inscrits <span className="badge">{clients.length}</span></h2>
      {error && <div className="alert error">{error}</div>}
      {loading ? (
        <p className="muted">Chargement…</p>
      ) : clients.length === 0 ? (
        <p className="muted">Aucun client inscrit pour le moment.</p>
      ) : (
        <div className="cards">
          {clients.map((c) => (
            <article className="mission-card" key={c.id}>
              <div className="card-top">
                <span className="badge">{c.clientType === "pro" ? "Client pro" : "Particulier"}</span>
                <span className={`status status-${c.status}`}>{labelStatus(c.status)}</span>
              </div>
              <h3>{c.fullName || "Client sans nom"}</h3>
              <div className="card-section">
                {c.companyName && <p><strong>Société :</strong> {c.companyName}</p>}
                <p><strong>Email :</strong> {c.email || "Non renseigné"}</p>
                <p><strong>Téléphone :</strong> {c.phone || "Non renseigné"}</p>
                <p><strong>Ville :</strong> {c.city || "Non renseignée"}</p>
                <p><strong>Inscrit le :</strong> {formatDateTime(c.createdAt)}</p>
              </div>
            </article>
          ))}
        </div>
      )}
    </div>
  );
}

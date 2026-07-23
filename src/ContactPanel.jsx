import { useEffect, useState } from "react";
import { supabase } from "./supabaseClient";

// Contact SECOTO pour les transporteurs : appel direct, WhatsApp, email.
// Les coordonnees sont lues depuis app_settings ('support_contact') et
// configurables sans redeployer (voir patch_contact.sql). Valeurs de repli
// si la table n'est pas encore renseignee.
const FALLBACK = {
  phone: "07 83 27 82 31",
  phone_e164: "+33783278231",
  email: "contact.secoto@gmail.com",
  whatsapp: "33783278231",
  hours: "7j/7",
};

export default function ContactPanel() {
  const [c, setC] = useState(FALLBACK);

  useEffect(() => {
    (async () => {
      try {
        const { data } = await supabase
          .from("app_settings")
          .select("value")
          .eq("key", "support_contact")
          .maybeSingle();
        if (data?.value) setC({ ...FALLBACK, ...data.value });
      } catch {
        /* on garde les valeurs de repli */
      }
    })();
  }, []);

  return (
    <div className="panel contact-panel">
      <h2>Contacter SECOTO</h2>
      <p className="muted" style={{ marginBottom: 16 }}>
        Une question sur une mission, un frais ou un document ? Contactez directement l’équipe SECOTO — réponse rapide, {c.hours}.
      </p>

      <a className="btn primary field-full contact-btn" href={`tel:${c.phone_e164}`}>
        Appeler SECOTO — {c.phone}
      </a>

      <div className="actions-row" style={{ marginTop: 12, flexWrap: "wrap" }}>
        <button
          type="button"
          className="btn field-full contact-btn"
          onClick={() => window.open(`https://wa.me/${c.whatsapp}?text=${encodeURIComponent("Bonjour SECOTO, ")}`, "_system")}
          style={{ background: "#25D366", color: "#fff" }}
        >
          WhatsApp
        </button>
        <a className="btn ghost field-full contact-btn" href={`mailto:${c.email}`}>
          {c.email}
        </a>
      </div>

      <div className="card-section" style={{ marginTop: 16 }}>
        <p><strong>Disponibilité :</strong> {c.hours}</p>
        <p><strong>Téléphone :</strong> <a href={`tel:${c.phone_e164}`}>{c.phone}</a></p>
        <p><strong>Email :</strong> <a href={`mailto:${c.email}`}>{c.email}</a></p>
      </div>
    </div>
  );
}

import { useEffect, useState } from "react";
import { bandeauRequis, enregistrerChoix, estNatif } from "./lib/consentement";

// ============================================================================
// SECOTO 088 — Bandeau cookies (web uniquement).
// « Refuser » et « Accepter » au même niveau, même taille. Rien n'est chargé
// avant un clic sur « Accepter ». Fermer sans choisir = refus, rien n'est déposé.
// Le bandeau se rouvre depuis le Profil (« Gérer mes cookies »).
// ============================================================================

export default function BanniereCookies() {
  const [ouvert, setOuvert] = useState(() => bandeauRequis());

  useEffect(() => {
    if (estNatif()) return undefined;
    const rouvrir = () => setOuvert(true);
    window.addEventListener("secoto:cookies-ouvrir", rouvrir);
    return () => window.removeEventListener("secoto:cookies-ouvrir", rouvrir);
  }, []);

  if (!ouvert) return null;
  const choisir = (accepte) => { enregistrerChoix(accepte); setOuvert(false); };

  return (
    <div className="cookies-bandeau" role="dialog" aria-modal="false" aria-labelledby="cookies-titre">
      {/* 113 : bandeau compact — l'ancien recouvrait le formulaire sur mobile. */}
      <div className="cookies-carte">
        <p className="cookies-texte">
          <strong id="cookies-titre">Cookies de mesure publicitaire</strong> (Google, Meta) : seulement avec votre accord, l’application marche pareil sans.{" "}
          <a href="/politique-confidentialite.html#cookies" target="_blank" rel="noopener noreferrer">En savoir plus</a>
        </p>
        <div className="cookies-actions">
          <button type="button" className="btn cookies-btn" onClick={() => choisir(false)}>Refuser</button>
          <button type="button" className="btn cookies-btn" onClick={() => choisir(true)}>Accepter</button>
        </div>
      </div>
    </div>
  );
}

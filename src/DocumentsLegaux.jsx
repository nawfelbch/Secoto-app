import { useEffect, useState } from "react";
import { DOCUMENT_TITLES, PRIVACY_PATH, conditionsLinks, conditionsUrl, termsPublic } from "./lib/conditions";
import { openExternal } from "./platform/runtime";
import { estNatif, ouvrirReglagesCookies } from "./lib/consentement";

// ============================================================================
// SECOTO 075 — Accès aux documents légaux, visibles et cliquables.
// ----------------------------------------------------------------------------
// Chaque document est un bouton bien identifiable (titre + « Lire »), qui
// s'ouvre dans le navigateur (onglet séparé sur le web, Safari / Chrome sur
// iPhone et Android). Les CGU et les conditions transporteur n'apparaissent
// que lorsque l'interrupteur conditions_v2 est allumé (décision D1) ; la
// politique de confidentialité est toujours accessible.
// ============================================================================

function IconeDocument() {
  return (
    <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" />
      <path d="M14 3v5h5M9 13h6M9 17h4" />
    </svg>
  );
}

export function DocumentsLegaux({ links, onOpen, titre }) {
  if (!links?.length) return null;
  return (
    <div className="docs-legaux">
      {titre && <p className="docs-legaux-titre">{titre}</p>}
      <ul>
        {links.map((l) => (
          <li key={l.key}>
            <a
              className="doc-legal"
              href={l.url}
              target="_blank"
              rel="noopener noreferrer"
              onClick={(e) => { e.preventDefault(); onOpen(l.url); }}
            >
              <span className="doc-legal-icone"><IconeDocument /></span>
              <span className="doc-legal-nom">{l.title || DOCUMENT_TITLES[l.key] || l.label}</span>
              <span className="doc-legal-action">Lire<span aria-hidden="true"> ↗</span></span>
            </a>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** Liste autonome (profil, informations légales) : charge elle-même la version en vigueur. */
export default function LiensLegaux({ role, titre = "Documents" }) {
  const [conditions, setConditions] = useState(null);
  useEffect(() => {
    let vivant = true;
    termsPublic().then((c) => { if (vivant) setConditions(c?.active && c?.version ? c : null); }).catch(() => {});
    return () => { vivant = false; };
  }, []);

  const cles = role === "transporter" || role === "admin"
    ? ["cgu", "confidentialite", "conditions_transporteur"]
    : ["cgu", "confidentialite"];
  const liens = conditions
    ? conditionsLinks(cles, conditions.documents, conditions.version)
    : [{ key: "confidentialite", title: DOCUMENT_TITLES.confidentialite, url: conditionsUrl(PRIVACY_PATH) }];

  return (
    <>
      <DocumentsLegaux links={liens} titre={titre} onOpen={(url) => openExternal(url).catch(() => {})} />
      {/* 088 : le choix de cookies se change à tout moment (web uniquement). */}
      {!estNatif() && (
        <button type="button" className="btn ghost small cookies-gerer" onClick={ouvrirReglagesCookies}>Gérer mes cookies</button>
      )}
    </>
  );
}

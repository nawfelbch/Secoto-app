import { useEffect, useState } from "react";
import { signedUrlCached } from "./lib/privateFiles";

// ============================================================================
// SECOTO — vignette d'un fichier prive, signee seulement quand elle s'affiche.
// ----------------------------------------------------------------------------
// Une photo d'etat des lieux n'est visible que si son etape est ouverte : il
// n'y a aucune raison de demander son URL au chargement de l'ecran, avec des
// centaines d'autres. Le composant la demande lui-meme, une fois, et l'URL
// reste en cache le temps de sa validite.
// ============================================================================

export default function PhotoPrivee({ photo, bucket = "mission-photos", hauteur = 90 }) {
  const [url, setUrl] = useState(null);
  const [echec, setEchec] = useState(false);

  useEffect(() => {
    let vivant = true;
    if (!photo?.filePath) { setEchec(true); return undefined; }
    signedUrlCached(bucket, photo.filePath).then((signee) => {
      if (!vivant) return;
      if (signee) setUrl(signee); else setEchec(true);
    });
    return () => { vivant = false; };
  }, [photo?.filePath, bucket]);

  const nom = photo?.fileName || "photo";
  const estImage = /\.(png|jpg|jpeg|webp|gif)$/i.test(nom);

  if (echec) {
    return <span className="muted" style={{ fontSize: 12 }}>Fichier indisponible</span>;
  }
  if (!url) {
    return (
      <div
        aria-busy="true"
        style={{
          width: "100%", height: hauteur, borderRadius: 12,
          border: "1px solid var(--border)", background: "var(--surface-2, rgba(127,127,127,.12))",
        }}
      />
    );
  }
  if (!estImage) {
    return <a className="btn ghost small" href={url} target="_blank" rel="noreferrer">Document</a>;
  }
  return (
    <a href={url} target="_blank" rel="noreferrer">
      <img
        src={url}
        alt={nom}
        style={{
          width: "100%", height: hauteur, objectFit: "cover",
          borderRadius: 12, border: "1px solid var(--border)",
        }}
      />
    </a>
  );
}

import { useEffect, useId, useRef, useState } from "react";
import { adressesEtrangeres } from "../lib/onDemand";
import { SCORE_FRANCE_SUR, doitChercherEtranger, nomPays } from "../lib/adressesUtil";

// Adresse vérifiée. Une adresse n'est « vérifiée » que si elle a été choisie
// dans la liste : on conserve alors le libellé officiel, le code postal, le
// pays et les coordonnées.
//   • France : Base Adresse Nationale (data.gouv.fr, sans clé), comme avant.
//   • 089 — Hors de France : recherche côté serveur (Geoapify ou
//     OpenRouteService). Elle part toute seule quand la Base Adresse Nationale
//     ne trouve rien de sûr, ou tout de suite si le client choisit
//     « Adresse hors de France ».

export default function VerifiedAddressField({ label, value, onChange, required = false, onSaisie = null }) {
  const [text, setText] = useState(value?.label || "");
  const [items, setItems] = useState([]);
  const [open, setOpen] = useState(false);
  const [status, setStatus] = useState("idle"); // idle | loading | error
  const [active, setActive] = useState(-1);
  const [horsFrance, setHorsFrance] = useState(Boolean(value?.country && value.country !== "FR"));
  const [provider, setProvider] = useState(null);
  const timer = useRef(null);
  const controller = useRef(null);
  const listId = useId();

  useEffect(() => () => {
    clearTimeout(timer.current);
    controller.current?.abort();
  }, []);

  function search(q, forceHorsFrance = horsFrance) {
    clearTimeout(timer.current);
    // 113 : dès 3 lettres (Pau, Gap, Dax…).
    if (q.trim().length < 3) { setItems([]); setOpen(false); return; }
    timer.current = setTimeout(async () => {
      controller.current?.abort();
      controller.current = new AbortController();
      const signal = controller.current.signal;
      setStatus("loading");
      try {
        let france = [];
        if (!forceHorsFrance) {
          const res = await fetch(`https://api-adresse.data.gouv.fr/search/?q=${encodeURIComponent(q)}&limit=6&autocomplete=1`, { signal });
          const data = await res.json();
          france = (data.features || []).map((f) => ({
            label: f.properties.label,
            city: f.properties.city,
            postcode: f.properties.postcode,
            country: "FR",
            lat: f.geometry.coordinates[1],
            lng: f.geometry.coordinates[0],
            kind: f.properties.type,
            score: f.properties.score,
          }));
        }
        let etranger = [];
        let fournisseur = null;
        let panneEtranger = false;
        if (doitChercherEtranger(q, france, forceHorsFrance)) {
          const r = await adressesEtrangeres(q, { signal });
          etranger = r.items;
          fournisseur = r.provider;
          panneEtranger = r.erreur && forceHorsFrance;
        }
        // France d'abord quand elle est sûre ; sinon l'étranger passe devant.
        const surFrance = france.some((i) => Number(i.score) >= SCORE_FRANCE_SUR);
        const tous = surFrance ? [...france, ...etranger] : [...etranger, ...france];
        setItems(tous.slice(0, 8));
        setProvider(etranger.length ? fournisseur : null);
        setOpen(true);
        setActive(-1);
        setStatus(panneEtranger ? "error" : "idle");
      } catch (error) {
        if (error?.name !== "AbortError") setStatus("error");
      }
    }, 300);
  }

  function choose(item) {
    setText(item.label);
    setOpen(false);
    setItems([]);
    const adresse = { ...item, verified: true };
    delete adresse.score;
    onChange(adresse);
  }

  function basculerHorsFrance() {
    const suivant = !horsFrance;
    setHorsFrance(suivant);
    if (text.trim().length >= 3) search(text, suivant);
  }

  const verified = Boolean(value?.verified && value.label === text);
  const pays = nomPays(value?.country);
  return (
    <div className="field ac-field">
      <label htmlFor={`${listId}-input`}><span>{label}{required ? " *" : ""}</span></label>
      <input
        id={`${listId}-input`}
        value={text}
        autoComplete="off"
        role="combobox"
        aria-expanded={open}
        aria-controls={listId}
        aria-invalid={Boolean(text) && !verified}
        placeholder={horsFrance ? "Rue, ville, pays" : "Numéro, rue, ville"}
        onChange={(e) => {
          setText(e.target.value);
          onChange(null);
          onSaisie?.();
          search(e.target.value);
        }}
        onBlur={() => {
          // 113 : ville tapée sans toucher la liste -> la 1re proposition est retenue.
          if (!verified && status !== "loading" && items.length > 0 && text.trim().length >= 3) choose(items[0]);
        }}
        onKeyDown={(e) => {
          if (!open || !items.length) return;
          if (e.key === "ArrowDown") { e.preventDefault(); setActive((a) => Math.min(a + 1, items.length - 1)); }
          if (e.key === "ArrowUp") { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)); }
          if (e.key === "Enter" && active >= 0) { e.preventDefault(); choose(items[active]); }
          if (e.key === "Escape") setOpen(false);
        }}
      />
      {open && items.length > 0 && (
        <ul className="ac-list" id={listId} role="listbox">
          {items.map((item, i) => (
            <li key={`${item.label}-${item.lat}-${i}`} role="option" aria-selected={i === active} className="ac-item" onMouseDown={(e) => { e.preventDefault(); choose(item); }}>
              <span className="ac-main">{item.label}</span>
              {item.kind !== "housenumber" && <span className="ac-sub">Précisez le numéro si possible</span>}
            </li>
          ))}
          {provider === "geoapify" && (
            <li className="ac-sub ac-attribution" aria-hidden="true">
              Adresses hors de France : <a href="https://www.geoapify.com/" target="_blank" rel="noopener noreferrer">Powered by Geoapify</a>
            </li>
          )}
        </ul>
      )}
      {status === "error" && <small className="muted">Recherche d’adresse indisponible (réseau). Réessayez.</small>}
      {text && !verified && status !== "error" && <small className="ac-aide">Touchez une adresse dans la liste pour continuer.</small>}
      {verified && <small className="muted">Adresse vérifiée · {[value.postcode, value.city].filter(Boolean).join(" ")}{pays ? ` · ${pays}` : ""}</small>}
      <button type="button" className="ac-hors-france" onClick={basculerHorsFrance}>
        {horsFrance ? "Revenir aux adresses en France" : "Adresse hors de France ?"}
      </button>
    </div>
  );
}

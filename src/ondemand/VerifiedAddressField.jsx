import { useEffect, useId, useRef, useState } from "react";

// Adresse vérifiée via la Base Adresse Nationale (data.gouv.fr, sans clé).
// Une adresse n'est « vérifiée » que si elle a été choisie dans la liste :
// on conserve alors le libellé officiel, le code postal et les coordonnées.
export default function VerifiedAddressField({ label, value, onChange, required = false }) {
  const [text, setText] = useState(value?.label || "");
  const [items, setItems] = useState([]);
  const [open, setOpen] = useState(false);
  const [status, setStatus] = useState("idle"); // idle | loading | error
  const [active, setActive] = useState(-1);
  const timer = useRef(null);
  const controller = useRef(null);
  const listId = useId();

  useEffect(() => () => {
    clearTimeout(timer.current);
    controller.current?.abort();
  }, []);

  function search(q) {
    clearTimeout(timer.current);
    if (q.trim().length < 4) { setItems([]); setOpen(false); return; }
    timer.current = setTimeout(async () => {
      controller.current?.abort();
      controller.current = new AbortController();
      setStatus("loading");
      try {
        const res = await fetch(`https://api-adresse.data.gouv.fr/search/?q=${encodeURIComponent(q)}&limit=6&autocomplete=1`, { signal: controller.current.signal });
        const data = await res.json();
        setItems((data.features || []).map((f) => ({
          label: f.properties.label,
          city: f.properties.city,
          postcode: f.properties.postcode,
          lat: f.geometry.coordinates[1],
          lng: f.geometry.coordinates[0],
          kind: f.properties.type,
        })));
        setOpen(true);
        setStatus("idle");
      } catch (error) {
        if (error?.name !== "AbortError") setStatus("error");
      }
    }, 250);
  }

  function choose(item) {
    setText(item.label);
    setOpen(false);
    setItems([]);
    onChange({ ...item, verified: true });
  }

  const verified = Boolean(value?.verified && value.label === text);
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
        placeholder="Numéro, rue, ville"
        onChange={(e) => {
          setText(e.target.value);
          onChange(null);
          search(e.target.value);
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
            <li key={`${item.label}-${i}`} role="option" aria-selected={i === active} className="ac-item" onMouseDown={(e) => { e.preventDefault(); choose(item); }}>
              <span className="ac-main">{item.label}</span>
              {item.kind !== "housenumber" && <span className="ac-sub">Précisez le numéro si possible</span>}
            </li>
          ))}
        </ul>
      )}
      {status === "error" && <small className="muted">Recherche d’adresse indisponible (réseau). Réessayez.</small>}
      {text && !verified && status !== "error" && <small className="muted">Choisissez l’adresse dans la liste pour la vérifier.</small>}
      {verified && <small className="muted">Adresse vérifiée · {value.postcode} {value.city}</small>}
    </div>
  );
}

import { useEffect, useRef, useState } from "react";

// Autocompletion d'adresses via la Base Adresse Nationale (data.gouv.fr).
// Gratuit, sans cle API, CORS ouvert. Evite les fautes de ville / adresse.
// kind="city" -> communes ; kind="address" -> adresses completes.

export default function AddressAutocomplete({
  name,
  value,
  setForm,
  label,
  kind = "address",
  placeholder = "",
  required = false,
}) {
  const [suggestions, setSuggestions] = useState([]);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const boxRef = useRef(null);
  const timer = useRef(null);
  const controller = useRef(null);

  useEffect(() => {
    function onDocClick(e) {
      if (boxRef.current && !boxRef.current.contains(e.target)) setOpen(false);
    }
    document.addEventListener("mousedown", onDocClick);
    return () => document.removeEventListener("mousedown", onDocClick);
  }, []);

  function setValue(v) {
    setForm((prev) => ({ ...prev, [name]: v }));
  }

  function query(text) {
    if (timer.current) clearTimeout(timer.current);
    if (!text || text.trim().length < 3) {
      setSuggestions([]);
      setOpen(false);
      return;
    }
    timer.current = setTimeout(async () => {
      try {
        if (controller.current) controller.current.abort();
        controller.current = new AbortController();
        const type = kind === "city" ? "&type=municipality" : "";
        const url = `https://api-adresse.data.gouv.fr/search/?q=${encodeURIComponent(text)}&limit=6&autocomplete=1${type}`;
        const res = await fetch(url, { signal: controller.current.signal });
        const data = await res.json();
        const feats = (data.features || []).map((f) => ({
          label: f.properties.label,
          city: f.properties.city || f.properties.name,
          postcode: f.properties.postcode || "",
          context: f.properties.context || "",
        }));
        setSuggestions(feats);
        setOpen(feats.length > 0);
        setActive(-1);
      } catch {
        /* reseau indisponible : on laisse la saisie libre */
      }
    }, 250);
  }

  function onInput(e) {
    const v = e.target.value;
    setValue(v);
    query(v);
  }

  function choose(s) {
    // Ville -> on ne garde que la commune ; Adresse -> le libelle complet.
    setValue(kind === "city" ? (s.postcode ? `${s.city} (${s.postcode})` : s.city) : s.label);
    setSuggestions([]);
    setOpen(false);
  }

  function onKeyDown(e) {
    if (!open || suggestions.length === 0) return;
    if (e.key === "ArrowDown") { e.preventDefault(); setActive((a) => Math.min(a + 1, suggestions.length - 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)); }
    else if (e.key === "Enter" && active >= 0) { e.preventDefault(); choose(suggestions[active]); }
    else if (e.key === "Escape") setOpen(false);
  }

  return (
    <label className="field ac-field" ref={boxRef}>
      <span>{label}{required ? " *" : ""}</span>
      <input
        type="text"
        name={name}
        value={value ?? ""}
        placeholder={placeholder}
        onChange={onInput}
        onKeyDown={onKeyDown}
        onFocus={() => suggestions.length && setOpen(true)}
        autoComplete="off"
        aria-label={label}
        aria-autocomplete="list"
        aria-expanded={open}
      />
      {open && (
        <ul className="ac-list" role="listbox">
          {suggestions.map((s, i) => (
            <li
              key={s.label + i}
              role="option"
              aria-selected={i === active}
              className={`ac-item ${i === active ? "active" : ""}`}
              onMouseDown={(e) => { e.preventDefault(); choose(s); }}
              onMouseEnter={() => setActive(i)}
            >
              <span className="ac-main">{kind === "city" ? s.city : s.label}</span>
              <span className="ac-sub">{kind === "city" ? s.postcode : s.context}</span>
            </li>
          ))}
        </ul>
      )}
    </label>
  );
}

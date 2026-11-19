import { bonnetNoel } from "../lib/promoNoel";

// SECOTO 153 — « SECOTO » ; jusqu'au 31/12, bonnet de Père Noël sur le dernier O.
export default function MarqueSecoto() {
  if (!bonnetNoel()) return <strong>SECOTO</strong>;
  return (
    <strong className="marque-noel" aria-label="SECOTO">
      SECOT<span className="marque-noel-o">O
        <svg className="marque-noel-bonnet" viewBox="0 0 120 90" aria-hidden="true">
          <path d="M14 66 C26 30 52 10 84 14 C100 16 108 30 104 52 C100 40 92 34 84 36 C70 40 66 56 70 66 Z" fill="#d7262e" />
          <path d="M84 14 C100 16 108 30 104 52 C100 40 92 34 84 36 Z" fill="#a8121b" opacity=".55" />
          <rect x="6" y="60" width="74" height="17" rx="8.5" fill="#fff" />
          <circle cx="104" cy="56" r="10" fill="#fff" />
        </svg>
      </span>
    </strong>
  );
}

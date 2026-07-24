import { useEffect, useRef, useState } from "react";

// ============================================================================
// SECOTO — Signature manuscrite (doigt sur mobile, souris sur ordinateur).
// Rend une image PNG (data URL) transmise telle quelle a la base, avec le nom
// du signataire et l'horodatage cote serveur.
// ============================================================================

export default function SignaturePad({
  defaultName = "",
  label = "Signer le document",
  busy = false,
  onCancel,
  onSign,
}) {
  const canvasRef = useRef(null);
  const drawingRef = useRef(false);
  const lastRef = useRef(null);
  const emptyRef = useRef(true);

  const [name, setName] = useState(defaultName);
  const [hasDrawn, setHasDrawn] = useState(false);
  const [error, setError] = useState("");

  // Le canvas doit être dimensionné en pixels réels (densité de l'écran),
  // sinon le trait est flou et décalé sur mobile.
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return undefined;

    function resize() {
      const ratio = window.devicePixelRatio || 1;
      const rect = canvas.getBoundingClientRect();
      if (!rect.width) return;
      canvas.width = Math.round(rect.width * ratio);
      canvas.height = Math.round(rect.height * ratio);
      const ctx = canvas.getContext("2d");
      ctx.scale(ratio, ratio);
      ctx.lineWidth = 2.2;
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.strokeStyle = "#0f172a";
      ctx.fillStyle = "#ffffff";
      ctx.fillRect(0, 0, rect.width, rect.height);
    }

    resize();
    window.addEventListener("resize", resize);
    return () => window.removeEventListener("resize", resize);
  }, []);

  function pointFrom(e) {
    const rect = canvasRef.current.getBoundingClientRect();
    const src = e.touches?.[0] || e.changedTouches?.[0] || e;
    return { x: src.clientX - rect.left, y: src.clientY - rect.top };
  }

  function start(e) {
    e.preventDefault();
    drawingRef.current = true;
    lastRef.current = pointFrom(e);
  }

  function move(e) {
    if (!drawingRef.current) return;
    e.preventDefault();
    const ctx = canvasRef.current.getContext("2d");
    const p = pointFrom(e);
    ctx.beginPath();
    ctx.moveTo(lastRef.current.x, lastRef.current.y);
    ctx.lineTo(p.x, p.y);
    ctx.stroke();
    lastRef.current = p;
    if (emptyRef.current) { emptyRef.current = false; setHasDrawn(true); }
  }

  function end(e) {
    if (!drawingRef.current) return;
    e.preventDefault();
    drawingRef.current = false;
  }

  function clear() {
    const canvas = canvasRef.current;
    const ctx = canvas.getContext("2d");
    const rect = canvas.getBoundingClientRect();
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, rect.width, rect.height);
    emptyRef.current = true;
    setHasDrawn(false);
  }

  function submit() {
    setError("");
    if (!name.trim()) { setError("Indiquez le nom du signataire."); return; }
    if (!hasDrawn) { setError("Tracez votre signature dans le cadre."); return; }
    onSign({
      data_url: canvasRef.current.toDataURL("image/png"),
      signer_name: name.trim(),
    });
  }

  return (
    <div className="sign-pad">
      <label className="field">
        <span>Nom du signataire *</span>
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Prénom NOM" />
      </label>

      <span className="muted" style={{ fontSize: "0.82rem" }}>
        Tracez votre signature ci-dessous (au doigt sur mobile).
      </span>

      <canvas
        ref={canvasRef}
        className="sign-canvas"
        onMouseDown={start}
        onMouseMove={move}
        onMouseUp={end}
        onMouseLeave={end}
        onTouchStart={start}
        onTouchMove={move}
        onTouchEnd={end}
      />

      {error && <div className="alert error">{error}</div>}

      <div className="actions-row" style={{ flexWrap: "wrap" }}>
        <button type="button" className="btn ghost small" onClick={clear} disabled={busy}>Effacer</button>
        {onCancel && <button type="button" className="btn ghost small" onClick={onCancel} disabled={busy}>Annuler</button>}
        <button type="button" className="btn primary small" onClick={submit} disabled={busy}>
          {busy ? "Signature en cours…" : label}
        </button>
      </div>
    </div>
  );
}

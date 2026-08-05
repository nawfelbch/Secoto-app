export default function NotificationConsentGate({ busy, onEnable, onDecline }) {
  return (
    <div className="permission-gate" role="dialog" aria-modal="true" aria-labelledby="push-consent-title">
      <div className="permission-gate-card">
        <div className="permission-gate-icon" aria-hidden="true">
          <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" />
            <path d="M13.73 21a2 2 0 0 1-3.46 0" />
          </svg>
        </div>
        <p className="eyebrow">SECOTO</p>
        <h2 id="push-consent-title">Ne ratez aucune nouvelle course</h2>
        <p>
          SECOTO utilise les notifications uniquement pour vous prévenir lorsqu'une nouvelle mission
          est disponible ou lorsqu'une action importante concerne l'une de vos missions.
        </p>
        <p className="muted">Aucune publicité et aucune notification inutile.</p>
        <div className="permission-gate-actions">
          <button className="btn primary" type="button" disabled={busy} onClick={onEnable}>
            {busy ? "Activation…" : "Activer les notifications"}
          </button>
          <button className="btn ghost" type="button" disabled={busy} onClick={onDecline}>
            Continuer sans notifications
          </button>
        </div>
      </div>
    </div>
  );
}
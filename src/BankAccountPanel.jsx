import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabaseClient";

function firstRow(data) {
  if (Array.isArray(data)) return data[0] || null;
  return data || null;
}

function bankHint(row) {
  return row?.iban_hint
    || row?.masked_iban
    || row?.iban_masked
    || row?.iban_last4
    || null;
}

export default function BankAccountPanel({ account }) {
  const [bankAccount, setBankAccount] = useState(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [form, setForm] = useState({
    holderName: account.companyName || account.fullName || "",
    siren: "",
    iban: "",
    bic: "",
  });

  const loadBankAccount = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      // Lecture exclusivement via la fonction SECURITY DEFINER : aucun SELECT
      // direct sur partner_bank_accounts n'est autorisé ni tenté par le front.
      const { data, error: rpcError } = await supabase.rpc(
        "secoto_my_bank_account",
      );
      if (rpcError) throw rpcError;
      const current = firstRow(data);
      setBankAccount(current);
      setForm((previous) => ({
        ...previous,
        holderName: current?.holder_name
          || account.companyName
          || account.fullName
          || previous.holderName,
        siren: current?.siren || previous.siren,
        bic: current?.bic || previous.bic,
        iban: "",
      }));
    } catch (loadError) {
      setError(loadError.message || "Coordonnées bancaires indisponibles.");
    } finally {
      setLoading(false);
    }
  }, [account.companyName, account.fullName]);

  useEffect(() => {
    const timer = setTimeout(() => {
      loadBankAccount();
    }, 0);
    return () => clearTimeout(timer);
  }, [loadBankAccount]);

  function update(event) {
    const { name, value } = event.target;
    setForm((previous) => ({ ...previous, [name]: value }));
  }

  async function save(event) {
    event.preventDefault();
    setError("");
    setNotice("");

    const holderName = form.holderName.trim();
    const siren = form.siren.replace(/\D/g, "");
    const iban = form.iban.replace(/\s/g, "").toUpperCase();
    const bic = form.bic.replace(/\s/g, "").toUpperCase();

    if (!holderName) {
      setError("Renseignez le titulaire du compte.");
      return;
    }
    if (!/^\d{9}$/.test(siren)) {
      setError("Le SIREN doit contenir exactement 9 chiffres.");
      return;
    }
    if (!/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/.test(iban)) {
      setError("L’IBAN saisi est invalide.");
      return;
    }
    if (bic && !/^[A-Z0-9]{8}([A-Z0-9]{3})?$/.test(bic)) {
      setError("Le BIC doit contenir 8 ou 11 caractères.");
      return;
    }

    setSaving(true);
    try {
      const { error: rpcError } = await supabase.rpc(
        "secoto_set_bank_account",
        {
          p_holder_name: holderName,
          p_siren: siren,
          p_iban: iban,
          p_bic: bic || null,
        },
      );
      if (rpcError) throw rpcError;
      setNotice("Coordonnées bancaires enregistrées.");
      setForm((previous) => ({ ...previous, iban: "" }));
      await loadBankAccount();
    } catch (saveError) {
      setError(saveError.message || "Enregistrement bancaire impossible.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="panel panel-full bank-panel">
      <h2>Coordonnées bancaires</h2>
      <p className="muted">
        Elles servent uniquement aux virements des missions de convoyage payées
        par SECOTO. L’IBAN est chiffré côté serveur et seule sa version masquée
        reste visible dans l’application.
      </p>

      {loading && <div className="alert">Chargement…</div>}
      {error && <div className="alert error">{error}</div>}
      {notice && <div className="alert success">{notice}</div>}

      {!loading && bankAccount && (
        <div className="bank-account-summary">
          <span className="status status-validated">Compte enregistré</span>
          <p><strong>IBAN :</strong> {bankHint(bankAccount) || "Masqué"}</p>
          <p><strong>Titulaire :</strong> {bankAccount.holder_name || form.holderName}</p>
          <p><strong>SIREN :</strong> {bankAccount.siren || form.siren}</p>
          {bankAccount.bic && <p><strong>BIC :</strong> {bankAccount.bic}</p>}
        </div>
      )}

      {!loading && (
        <form className="form-grid bank-account-form" onSubmit={save}>
          <label className="field">
            <span>Titulaire du compte *</span>
            <input
              name="holderName"
              value={form.holderName}
              onChange={update}
              autoComplete="name"
              required
            />
          </label>
          <label className="field">
            <span>SIREN *</span>
            <input
              name="siren"
              value={form.siren}
              onChange={update}
              inputMode="numeric"
              placeholder="9 chiffres"
              required
            />
          </label>
          <label className="field field-full">
            <span>{bankAccount ? "Nouvel IBAN *" : "IBAN *"}</span>
            <input
              name="iban"
              value={form.iban}
              onChange={update}
              autoCapitalize="characters"
              autoComplete="off"
              spellCheck="false"
              placeholder="FR76 …"
              required
            />
          </label>
          <label className="field">
            <span>BIC (facultatif)</span>
            <input
              name="bic"
              value={form.bic}
              onChange={update}
              autoCapitalize="characters"
              autoComplete="off"
              spellCheck="false"
              placeholder="Ex. ABCDFRPP"
            />
          </label>
          <button className="btn primary field-full" type="submit" disabled={saving}>
            {saving ? "Enregistrement…" : bankAccount ? "Mettre à jour" : "Enregistrer"}
          </button>
        </form>
      )}
    </div>
  );
}

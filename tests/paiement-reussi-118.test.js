// SECOTO 118 — après des prélèvements refusés, le paiement réussi devient la référence
// (sinon le virement au transporteur part d'une charge refusée et échoue).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202610250118_paiement_reussi_reference.sql", import.meta.url), "utf8");

test("un paiement réussi remplace l'identifiant d'un essai précédent", () => {
  assert.match(sql, /secoto_od_apply_payment_event/);
  assert.match(sql, /case when v_new = ''paid'' and p_intent_id is not null then p_intent_id else coalesce\(provider_intent_id, p_intent_id\) end/);
});

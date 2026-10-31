import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202610310125_email_transporteur_confirme.sql", import.meta.url), "utf8");

test("125 : e-mail au client au passage en « transporteur confirmé », une seule fois par commande", () => {
  assert.match(sql, /after update of status on public\.transport_orders/);
  assert.match(sql, /new\.status <> 'partner_confirmed' or old\.status = 'partner_confirmed' or coalesce\(new\.is_test, false\)/);
  assert.match(sql, /'od-transporteur-confirme:' \|\| new\.id::text/);
  assert.match(sql, /on conflict \(event_key\) do nothing/);
});

test("125 : l'e-mail ne bloque jamais la confirmation et reste signé L'Équipe SECOTO", () => {
  assert.match(sql, /exception when others then\s+--[^\n]*\n\s+return new;/);
  assert.match(sql, /'L''Équipe SECOTO'/);
  assert.match(sql, /validé par SECOTO/);
  assert.doesNotMatch(sql, /garanti|assuré/i);
});

test("125 : contenu — transporteur, téléphone, montant et mode de règlement", () => {
  for (const motif of ["carrier_contact_json", "Votre transporteur : ", "Téléphone : ", "reglement_eur(p_order.client_price_cents)", "'klarna'", "'virement'", "'especes'"]) {
    assert.ok(sql.includes(motif), motif);
  }
});

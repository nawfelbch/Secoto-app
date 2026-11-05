import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202611050128_emails_client_chaque_etape.sql", import.meta.url), "utf8");

test("128 : un e-mail client à chaque étape de la commande", () => {
  for (const etape of ["searching_partner", "picked_up", "delivered", "no_partner", "cancelled"]) {
    assert.ok(sql.includes(`p_etape = '${etape}'`), etape);
  }
  assert.match(sql, /'od-etape:' \|\| new\.status \|\| ':' \|\| new\.id::text/);
  assert.match(sql, /on conflict \(event_key\) do nothing/);
});

test("128 : « demande reçue » seulement à la réservation, jamais les commandes de test", () => {
  assert.match(sql, /new\.status = 'searching_partner' and old\.status <> 'awaiting_payment' then return new/);
  assert.match(sql, /coalesce\(new\.is_test, false\)/);
});

test("128 : nouveau transporteur après un désistement = nouvel e-mail de confirmation", () => {
  assert.match(sql, /'od-transporteur-confirme:' \|\| new\.id::text \|\| ':' \|\| coalesce\(new\.assigned_partner_id::text, ''\)/);
  assert.match(sql, /Il remplace celui annoncé dans notre précédent e-mail/);
});

test("128 : l'e-mail ne bloque jamais le statut et reste honnête sur le règlement", () => {
  assert.equal((sql.match(/exception when others then/g) || []).length, 2);
  assert.match(sql, /'L''Équipe SECOTO'/);
  assert.doesNotMatch(sql, /garanti|assuré/i);
});

const sql129 = readFileSync(new URL("../supabase/migrations/202611050129_avis_10_minutes_apres_livraison.sql", import.meta.url), "utf8");

test("129 : demande d'avis 10 minutes après la livraison", () => {
  assert.match(sql129, /trg_mission_review_request\(\)'::regprocedure/);
  assert.match(sql129, /now\(\) \+ interval ''10 minutes'' \/\* 129 \*\//);
  assert.match(sql129, /least\(due_at, created_at \+ interval '10 minutes'\)/);
});

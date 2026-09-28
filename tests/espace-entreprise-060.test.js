// ============================================================================
// SECOTO 060 — espace entreprise de transport. Les quatre regles du 28/09/2026
// doivent etre portees par la base, pas par les ecrans.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(
  new URL("../supabase/migrations/202609280060_espace_entreprise_transport.sql", import.meta.url),
  "utf8",
);

test("regle 1 — le versement ne peut aller qu'a l'entreprise", () => {
  // Un declencheur, pas une convention d'ecran : aucun chemin d'attribution
  // ne peut le contourner.
  assert.match(SQL, /create trigger trg_secoto_carrier_payee\s+before insert or update of assigned_transporter_id on public\.missions/);
  assert.match(SQL, /new\.assigned_transporter_id := v_payout;/);
});

test("regle 2 — seul un gerant accepte une mission", () => {
  assert.match(SQL, /if v_role <> 'owner' then/);
  assert.match(SQL, /Seul un gerant peut accepter une mission pour son entreprise\./);
  // Un employe ne peut que suggerer.
  assert.match(SQL, /create or replace function public\.secoto_carrier_suggest\(/);
});

test("regle 3 — un employe ne voit aucun montant", () => {
  const vue = SQL.slice(SQL.indexOf("create or replace view public.secoto_missions_transporter_v2"));
  for (const colonne of ["carrier_cost", "carrier_pay"]) {
    const re = new RegExp(
      `case when m\\.assigned_transporter_id = auth\\.uid\\(\\)[\\s\\S]{0,200}?then m\\.${colonne} end as ${colonne}`,
    );
    assert.match(vue, re, `${colonne} doit etre masquee a l'employe`);
  }
  // Le tableau de l'employe ne renvoie ni prix client ni remuneration.
  const employe = SQL.slice(SQL.indexOf("-- Employe : sa societe"), SQL.indexOf("return jsonb_build_object(\n    'company', jsonb_build_object(\n      'id', v_b.id, 'name', v_b.name, 'siren'"));
  assert.doesNotMatch(employe, /carrier_pay|client_price|carrier_cost/);
});

test("regle 4 — plusieurs gerants, et jamais zero", () => {
  assert.match(SQL, /create or replace function public\.secoto_carrier_set_role\(/);
  assert.match(SQL, /L''entreprise doit garder au moins un gerant\./);
});

test("un convoyeur qui part ne laisse pas de mission en cours", () => {
  assert.match(SQL, /mission\(s\) en cours : reaffectez-les/);
});

test("le compte de versement ne peut pas etre retire de l'entreprise", () => {
  assert.match(SQL, /Designez d''abord un autre compte de versement\./);
});

test("les entreprises clientes et transporteurs restent separees", () => {
  assert.match(SQL, /check \(kind in \('client', 'transporteur'\)\)/);
  assert.match(SQL, /b\.kind = 'transporteur'/);
});

test("les fonctions sont fermees a anon", () => {
  assert.match(SQL, /revoke all on function %s from public, anon/);
  assert.match(SQL, /grant execute on function %s to authenticated/);
  assert.match(SQL, /revoke all on table public\.secoto_missions_transporter_v2 from public, anon;/);
});

test("la migration se controle elle-meme", () => {
  assert.match(SQL, /Le declencheur qui protege les versements n''est pas pose/);
  assert.match(SQL, /La vue transporteur est lisible par anon/);
});

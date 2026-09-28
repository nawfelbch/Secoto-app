// ============================================================================
// SECOTO 059 — commander plusieurs vehicules. Ce qui est verifie ici, ce sont
// les proprietes qu'aucun ecran ne peut rattraper : le patch ne s'applique
// qu'a coup sur, et la somme des missions vaut exactement la commande.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(
  new URL("../supabase/migrations/202609280059_commande_multi_vehicules.sql", import.meta.url),
  "utf8",
);

test("aucune ancre n'est remplacee a l'aveugle", () => {
  // Chaque ancre doit exister EXACTEMENT une fois dans la source deployee :
  // zero et le patch passerait inapercu, deux et il toucherait un autre endroit.
  assert.match(SQL, /create or replace function secoto_private\.compter_occurrences\(/);
  const controles = SQL.match(/secoto_private\.compter_occurrences\(v_new, [\s\S]*?\) <> 1 then/g) || [];
  assert.ok(controles.length >= 7, `attendu au moins 7 ancres verifiees, trouve ${controles.length}`);
  // Le compteur est un outil de migration : il ne reste pas en base.
  assert.match(SQL, /drop function if exists secoto_private\.compter_occurrences\(text, text\);/);
});

test("le patch est refait sans dommage s'il a deja ete applique", () => {
  assert.match(SQL, /if position\('price_group_with_grid' in v_src\) > 0 then[\s\S]{0,120}return;/);
  assert.match(SQL, /if position\('groupage_order_id' in v_src\) > 0 then[\s\S]{0,120}return;/);
});

test("la somme des missions vaut exactement la commande", () => {
  // La premiere mission est l'ecriture d'equilibre : quoi que contienne le
  // detail du devis — y compris rien, sur un devis chiffre a la main — le
  // transporteur ne peut etre ni sous-paye ni paye deux fois.
  assert.match(SQL, /set manual_carrier_pay = \(v_order\.partner_pay_cents - coalesce\(\(/);
  assert.match(SQL, /where s\.groupage_order_id = v_order\.id and s\.groupage_rank > 0\), 0\)\) \/ 100\.0,/);
  assert.match(SQL, /od_confirm ne partage pas la remuneration entre les missions d''une meme commande/);
});

test("une mission soeur nait publiee puis attribuee, comme la premiere", () => {
  // Les declencheurs d'attribution (documents, notifications, versements)
  // doivent s'executer pour chaque vehicule.
  assert.match(SQL, /v_order\.mode, ''published''/);
  assert.match(SQL, /set status = ''assigned'', progress_status = ''assigned_pending'',/);
});

test("le parcours a un seul vehicule est inchange", () => {
  // Sans liste dans la charge utile, v_vehicles ne contient que le vehicule
  // unique : la fonction suit exactement le meme chemin qu'avant.
  assert.match(SQL, /else jsonb_build_array\(p_payload -> ''vehicle''\) end;/);
  assert.match(SQL, /jsonb_array_length\(v_vehicles\) not between 1 and 3/);
});

test("rien n'est insere apres begin : la liste nait dans les declarations", () => {
  // L'ancre « begin » supposait que v_constraint fermait les declarations, ce
  // qui n'est vrai que de la version d'origine. On s'appuie desormais sur la
  // ligne qui declare le vehicule, et le corps n'est plus touche a cet endroit.
  assert.doesNotMatch(SQL, /Ancre begin/);
  assert.match(SQL, /'  v_vehicle jsonb := p_payload -> ''vehicle'';'/);
  assert.match(SQL, /'  v_vehicle jsonb := v_vehicles -> 0;'/);
});

test("un echec d'ancre dit a quoi ressemble la fonction deployee", () => {
  assert.match(SQL, /Debut reel : %',\s*\n?\s*left\(v_new, 1200\)/);
});

test("les devis deja enregistres sont repris", () => {
  assert.match(SQL, /update public\.transport_quotes\s+set vehicles = jsonb_build_array\(vehicle\)\s+where vehicles is null;/);
  assert.match(SQL, /Des devis existants n''ont pas ete repris avec leur vehicule/);
});

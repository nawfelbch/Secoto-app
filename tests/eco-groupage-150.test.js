import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202611170150_eco_sur_groupage.sql", import.meta.url), "utf8");

// Copie JS de eco_meme_axe : même couloir, même sens, trajets qui se chevauchent.
const COULOIRS = [["Paris", "Lyon", "Marseille", "Nice"], ["Paris", "Lyon", "Montpellier", "Toulouse"], ["Paris", "Bordeaux", "Toulouse"]];
function memeAxe(d, a, d2, a2) {
  return COULOIRS.some((c) => {
    const [i, j, k, l] = [d, a, d2, a2].map((v) => c.indexOf(v));
    if ([i, j, k, l].some((x) => x < 0) || i === j || k === l) return false;
    return Math.sign(j - i) === Math.sign(l - k) && Math.max(Math.min(i, j), Math.min(k, l)) < Math.min(Math.max(i, j), Math.max(k, l));
  });
}

test("150 : même axe = même couloir, même sens, trajets qui se chevauchent (vérifié en production)", () => {
  assert.equal(memeAxe("Paris", "Lyon", "Paris", "Marseille"), true);
  assert.equal(memeAxe("Paris", "Marseille", "Lyon", "Marseille"), true);
  assert.equal(memeAxe("Lyon", "Paris", "Paris", "Lyon"), false);
  assert.equal(memeAxe("Paris", "Lyon", "Lyon", "Marseille"), false);
  assert.equal(memeAxe("Paris", "Bordeaux", "Paris", "Lyon"), false);
});

test("150 : Éco seulement en groupage (plusieurs véhicules, ou 2 commandes sur l'axe à ± 3 jours), jamais pour un pro", () => {
  assert.match(sql, /'debloquer_apres', 2/);
  assert.match(sql, /'ecart_jours', 3/);
  assert.match(sql, /if v_navette is null and not v_pro and secoto_private\.flag\('bareme_v3'\) and secoto_private\.eco_debloquee\(q\)/);
  assert.match(sql, /if jsonb_array_length\(coalesce\(q\.vehicles, '\[\]'::jsonb\)\) > 1 then return true; end if;/);
  assert.match(sql, /'sur_groupage'/);
  // Barèmes Éco inchangés : on réutilise offre_eco_v3 telle quelle.
  assert.doesNotMatch(sql, /create or replace function secoto_private\.offre_eco_v3/);
});

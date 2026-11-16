import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const lire = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

test("Médiateur de la consommation : CM2C affiché dans les CGU et les informations légales", () => {
  for (const f of ["public/cgu.html", "src/LegalNoticesPanel.jsx"]) {
    const t = lire(f);
    assert.match(t, /CM2C/, f);
    assert.match(t, /49 rue de Ponthieu, 75008 Paris, tél\. 01 89 47 00 14/, f);
    assert.match(t, /www\.cm2c\.net/, f);
    assert.match(t, /L\.612-1/, f);
  }
  assert.doesNotMatch(lire("public/cgu.html"), /communiquées sur simple demande/);
});

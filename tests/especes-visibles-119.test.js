// SECOTO 119 — course réglée en espèces : le transporteur voit le total à
// encaisser en grand, puis sa part et la part SECOTO.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { detailEspeces, eurosEnCentimes } from "../src/lib/especes.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const sql = lire("supabase/migrations/202610280119_especes_visibles_transporteur.sql");
const app = lire("src/App.jsx");
const offres = lire("src/ondemand/PartnerOffers.jsx");
const bloc = lire("src/ondemand/EspecesAEncaisser.jsx");

test("119 : total, part transporteur et part SECOTO (incident Lux → Ambérieu)", () => {
  assert.deepEqual(detailEspeces(15084, 12570), { total: 15084, partTransporteur: 12570, partSecoto: 2514 });
  assert.equal(eurosEnCentimes("150.84"), 15084);
  assert.equal(eurosEnCentimes(125.7), 12570);
  assert.equal(eurosEnCentimes(null), null);
});

test("119 : chauffeur d'une entreprise (part inconnue) → total seul ; montant inconnu → aucun calcul", () => {
  assert.deepEqual(detailEspeces(15084, null), { total: 15084, partTransporteur: null, partSecoto: null });
  assert.equal(detailEspeces(null, 12570).total, null);
  // Jamais de part SECOTO négative.
  assert.equal(detailEspeces(10000, 12000).partSecoto, 0);
});

test("119 : la vue transporteur expose le total seulement en espèces, sans toucher au reste", () => {
  assert.match(sql, /secoto_missions_transporter_v2/);
  assert.match(sql, /= ''especes''/);
  assert.match(sql, /AS especes_a_encaisser FROM public\.missions m/);
  assert.match(sql, /security_barrier = true, security_invoker = false/);
  assert.match(sql, /raise exception 'Vue secoto_missions_transporter_v2 : structure inattendue/);
  // Le prix client ne rejoint jamais la liste des colonnes transporteur.
  const colonnes = app.slice(app.indexOf("const MISSION_TRANSPORTER_COLUMNS = ["), app.indexOf('].join(",");', app.indexOf("const MISSION_TRANSPORTER_COLUMNS = [")));
  assert.doesNotMatch(colonnes, /"client_total_due"|"client_price"|"margin"/);
});

test("119 : l'app relit sans la colonne si la migration n'est pas encore passée", () => {
  assert.match(app, /MISSION_TRANSPORTER_COLUMNS_119 = `\$\{MISSION_TRANSPORTER_COLUMNS\},especes_a_encaisser`/);
  assert.match(app, /\/especes_a_encaisser\/\.test\(r\.error\.message/);
  assert.equal((app.match(/sansColonne119\(/g) || []).length, 2); // liste + mission seule (file hors ligne)
});

test("119 : affichage côté transporteur (mission, offre, liste)", () => {
  assert.match(app, /visiblePricing === "transporter" && mission\.paymentMethod === "especes"/);
  assert.match(app, /💶 Espèces/);
  assert.match(offres, /<EspecesAEncaisser totalCents=\{offer\.especes_a_encaisser_cents\}/);
  assert.match(offres, /À encaisser en espèces/);
  assert.match(bloc, /À encaisser auprès du client/);
  assert.match(bloc, /Votre part/);
  assert.match(bloc, /Part SECOTO à reverser/);
});

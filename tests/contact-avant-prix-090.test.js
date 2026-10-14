import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { aideContact, contactValide, emailPropre, telephoneLisible, telephonePropre } from "../src/lib/contactDevis.js";
import { enregistrerContact } from "../netlify/functions/quote-public.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");

test("téléphone : formats français et étrangers, même règle que la base", () => {
  assert.equal(telephonePropre("06 12 34 56 78"), "+33612345678");
  assert.equal(telephonePropre("06.12.34.56.78"), "+33612345678");
  assert.equal(telephonePropre("+33 6 12 34 56 78"), "+33612345678");
  assert.equal(telephonePropre("0033612345678"), "+33612345678");
  assert.equal(telephonePropre("+49 151 2345678"), "+491512345678");
  assert.equal(telephonePropre("06 12 34 56 7"), null);
  assert.equal(telephonePropre("00 00"), null);
  assert.equal(telephoneLisible("+33612345678"), "06 12 34 56 78");
  assert.equal(telephoneLisible("+491512345678"), "+491512345678");
});

test("contact : au moins un des deux, aide seulement après saisie", () => {
  assert.equal(contactValide({ phone: "", email: "" }), null);
  assert.deepEqual(contactValide({ phone: "0612345678", email: "" }), { phone: "+33612345678", email: null });
  assert.deepEqual(contactValide({ phone: "abc", email: "Jean@Exemple.fr" }), { phone: null, email: "jean@exemple.fr" });
  assert.equal(emailPropre("jean@"), null);
  assert.equal(aideContact({ phone: "" }, "telephone"), "", "pas d'erreur avant la saisie");
  assert.match(aideContact({ phone: "06" }, "telephone"), /Vérifiez le numéro/);
  assert.equal(aideContact({ email: "a@b.fr" }, "email"), "");
});

test("serveur : le contact part à la base, jamais bloquant pour le prix", async () => {
  const appels = [];
  const admin = { rpc: async (nom, args) => { appels.push({ nom, args }); return { error: null }; } };
  assert.equal(await enregistrerContact(admin, "q1", { phone: "0612345678" }), true);
  assert.deepEqual(appels[0], { nom: "secoto_devis_contact", args: { p_quote_id: "q1", p_phone: "0612345678", p_email: null } });
  assert.equal(await enregistrerContact(admin, "q1", null), false, "ancienne app : rien à enregistrer");
  assert.equal(await enregistrerContact(admin, null, { phone: "06" }), false);
  const enPanne = { rpc: async () => { throw new Error("réseau"); } };
  assert.equal(await enregistrerContact(enPanne, "q1", { email: "a@b.fr" }), false);
});

test("parcours : contact obligatoire avant le prix, sans compte, téléphone d'abord", () => {
  const b = lire("src/ondemand/OnDemandBooking.jsx");
  assert.match(b, /if \(anonyme && !leContact\) throw new Error/);
  assert.match(b, /publicQuote\(payload, leContact\)/);
  assert.match(b, /!contactValide\(contact\)\}/);
  assert.match(b, /Voir mon prix/);
  const c = lire("src/ondemand/ContactAvantPrix.jsx");
  assert.match(c, /type="tel"/);
  assert.match(c, /autoComplete="tel"/);
  assert.match(c, /Je préfère laisser mon e-mail/);
  assert.match(c, /Votre prix s’affiche immédiatement/);
  assert.match(lire("public/politique-confidentialite.html"), /id="contact-devis"/);
  const m = lire("supabase/migrations/202610140090_contact_avant_prix.sql");
  assert.doesNotMatch(m, /\b(drop table|drop column|alter column|drop policy|truncate|delete from)\b/i);
  assert.match(m, /grant execute on function public\.secoto_devis_contact\(uuid, text, text\) to service_role/);
});

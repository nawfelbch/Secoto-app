import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — un gérant fait créer le compte d'un de ses chauffeurs.
// ----------------------------------------------------------------------------
// Créer un compte d'authentification exige la clé de service : c'est la seule
// raison d'être de cette fonction. Tout le reste — qui a le droit, à quelle
// entreprise rattacher — reste décidé en base.
//
// Le mot de passe renvoyé est provisoire et affiché une seule fois au gérant.
// Le compte porte « must_change_password » : tant que le chauffeur ne l'a pas
// remplacé, l'application ne lui montre que cet écran. Un mot de passe connu
// d'un tiers ne doit jamais rester actif.
import { randomBytes } from "node:crypto";
import { authenticatedUserId, bearer, json, parseBody, serviceClient, userClient, withCors } from "../lib/secoto-server.js";

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

// Lisible au téléphone et sans ambiguïté : ni O/0, ni I/l/1.
const ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

export function motDePasseProvisoire(octets = randomBytes(12)) {
  let sortie = "";
  for (const o of octets) sortie += ALPHABET[o % ALPHABET.length];
  return `${sortie.slice(0, 4)}-${sortie.slice(4, 8)}-${sortie.slice(8, 12)}`;
}

const handler = async (event) => {
  if (event.httpMethod === "OPTIONS") return json(200, {});
  if (event.httpMethod !== "POST") return json(405, { error: "method_not_allowed" });

  const token = bearer(event);
  const ownerId = token ? await authenticatedUserId(token) : null;
  if (!ownerId) return json(401, { error: "unauthenticated" });

  const body = parseBody(event) || {};

  // Retrait d'un chauffeur. Les règles restent en base : le serveur n'est là
  // que pour supprimer, le cas échéant, un compte que la base déclare
  // supprimable — créé par l'entreprise et jamais ouvert par son titulaire.
  if (body.action === "remove") {
    const accountId = String(body.account_id || "");
    if (!accountId) return json(400, { error: "compte_manquant" });

    const asOwnerR = userClient(token);
    const { data: retrait, error: retraitErr } =
      await asOwnerR.rpc("secoto_carrier_remove_member", { p_account_id: accountId });
    if (retraitErr) return json(400, { error: "retrait_refuse", detail: retraitErr.message });

    if (!retrait?.compte_supprimable) return json(200, { removed: true, compte_supprime: false });

    // Dernière vérification côté authentification : un compte déjà ouvert une
    // fois appartient à son titulaire, il n'est jamais supprimé.
    const adminR = serviceClient();
    const { data: u } = await adminR.auth.admin.getUserById(accountId).catch(() => ({ data: null }));
    if (u?.user?.last_sign_in_at) return json(200, { removed: true, compte_supprime: false });

    const { error: delErr } = await adminR.auth.admin.deleteUser(accountId);
    return json(200, { removed: true, compte_supprime: !delErr });
  }

  const email = String(body.email || "").trim().toLowerCase();
  const nom = String(body.full_name || "").trim().slice(0, 160);
  const telephone = String(body.phone || "").trim().slice(0, 40);

  if (!EMAIL.test(email)) return json(400, { error: "email_invalide" });
  if (nom.length < 2) return json(400, { error: "nom_invalide" });

  // 1. Le demandeur est-il gérant ? La base répond, pas le serveur.
  const asOwner = userClient(token);
  const { data: vue, error: vueErr } = await asOwner.rpc("secoto_carrier_overview", {});
  if (vueErr) return json(500, { error: "overview_indisponible" });
  if (vue?.company?.role !== "owner") return json(403, { error: "reserve_aux_gerants" });

  const admin = serviceClient();

  // 2. Un compte existe déjà avec cet e-mail : on ne touche à rien. Le gérant
  //    lui enverra une invitation — c'est le chemin prévu pour ce cas.
  const { data: existant } = await admin
    .from("accounts").select("id").eq("email", email).maybeSingle();
  if (existant?.id) return json(200, { existe: true, email });

  // 3. Le compte est créé exactement comme une inscription : le déclencheur
  //    handle_new_user construit la fiche à partir de ces métadonnées.
  const { data: gerant } = await admin
    .from("accounts").select("transporter_type,city").eq("id", ownerId).maybeSingle();

  const motDePasse = motDePasseProvisoire();
  const { data: cree, error: creationErr } = await admin.auth.admin.createUser({
    email,
    password: motDePasse,
    email_confirm: true,
    user_metadata: {
      role: "transporter",
      transporter_type: gerant?.transporter_type || "vl",
      full_name: nom,
      phone: telephone || null,
      city: gerant?.city || null,
    },
  });
  if (creationErr || !cree?.user?.id) {
    return json(502, { error: "creation_impossible", detail: creationErr?.message || null });
  }

  // 4. Rattachement à l'entreprise et drapeau de mot de passe provisoire.
  const { error: attachErr } = await admin.rpc("secoto_carrier_attach_employee", {
    p_owner_id: ownerId,
    p_account_id: cree.user.id,
  });
  if (attachErr) {
    // Le compte ne doit pas rester orphelin si le rattachement échoue.
    await admin.auth.admin.deleteUser(cree.user.id).catch(() => null);
    return json(500, { error: "rattachement_impossible", detail: attachErr.message });
  }

  return json(200, { existe: false, email, mot_de_passe: motDePasse });
};

export default withLambda(withCors(handler));

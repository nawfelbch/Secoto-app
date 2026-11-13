import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { auteurChat, chatVisibleCommande, chatVisibleMission, heureChat, texteAEnvoyer, titreChat, CHAT_MAX } from "../src/lib/chatUtil.js";

const sql = readFileSync(new URL("../supabase/migrations/202611130142_chat_mission.sql", import.meta.url), "utf8");
const livrable = readFileSync(new URL("../deliverables/SECOTO-142-chat-mission-a-coller-dans-Supabase.sql", import.meta.url), "utf8");
const chat = readFileSync(new URL("../src/ondemand/ChatMission.jsx", import.meta.url), "utf8");
const panel = readFileSync(new URL("../src/ondemand/MyOrdersPanel.jsx", import.meta.url), "utf8");
const app = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");

test("142 : titres et auteurs selon le lecteur", () => {
  assert.equal(titreChat("client"), "Discuter avec votre transporteur");
  assert.equal(titreChat("transporteur"), "Discuter avec votre client");
  assert.equal(titreChat("admin"), "Conversation client ↔ transporteur");
  assert.equal(auteurChat({ moi: true, auteur_role: "client" }, "client"), "Vous");
  assert.equal(auteurChat({ auteur_role: "transporteur" }, "client"), "Votre transporteur");
  assert.equal(auteurChat({ auteur_role: "client" }, "transporteur"), "Votre client");
  assert.equal(auteurChat({ auteur_role: "client" }, "admin"), "Client");
  assert.equal(auteurChat({ auteur_role: "admin" }, "client"), "SECOTO");
});

test("142 : texte nettoyé et borné, heure lisible", () => {
  assert.equal(texteAEnvoyer("   "), "");
  assert.equal(texteAEnvoyer("  Bonjour  "), "Bonjour");
  assert.equal(texteAEnvoyer("x".repeat(CHAT_MAX + 50)).length, CHAT_MAX);
  const maintenant = new Date("2026-11-13T10:00:00");
  assert.match(heureChat("2026-11-13T09:05:00", maintenant), /^09:05$/);
  assert.doesNotMatch(heureChat("2026-11-10T09:05:00", maintenant), /^09:05$/);
  assert.equal(heureChat("pas une date"), "");
});

test("142 : le chat n'apparaît qu'avec un transporteur attribué", () => {
  assert.equal(chatVisibleMission({ id: "m", assignedTransporterId: "t", status: "assigned" }), true);
  assert.equal(chatVisibleMission({ id: "m", assignedTransporterId: "t", status: "completed" }), true);
  assert.equal(chatVisibleMission({ id: "m", assignedTransporterId: "", status: "published" }), false);
  assert.equal(chatVisibleMission({ id: "m", assignedTransporterId: "t", status: "cancelled" }), false);
  assert.equal(chatVisibleCommande({ mission_id: "m", status: "partner_confirmed" }), true);
  assert.equal(chatVisibleCommande({ mission_id: "m", status: "delivered" }), true);
  assert.equal(chatVisibleCommande({ mission_id: "m", status: "searching_partner" }), false);
  assert.equal(chatVisibleCommande({ mission_id: null, status: "picked_up" }), false);
});

test("142 : base — accès par fonctions seulement, participants vérifiés", () => {
  assert.match(sql, /revoke all on table public\.mission_messages from public, anon, authenticated;/);
  assert.match(sql, /alter table public\.mission_messages enable row level security;/);
  assert.match(sql, /m\.assigned_transporter_id = p_user or m\.carrier_employee_id = p_user/);
  assert.match(sql, /o\.mission_id = p_mission and o\.account_id = p_user/);
  assert.match(sql, /if v_role is null then raise exception 'Accès refusé\.'; end if;/);
  assert.match(sql, /revoke all on function public\.%s from public, anon/);
});

test("142 : base — fermeture 7 jours après livraison, anti-abus, notification espacée, signalement", () => {
  assert.match(sql, /m\.status::text not in \('cancelled', 'published'\)/);
  assert.match(sql, /interval '7 days'/);
  assert.match(sql, />= 30 then/);
  assert.match(sql, /extract\(epoch from now\(\)\) \/ 600/);
  assert.match(sql, /notify_admins_event\('order_update', 'Message signalé dans un chat'/);
  assert.match(sql, /Vous ne pouvez pas signaler votre propre message\./);
  assert.equal(livrable.replace(/\r/g, ""), sql.replace(/\r/g, ""));
});

test("142 : écrans — client, transporteur, admin ; signaler ; mention de conservation", () => {
  assert.match(panel, /chatVisibleCommande\(order\) && <ChatMission missionId=\{order\.mission_id\} roleAttendu="client" \/>/);
  assert.match(app, /\["transporter", "admin"\]\.includes\(visiblePricing\) && chatVisibleMission\(mission\)/);
  assert.match(chat, /Signaler/);
  assert.match(chat, /peuvent être consultés par SECOTO en cas de litige/);
  assert.doesNotMatch(chat, /dangerouslySetInnerHTML/);
});

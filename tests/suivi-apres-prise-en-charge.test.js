// Suivi GPS côté client (ajustement 046).
// La carte ne doit s'ouvrir qu'une fois le véhicule à bord : avant, elle
// montrerait le transporteur chez lui ou sur une autre course.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ORDERS = readFileSync(new URL("../src/ondemand/MyOrdersPanel.jsx", import.meta.url), "utf8");
const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
const VUE = readFileSync(new URL("../src/ondemand/LiveTrackingView.jsx", import.meta.url), "utf8");

test("commande en ligne : suivi ouvert seulement après la prise en charge", () => {
  assert.match(ORDERS, /order\.status === "picked_up"/);
  assert.doesNotMatch(ORDERS, /\["partner_confirmed", "picked_up", "delivered"\]/);
});

test("mission classique : mêmes conditions, sur l'avancement réel", () => {
  assert.match(APP, /\["pickup_completed", "in_transit", "incident_reported", "delivery_started"\]\.includes\(mission\.progressStatus\)/);
});

test("le suivi reste derrière le drapeau live_tracking", () => {
  assert.match(ORDERS, /flags\?\.live_tracking/);
  assert.match(APP, /flags\.live_tracking && mission\.status === "assigned"/);
});

test("la vue dit franchement quand le transporteur ne partage pas", () => {
  assert.match(VUE, /sharing/);
});

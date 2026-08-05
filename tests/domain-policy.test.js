import test from "node:test";
import assert from "node:assert/strict";

import {
  APPLICATION_STATUS_TRANSITIONS,
  MISSION_STATUS_TRANSITIONS,
  PAYMENT_METHODS,
  PUBLIC_SIGNUP_ROLES,
  REQUEST_STATUS_TRANSITIONS,
  TRANSPORTER_TYPE_VALUES,
  canTransition,
  isPublicSignupRole,
  normalizePublicSignupMetadata,
  progressFromTrackingEvent,
} from "../src/lib/domainPolicy.js";

test("seuls client et transporteur sont des rôles d'inscription publique", () => {
  assert.deepEqual(PUBLIC_SIGNUP_ROLES, ["client", "transporter"]);
  assert.equal(isPublicSignupRole("client"), true);
  assert.equal(isPublicSignupRole("transporter"), true);
  assert.equal(isPublicSignupRole("admin"), false);
  assert.equal(isPublicSignupRole("service_role"), false);
  assert.equal(isPublicSignupRole("inconnu"), false);
});

test("les métadonnées sensibles ne traversent jamais la normalisation d'inscription", () => {
  const result = normalizePublicSignupMetadata({
    role: "admin",
    full_name: "  Alice  ",
    client_type: "pro",
    luxury_closed_transport_requested: true,
    receives_standard_plateau: false,
    is_verified: true,
    status: "active",
    docs_count: 99,
  });

  assert.deepEqual(result, {
    full_name: "Alice",
    company_name: "",
    phone: "",
    city: "",
    role: "client",
    client_type: "pro",
    transporter_type: null,
    receives_standard_plateau: false,
    luxury_closed_transport_requested: false,
  });
  assert.equal("is_verified" in result, false);
  assert.equal("status" in result, false);
  assert.equal("docs_count" in result, false);
});

test("les trois sous-types transporteur restent inchangés", () => {
  assert.deepEqual(TRANSPORTER_TYPE_VALUES, ["convoyeur", "vl", "pl"]);
  for (const transporter_type of TRANSPORTER_TYPE_VALUES) {
    assert.equal(
      normalizePublicSignupMetadata({ role: "transporter", transporter_type }).transporter_type,
      transporter_type,
    );
  }
});

test("les modes de règlement actuels restent strictement inchangés", () => {
  assert.deepEqual(PAYMENT_METHODS, ["virement", "especes"]);
});

test("les transitions de mission, demande et candidature sont bornées", () => {
  assert.equal(canTransition(MISSION_STATUS_TRANSITIONS, "published", "assigned"), true);
  assert.equal(canTransition(MISSION_STATUS_TRANSITIONS, "assigned", "completed"), true);
  assert.equal(canTransition(MISSION_STATUS_TRANSITIONS, "completed", "published"), false);
  assert.equal(canTransition(REQUEST_STATUS_TRANSITIONS, "pending", "approved"), true);
  assert.equal(canTransition(REQUEST_STATUS_TRANSITIONS, "approved", "pending"), false);
  assert.equal(canTransition(APPLICATION_STATUS_TRANSITIONS, "pending", "accepted"), true);
  assert.equal(canTransition(APPLICATION_STATUS_TRANSITIONS, "accepted", "pending"), false);
});

test("chaque événement terrain garde son statut de progression historique", () => {
  assert.equal(progressFromTrackingEvent("pickup_inspection"), "pickup_completed");
  assert.equal(progressFromTrackingEvent("road_incident"), "incident_reported");
  assert.equal(progressFromTrackingEvent("delivery_inspection"), "delivery_completed");
  assert.equal(progressFromTrackingEvent("inconnu"), null);
});

test("une demande camion fermé reste une demande non validée", () => {
  const result = normalizePublicSignupMetadata({
    role: "transporter",
    transporter_type: "vl",
    receives_standard_plateau: false,
    luxury_closed_transport_requested: true,
    luxury_closed_transport_status: "approved",
  });

  assert.equal(result.transporter_type, "vl");
  assert.equal(result.receives_standard_plateau, false);
  assert.equal(result.luxury_closed_transport_requested, true);
  assert.equal("luxury_closed_transport_status" in result, false);
});
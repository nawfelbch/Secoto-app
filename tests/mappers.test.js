import test from "node:test";
import assert from "node:assert/strict";

import {
  accountFromDb,
  missionFromDb,
  missionToDb,
  publicMissionFromDb,
  requestToDb,
} from "../src/lib/mappers.js";

test("accountFromDb conserve les rôles et sous-types existants", () => {
  assert.deepEqual(
    accountFromDb({
      id: "a-1",
      role: "transporter",
      full_name: "Jean Convoyeur",
      company_name: "JC Transport",
      email: "jean@example.test",
      phone: "0102030405",
      city: "Lyon",
      status: "active",
      docs_count: 3,
      is_verified: true,
      transporter_type: "convoyeur",
      client_type: null,
      created_at: "2026-01-01T00:00:00Z",
    }),
    {
      id: "a-1",
      role: "transporter",
      fullName: "Jean Convoyeur",
      companyName: "JC Transport",
      email: "jean@example.test",
      phone: "0102030405",
      city: "Lyon",
      status: "active",
      docsCount: 3,
      isVerified: true,
      transporterType: "convoyeur",
      clientType: null,
      createdAt: "2026-01-01T00:00:00Z",
    },
  );
});

test("missionFromDb conserve tous les champs autorisés d'une mission privée", () => {
  const result = missionFromDb({
    id: "m-1",
    public_ref: "MIS-2026-1000",
    type: "plateau",
    status: "assigned",
    progress_status: "pickup_completed",
    from_city: "Paris",
    to_city: "Lyon",
    pickup_address: "1 rue du Départ",
    delivery_address: "2 rue de l'Arrivée",
    mission_date: "2026-08-01",
    vehicle: "Utilitaire",
    plate: "AA-123-AA",
    distance_km: 465,
    carrier_cost: 400,
    client_price: 480,
    carrier_pay: 400,
    margin: 80,
    client_name: "Client",
    client_contact: "Contact",
    client_phone: "0102030405",
    price_mode: "fixed",
    proposed_price: 400,
    payment_method: "especes",
    notes: "Fragile",
    created_by_role: "admin",
    client_account_id: "c-1",
    assigned_transporter_id: "t-1",
    assigned_transporter_name: "Transporteur",
    source_request_id: "r-1",
    created_at: "2026-01-01T00:00:00Z",
  });

  assert.equal(result.pickupAddress, "1 rue du Départ");
  assert.equal(result.deliveryAddress, "2 rue de l'Arrivée");
  assert.equal(result.clientPrice, 480);
  assert.equal(result.carrierPay, 400);
  assert.equal(result.margin, 80);
  assert.equal(result.paymentMethod, "especes");
});

test("missionToDb omet les valeurs vides sans changer les valeurs explicites", () => {
  const payload = missionToDb(
    {
      type: "convoyage",
      fromCity: "Paris",
      toCity: "Lille",
      pickupAddress: "",
      distanceKm: "220.5",
      carrierCost: "",
      paymentMethod: "virement",
    },
    { publicRef: "MIS-TEST", status: "published", createdByRole: "client" },
  );

  assert.equal(payload.public_ref, "MIS-TEST");
  assert.equal(payload.distance_km, 220.5);
  assert.equal(payload.payment_method, "virement");
  assert.equal(payload.created_by_role, "client");
  assert.equal("pickup_address" in payload, false);
  assert.equal("carrier_cost" in payload, false);
});

test("requestToDb n'envoie jamais les colonnes propres à missions", () => {
  const payload = requestToDb(
    {
      type: "plateau",
      fromCity: "Nantes",
      toCity: "Rennes",
      carrierCost: "999",
      paymentMethod: "especes",
      clientName: "Demandeur",
    },
    { id: "t-1", role: "transporter", fullName: "T", companyName: "Société" },
    { publicRef: "REQ-TEST" },
  );

  for (const forbidden of [
    "assigned_transporter_id",
    "carrier_cost",
    "payment_method",
    "client_account_id",
    "source_request_id",
  ]) {
    assert.equal(forbidden in payload, false, forbidden);
  }
  assert.equal(payload.status, "pending");
  assert.equal(payload.requester_id, "t-1");
});

test("le mapper du flux transporteur doit expurger les adresses exactes", () => {
  const result = publicMissionFromDb({
    id: "m-2",
    public_ref: "MIS-2026-1001",
    type: "convoyage",
    status: "published",
    progress_status: null,
    from_city: "Paris",
    to_city: "Lyon",
    pickup_address: "Adresse privée de départ",
    delivery_address: "Adresse privée d'arrivée",
    vehicle: "Berline",
    distance_km: 465,
    created_at: "2026-01-01T00:00:00Z",
  });

  assert.equal(result.fromCity, "Paris");
  assert.equal(result.toCity, "Lyon");
  assert.equal("pickupAddress" in result, false);
  assert.equal("deliveryAddress" in result, false);
});

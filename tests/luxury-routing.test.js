import test from "node:test";
import assert from "node:assert/strict";
import {
  missionRoutingKey,
  transporterMatchesMission,
} from "../src/lib/luxuryRouting.js";

const verified = {
  role: "transporter",
  status: "active",
  isVerified: true,
};

test("le convoyage standard ou prestige est réservé aux convoyeurs", () => {
  for (const vehicleCategory of ["standard", "luxury"]) {
    const mission = { type: "convoyage", vehicleCategory };

    assert.equal(
      missionRoutingKey(mission),
      "convoyage",
    );
    assert.equal(
      transporterMatchesMission(
        { ...verified, transporterType: "convoyeur" },
        mission,
      ),
      true,
    );
    assert.equal(
      transporterMatchesMission(
        { ...verified, transporterType: "vl" },
        mission,
      ),
      false,
    );
  }
});

test("le plateau standard cible les VL ou PL acceptant les missions standard", () => {
  const mission = { type: "plateau", vehicleCategory: "standard" };

  assert.equal(
    transporterMatchesMission(
      {
        ...verified,
        transporterType: "vl",
        receivesStandardPlateau: true,
      },
      mission,
    ),
    true,
  );
  assert.equal(
    transporterMatchesMission(
      {
        ...verified,
        transporterType: "pl",
        receivesStandardPlateau: false,
      },
      mission,
    ),
    false,
  );
  assert.equal(
    transporterMatchesMission(
      { ...verified, transporterType: "convoyeur" },
      mission,
    ),
    false,
  );
});

test("le transport premium en camion fermé exige une capacité approuvée", () => {
  const mission = { type: "plateau", vehicleCategory: "luxury" };

  assert.equal(missionRoutingKey(mission), "closed_luxury");
  assert.equal(
    transporterMatchesMission(
      {
        ...verified,
        transporterType: "vl",
        luxuryClosedTransportStatus: "approved",
      },
      mission,
    ),
    true,
  );

  for (const status of [
    "not_requested",
    "pending",
    "rejected",
    "suspended",
  ]) {
    assert.equal(
      transporterMatchesMission(
        {
          ...verified,
          transporterType: "pl",
          luxuryClosedTransportStatus: status,
        },
        mission,
      ),
      false,
    );
  }
});

test("un compte non actif ou non vérifié ne reçoit aucune mission", () => {
  const mission = { type: "convoyage", vehicleCategory: "standard" };

  assert.equal(
    transporterMatchesMission(
      {
        role: "transporter",
        status: "pending",
        isVerified: true,
        transporterType: "convoyeur",
      },
      mission,
    ),
    false,
  );
  assert.equal(
    transporterMatchesMission(
      {
        role: "transporter",
        status: "active",
        isVerified: false,
        transporterType: "convoyeur",
      },
      mission,
    ),
    false,
  );
});
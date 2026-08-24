import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const FUNCTIONS = [
  "create-payment-intent.js",
  "request-account-deletion.js",
  "retry-account-deletions.js",
  "retry-push-outbox.js",
  "retry-refunds.js",
  "send-mission-notifications.js",
  "send-transactional-email.js",
  "stripe-webhook.js",
];

test("les fonctions Netlify utilisent le runtime moderne avec le wrapper Lambda", () => {
  for (const file of FUNCTIONS) {
    const source = readFileSync(
      new URL(`../netlify/functions/${file}`, import.meta.url),
      "utf8",
    );

    assert.match(source, /export default withLambda\(/, `${file}: export moderne absent`);
    assert.doesNotMatch(
      source,
      /export\s+(?:const|let|var|async\s+function|function)\s+handler\b/,
      `${file}: un export handler nommé réactive la compatibilité AWS Lambda`,
    );
  }
});

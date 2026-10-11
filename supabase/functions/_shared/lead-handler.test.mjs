import assert from "node:assert/strict";
import test from "node:test";
import { createLeadHandler, signLeadPayload } from "./lead-handler.mjs";

const secret = "test-webhook-secret";
const now = () => 1_800_000_000_000;
const payload = {
  id: "partner-123",
  name: "Alex Example",
  email: "Alex@example.com",
  company: "Example Co",
  source: "partner-site",
};

async function signedRequest(body, timestamp = `${Math.floor(now() / 1000)}`) {
  const { signature } = await signLeadPayload(body, secret, timestamp);
  return new Request("https://example.test/receive-lead", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-lead-timestamp": timestamp,
      "x-lead-signature": signature,
    },
    body,
  });
}

function inMemoryUpsert(rows) {
  return async (lead) => {
    const existing = rows.find(
      (row) => row.external_id === lead.external_id || row.email === lead.email,
    );
    if (existing) {
      Object.assign(existing, lead);
      return existing;
    }
    const saved = { ...lead, stage: "New" };
    rows.push(saved);
    return saved;
  };
}

test("rejects requests with an invalid signature without persisting a lead", async () => {
  const rows = [];
  const handler = createLeadHandler({
    secret,
    now,
    upsertLead: inMemoryUpsert(rows),
  });
  const request = await signedRequest(JSON.stringify(payload));
  const headers = new Headers(request.headers);
  headers.set("x-lead-signature", `sha256=${"0".repeat(64)}`);

  const response = await handler(new Request(request, { headers }));

  assert.equal(response.status, 401);
  assert.equal(rows.length, 0);
});

test("duplicate submissions with the same partner ID update one record", async () => {
  const rows = [];
  const handler = createLeadHandler({
    secret,
    now,
    upsertLead: inMemoryUpsert(rows),
  });
  const first = await signedRequest(JSON.stringify(payload));
  const updatedPayload = { ...payload, name: "Alex Updated" };
  const second = await signedRequest(JSON.stringify(updatedPayload));

  assert.equal((await handler(first)).status, 200);
  assert.equal((await handler(second)).status, 200);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].name, "Alex Updated");
});

test("a new partner ID with an existing email updates the existing record", async () => {
  const rows = [];
  const handler = createLeadHandler({
    secret,
    now,
    upsertLead: inMemoryUpsert(rows),
  });
  await handler(await signedRequest(JSON.stringify(payload)));
  const matchingEmail = {
    ...payload,
    id: "partner-456",
    name: "Alex From Another Source",
    email: " ALEX@EXAMPLE.COM ",
  };

  assert.equal((await handler(await signedRequest(JSON.stringify(matchingEmail)))).status, 200);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].external_id, "partner-456");
  assert.equal(rows[0].name, "Alex From Another Source");
});

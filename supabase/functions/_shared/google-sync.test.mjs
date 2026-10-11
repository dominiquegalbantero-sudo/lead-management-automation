import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import {
  decryptRefreshToken,
  encryptRefreshToken,
  getAccessToken,
  upsertSheetRow,
} from "./google.ts";

const originalFetch = globalThis.fetch;
const originalDeno = globalThis.Deno;
const testEncryptionKey = Buffer.alloc(32, 7).toString("base64");

afterEach(() => {
  globalThis.fetch = originalFetch;
  if (originalDeno === undefined) {
    delete globalThis.Deno;
  } else {
    globalThis.Deno = originalDeno;
  }
});

const lead = {
  id: "record-1",
  external_id: "partner-1",
  name: "Test Lead",
  email: "test@example.com",
  company: "Example Co",
  source: "test",
  stage: "New",
  updated_at: "2026-10-12T00:00:00.000Z",
};

test("appends a new lead using the Google Sheets append endpoint", async () => {
  const requests = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input);
    requests.push({ url, method: init.method ?? "GET" });
    if (url.pathname.endsWith("/A:A")) {
      return Response.json({ values: [["Record ID", "Partner Lead ID"]] });
    }
    return Response.json({});
  };

  await upsertSheetRow("spreadsheet-1", "access-token", lead);

  assert.equal(requests.length, 2);
  assert.equal(requests[1].method, "POST");
  assert.ok(requests[1].url.pathname.endsWith("/values/A:H:append"));
  assert.equal(requests[1].url.searchParams.get("valueInputOption"), "RAW");
});

test("updates an existing lead row instead of appending a duplicate", async () => {
  const requests = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input);
    requests.push({ url, method: init.method ?? "GET" });
    if (url.pathname.endsWith("/A:A")) {
      return Response.json({ values: [["Record ID"], [lead.id]] });
    }
    return Response.json({});
  };

  await upsertSheetRow("spreadsheet-1", "access-token", lead);

  assert.equal(requests.length, 2);
  assert.equal(requests[1].method, "PUT");
  assert.ok(requests[1].url.pathname.endsWith("/values/A2:H2"));
});

test("encrypts refresh tokens at rest and can decrypt them for sync", async () => {
  globalThis.Deno = {
    env: { get: (name) => name === "GOOGLE_TOKEN_ENCRYPTION_KEY" ? testEncryptionKey : undefined },
  };

  const refreshToken = "google-refresh-token-test";
  const encryptedToken = await encryptRefreshToken(refreshToken);

  assert.match(encryptedToken, /^v1\./);
  assert.ok(!encryptedToken.includes(refreshToken));
  assert.equal(await decryptRefreshToken(encryptedToken), refreshToken);
});

test("uses the saved refresh token to obtain a fresh access token", async () => {
  globalThis.Deno = {
    env: {
      get: (name) => ({
        GOOGLE_TOKEN_ENCRYPTION_KEY: testEncryptionKey,
        GOOGLE_OAUTH_CLIENT_ID: "test-client-id",
        GOOGLE_OAUTH_CLIENT_SECRET: "test-client-secret",
      })[name],
    },
  };
  const refreshToken = "google-refresh-token-test";
  const encryptedToken = await encryptRefreshToken(refreshToken);
  let requestedUrl;
  let requestedBody;
  globalThis.fetch = async (input, init = {}) => {
    requestedUrl = new URL(input);
    requestedBody = new URLSearchParams(init.body);
    return Response.json({ access_token: "fresh-access-token", expires_in: 3600 });
  };

  const accessToken = await getAccessToken({
    id: "integration-1",
    refresh_token_encrypted: encryptedToken,
  });

  assert.equal(accessToken, "fresh-access-token");
  assert.equal(requestedUrl.href, "https://oauth2.googleapis.com/token");
  assert.equal(requestedBody.get("grant_type"), "refresh_token");
  assert.equal(requestedBody.get("refresh_token"), refreshToken);
  assert.equal(requestedBody.get("client_id"), "test-client-id");
  assert.equal(requestedBody.get("client_secret"), "test-client-secret");
});

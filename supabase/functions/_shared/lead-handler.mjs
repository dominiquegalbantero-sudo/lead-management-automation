const encoder = new TextEncoder();
const maxBodyBytes = 64 * 1024;
const maxClockSkewSeconds = 5 * 60;

/**
 * @typedef {{
 *   external_id: string;
 *   name: string;
 *   email: string;
 *   company: string;
 *   source: string;
 * }} Lead
 */

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function constantTimeEquals(left, right) {
  const length = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < length; index++) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

async function isValidSignature(rawBody, timestamp, supplied, secret, now) {
  if (!/^\d{10}$/.test(timestamp) || !/^sha256=[0-9a-f]{64}$/i.test(supplied)) {
    return false;
  }

  const timestampSeconds = Number(timestamp);
  if (Math.abs(Math.floor(now / 1000) - timestampSeconds) > maxClockSkewSeconds) {
    return false;
  }

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${rawBody}`)),
  );
  const expected = `sha256=${Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
  return constantTimeEquals(expected.toLowerCase(), supplied.toLowerCase());
}

function parseLead(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const { id, name, email, company, source } = value;
  if (
    typeof id !== "string" || id.trim().length === 0 || id.trim().length > 200 ||
    typeof name !== "string" || name.trim().length === 0 || name.trim().length > 200 ||
    typeof email !== "string" || email.trim().length > 320 ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim()) ||
    typeof company !== "string" || company.length > 200 ||
    typeof source !== "string" || source.length > 200
  ) {
    return null;
  }

  return {
    external_id: id.trim(),
    name: name.trim(),
    email: email.trim().toLowerCase(),
    company: company.trim(),
    source: source.trim(),
  };
}

/**
 * @param {{
 *   secret: string | undefined;
 *   upsertLead: (lead: Lead) => Promise<unknown>;
 *   now?: () => number;
 * }} options
 */
export function createLeadHandler({ secret, upsertLead, now = () => Date.now() }) {
  return async (request) => {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204 });
    }
    if (request.method !== "POST") {
      return jsonResponse(405, { error: "Method not allowed" });
    }
    if (!secret) {
      console.error("LEAD_WEBHOOK_SECRET is not configured");
      return jsonResponse(500, { error: "Lead reception is not configured" });
    }

    const declaredLength = Number(request.headers.get("content-length"));
    if (Number.isFinite(declaredLength) && declaredLength > maxBodyBytes) {
      return jsonResponse(413, { error: "Request body is too large" });
    }
    const rawBody = await request.text();
    if (encoder.encode(rawBody).length > maxBodyBytes) {
      return jsonResponse(413, { error: "Request body is too large" });
    }

    const timestamp = request.headers.get("x-lead-timestamp") ?? "";
    const signature = request.headers.get("x-lead-signature") ?? "";
    if (!(await isValidSignature(rawBody, timestamp, signature, secret, now()))) {
      return jsonResponse(401, { error: "Invalid or expired signature" });
    }

    let value;
    try {
      value = JSON.parse(rawBody);
    } catch {
      return jsonResponse(400, { error: "Request body must be valid JSON" });
    }

    const lead = parseLead(value);
    if (!lead) {
      return jsonResponse(400, {
        error: "Lead must include a valid id, name, email, company, and source",
      });
    }

    try {
      const savedLead = await upsertLead(lead);
      return jsonResponse(200, { lead: savedLead });
    } catch (error) {
      if (error?.status === 409) {
        return jsonResponse(409, { error: error.message });
      }
      console.error("Failed to persist incoming lead", error);
      return jsonResponse(500, { error: "Unable to save lead" });
    }
  };
}

/**
 * @param {string} payload
 * @param {string} secret
 * @param {string} [timestamp]
 */
export async function signLeadPayload(payload, secret, timestamp = `${Math.floor(Date.now() / 1000)}`) {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${payload}`)),
  );
  return {
    timestamp,
    signature: `sha256=${Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("")}`,
  };
}

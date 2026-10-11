const encoder = new TextEncoder();
const decoder = new TextDecoder();

function decodeBase64(value: string) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function encodeBase64(value: Uint8Array) {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function encryptionKey() {
  const encoded = Deno.env.get("GOOGLE_TOKEN_ENCRYPTION_KEY");
  if (!encoded) throw new Error("GOOGLE_TOKEN_ENCRYPTION_KEY is not configured");
  const raw = decodeBase64(encoded);
  if (raw.length !== 32) {
    throw new Error("GOOGLE_TOKEN_ENCRYPTION_KEY must be a base64-encoded 32-byte key");
  }
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function encryptRefreshToken(refreshToken: string) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await encryptionKey();
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    encoder.encode(refreshToken),
  );
  return `v1.${encodeBase64(iv)}.${encodeBase64(new Uint8Array(encrypted))}`;
}

export async function decryptRefreshToken(value: string) {
  const [version, encodedIv, encodedCiphertext, extra] = value.split(".");
  if (version !== "v1" || !encodedIv || !encodedCiphertext || extra) {
    throw new Error("Stored Google refresh token has an unsupported format");
  }
  const key = await encryptionKey();
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: decodeBase64(encodedIv) },
    key,
    decodeBase64(encodedCiphertext),
  );
  return decoder.decode(plaintext);
}

export async function sha256Hex(value: string) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function randomState() {
  return Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

async function googleJson<T>(response: Response): Promise<T> {
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`Google API request failed (${response.status}): ${text.slice(0, 500)}`);
  }
  return JSON.parse(text) as T;
}

export async function getAccessToken(integration: {
  id: string;
  refresh_token_encrypted: string;
}) {
  const clientId = Deno.env.get("GOOGLE_OAUTH_CLIENT_ID");
  const clientSecret = Deno.env.get("GOOGLE_OAUTH_CLIENT_SECRET");
  if (!clientId || !clientSecret) {
    throw new Error("Google OAuth client credentials are not configured");
  }

  const refreshToken = await decryptRefreshToken(integration.refresh_token_encrypted);
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
  });
  const token = await googleJson<{ access_token: string }>(response);
  return token.access_token;
}

async function sheetsRequest(url: URL, accessToken: string, init?: RequestInit) {
  return googleJson<Record<string, unknown>>(
    await fetch(url, {
      ...init,
      headers: {
        authorization: `Bearer ${accessToken}`,
        ...(init?.headers ?? {}),
      },
    }),
  );
}

export async function upsertSheetRow(
  spreadsheetId: string,
  accessToken: string,
  lead: {
    id: string;
    external_id: string;
    name: string;
    email: string;
    company: string;
    source: string;
    stage: string;
    updated_at: string;
  },
) {
  const base = `https://sheets.googleapis.com/v4/spreadsheets/${encodeURIComponent(spreadsheetId)}/values`;
  const readUrl = new URL(`${base}/A:A`);
  const sheetData = await sheetsRequest(readUrl, accessToken) as {
    values?: string[][];
  };
  const values = sheetData.values ?? [];
  const headers = [
    "Record ID",
    "Partner Lead ID",
    "Name",
    "Email",
    "Company",
    "Source",
    "Stage",
    "Updated At",
  ];

  if (!values.length) {
    const headerUrl = new URL(`${base}/A1:H1`);
    headerUrl.searchParams.set("valueInputOption", "RAW");
    await sheetsRequest(headerUrl, accessToken, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ values: [headers] }),
    });
  }

  const row = [
    lead.id,
    lead.external_id,
    lead.name,
    lead.email,
    lead.company,
    lead.source,
    lead.stage,
    lead.updated_at,
  ];
  const existingIndex = values.findIndex((existing) => existing[0] === lead.id);
  const rowUrl = new URL(
    existingIndex >= 0
      ? `${base}/A${existingIndex + 1}:H${existingIndex + 1}`
      : `${base}/A:H:append`,
  );
  rowUrl.searchParams.set("valueInputOption", "RAW");
  await sheetsRequest(rowUrl, accessToken, {
    method: existingIndex >= 0 ? "PUT" : "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ values: [row] }),
  });
}

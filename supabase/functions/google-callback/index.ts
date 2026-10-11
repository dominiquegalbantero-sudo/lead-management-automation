/// <reference path="../_shared/edge-runtime.d.ts" />
import { createAdminClient, serviceRoleKey, supabaseUrl } from "../_shared/http.ts";
import { encryptRefreshToken, sha256Hex } from "../_shared/google.ts";

const supabase = createAdminClient();

function htmlResponse(status: number, title: string, message: string) {
  return new Response(
    `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${title}</title><body><main><h1>${title}</h1><p>${message}</p></main></body></html>`,
    {
      status,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
        "referrer-policy": "no-referrer",
        "x-content-type-options": "nosniff",
      },
    },
  );
}

Deno.serve(async (request) => {
  if (request.method !== "GET") {
    return htmlResponse(405, "Google Sheets connection failed", "This callback only accepts GET requests.");
  }

  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  if (url.searchParams.has("error")) {
    return htmlResponse(400, "Google Sheets connection cancelled", "Return to the app and try again.");
  }
  if (!code || !state || !/^[0-9a-f]{64}$/.test(state)) {
    return htmlResponse(400, "Google Sheets connection failed", "The authorization response is invalid.");
  }

  const { data: states, error: stateError } = await supabase.rpc(
    "consume_google_oauth_state",
    { p_state_hash: await sha256Hex(state) },
  );
  if (stateError) {
    console.error("Unable to validate Google OAuth state", stateError);
    return htmlResponse(500, "Google Sheets connection failed", "Unable to validate the authorization request.");
  }
  const oauthState = Array.isArray(states) ? states[0] : null;
  if (!oauthState) {
    return htmlResponse(400, "Google Sheets connection failed", "This authorization request has expired or was already used.");
  }

  const clientId = Deno.env.get("GOOGLE_OAUTH_CLIENT_ID");
  const clientSecret = Deno.env.get("GOOGLE_OAUTH_CLIENT_SECRET");
  const redirectUri = Deno.env.get("GOOGLE_OAUTH_REDIRECT_URI") ??
    `${supabaseUrl}/functions/v1/google-callback`;
  if (!clientId || !clientSecret || !redirectUri) {
    console.error("Google OAuth client credentials are not configured");
    return htmlResponse(500, "Google Sheets connection failed", "The integration is not configured.");
  }

  try {
    const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: redirectUri,
        grant_type: "authorization_code",
      }),
    });
    const tokenText = await tokenResponse.text();
    if (!tokenResponse.ok) {
      console.error("Google authorization-code exchange failed", tokenResponse.status);
      return htmlResponse(502, "Google Sheets connection failed", "Google could not complete authorization. Start the connection again.");
    }

    const tokens = JSON.parse(tokenText) as { refresh_token?: string };
    const { data: existing, error: lookupError } = await supabase
      .from("google_integrations")
      .select("refresh_token_encrypted")
      .eq("user_id", oauthState.user_id)
      .maybeSingle();
    if (lookupError) throw lookupError;

    const refreshToken = tokens.refresh_token
      ? await encryptRefreshToken(tokens.refresh_token)
      : existing?.refresh_token_encrypted;
    if (!refreshToken) {
      return htmlResponse(
        502,
        "Google Sheets connection failed",
        "Google did not provide ongoing access. Start the connection again and approve offline access.",
      );
    }

    const { error: saveError } = await supabase.from("google_integrations").upsert({
      user_id: oauthState.user_id,
      spreadsheet_id: oauthState.spreadsheet_id,
      refresh_token_encrypted: refreshToken,
      updated_at: new Date().toISOString(),
    }, { onConflict: "user_id" });
    if (saveError) throw saveError;

    EdgeRuntime.waitUntil(
      fetch(`${supabaseUrl}/functions/v1/sync-sheets`, {
        method: "POST",
        headers: {
          apikey: serviceRoleKey,
          authorization: `Bearer ${serviceRoleKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({}),
      }).then((response) => {
        if (!response.ok || response.status === 207) {
          console.error("Google account connected, but queued sheet sync failed", response.status);
        }
      }).catch((error) => console.error("Google account connected, but queued sheet sync failed", error)),
    );

    return htmlResponse(200, "Google Sheets connected", "Your account is connected. Queued leads will sync shortly.");
  } catch (error) {
    console.error("Failed to finish Google OAuth connection", error);
    return htmlResponse(500, "Google Sheets connection failed", "Unable to save the Google integration.");
  }
});

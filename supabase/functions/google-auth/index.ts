import { createAdminClient, corsHeaders, getAuthenticatedUserId, isOptionsRequest, jsonResponse } from "../_shared/http.ts";
import { randomState, sha256Hex } from "../_shared/google.ts";

const supabase = createAdminClient();

Deno.serve(async (request) => {
  if (isOptionsRequest(request)) {
    return new Response(null, { status: 204, headers: corsHeaders(request) });
  }
  const userId = await getAuthenticatedUserId(request, supabase);
  if (!userId) {
    return jsonResponse(request, 401, { error: "Sign in to the dashboard before connecting Sheets" });
  }

  if (request.method === "GET") {
    const { data, error } = await supabase
      .from("google_integrations")
      .select("spreadsheet_id")
      .eq("user_id", userId)
      .maybeSingle();
    if (error) {
      console.error("Unable to check Google Sheets connection", error);
      return jsonResponse(request, 500, { error: "Unable to check Google Sheets connection" });
    }
    return jsonResponse(request, 200, {
      connected: !!data,
      spreadsheet_id: data?.spreadsheet_id ?? null,
    });
  }

  if (request.method !== "POST") {
    return jsonResponse(request, 405, { error: "Method not allowed" });
  }

  const clientId = Deno.env.get("GOOGLE_OAUTH_CLIENT_ID");
  const redirectUri = Deno.env.get("GOOGLE_OAUTH_REDIRECT_URI") ??
    `${Deno.env.get("SUPABASE_URL")}/functions/v1/google-callback`;
  if (!clientId || !redirectUri || redirectUri.includes("undefined")) {
    console.error("Google OAuth client ID or callback URL is not configured");
    return jsonResponse(request, 500, { error: "Google Sheets integration is not configured" });
  }

  let body: { spreadsheet_id?: unknown };
  try {
    body = await request.json();
  } catch {
    return jsonResponse(request, 400, { error: "Request body must be valid JSON" });
  }

  const spreadsheetId = typeof body.spreadsheet_id === "string"
    ? body.spreadsheet_id.trim()
    : "";
  if (!/^[A-Za-z0-9_-]{10,200}$/.test(spreadsheetId)) {
    return jsonResponse(request, 400, { error: "A valid Google spreadsheet_id is required" });
  }

  const state = randomState();
  const { error } = await supabase.from("google_oauth_states").insert({
    state_hash: await sha256Hex(state),
    user_id: userId,
    spreadsheet_id: spreadsheetId,
  });
  if (error) {
    console.error("Unable to create Google OAuth state", error);
    return jsonResponse(request, 500, { error: "Unable to start Google authorization" });
  }

  const authorizationUrl = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  authorizationUrl.search = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: "https://www.googleapis.com/auth/spreadsheets",
    access_type: "offline",
    prompt: "consent",
    state,
  }).toString();

  return jsonResponse(request, 200, { authorization_url: authorizationUrl.toString() });
});

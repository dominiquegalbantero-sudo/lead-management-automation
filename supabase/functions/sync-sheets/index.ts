import {
  createAdminClient,
  corsHeaders,
  isOptionsRequest,
  isServiceRoleRequest,
  jsonResponse,
} from "../_shared/http.ts";
import { getAccessToken, upsertSheetRow } from "../_shared/google.ts";

const supabase = createAdminClient();

Deno.serve(async (request) => {
  if (isOptionsRequest(request)) {
    return new Response(null, { status: 204, headers: corsHeaders(request) });
  }
  if (request.method !== "POST") {
    return jsonResponse(request, 405, { error: "Method not allowed" });
  }

  if (!isServiceRoleRequest(request)) {
    return jsonResponse(request, 401, { error: "Server authorization required" });
  }

  const { data: integrations, error: integrationsError } = await supabase
    .from("google_integrations")
    .select("id, user_id, spreadsheet_id, refresh_token_encrypted");
  if (integrationsError) {
    console.error("Unable to read Google Sheets integrations", integrationsError);
    return jsonResponse(request, 500, { error: "Unable to load Google Sheets integrations" });
  }
  if (!integrations?.length) {
    return jsonResponse(request, 200, {
      synced: 0,
      message: "No Google Sheets integration is connected; leads remain queued.",
    });
  }

  const accessTokens = new Map<string, string>();
  try {
    for (const integration of integrations) {
      accessTokens.set(integration.id, await getAccessToken(integration));
    }
  } catch (error) {
    console.error("Unable to refresh Google authorization", error);
    return jsonResponse(request, 502, { error: "Unable to authorize Google Sheets sync" });
  }

  const { data: leads, error: claimError } = await supabase.rpc("claim_sheet_sync", {
    p_user_id: null,
    p_limit: 100,
  });
  if (claimError) {
    console.error("Unable to claim queued sheet syncs", claimError);
    return jsonResponse(request, 500, { error: "Unable to process queued sheet syncs" });
  }

  let synced = 0;
  let failed = 0;
  for (const lead of leads ?? []) {
    try {
      for (const integration of integrations) {
        const accessToken = accessTokens.get(integration.id);
        if (!accessToken) throw new Error("Google Sheets access token was not loaded");
        await upsertSheetRow(integration.spreadsheet_id, accessToken, {
          id: lead.id,
          external_id: lead.external_id ?? "",
          name: lead.name,
          email: lead.email,
          company: lead.company,
          source: lead.source,
          stage: lead.stage,
          updated_at: lead.updated_at,
        });
      }

      const { error } = await supabase.rpc("finish_sheet_sync", {
        p_lead_id: lead.id,
        p_status: "synced",
        p_lead_updated_at: lead.updated_at,
        p_error: null,
      });
      if (error) throw error;
      synced++;
    } catch (error) {
      failed++;
      console.error(`Sheet sync failed for lead ${lead.id}`, error);
      const { error: updateError } = await supabase.rpc("finish_sheet_sync", {
        p_lead_id: lead.id,
        p_status: "failed",
        p_lead_updated_at: lead.updated_at,
        p_error: error instanceof Error ? error.message : "Unknown Google Sheets error",
      });
      if (updateError) {
        console.error(`Unable to mark sheet sync failed for lead ${lead.id}`, updateError);
      }
    }
  }

  return jsonResponse(request, failed ? 207 : 200, { synced, failed });
});

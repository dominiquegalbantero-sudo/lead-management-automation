/// <reference path="../_shared/edge-runtime.d.ts" />
import { createClient } from "npm:@supabase/supabase-js@2.117.3";
import { createLeadHandler } from "../_shared/lead-handler.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const webhookSecret = Deno.env.get("LEAD_WEBHOOK_SECRET");

if (!supabaseUrl || !serviceRoleKey) {
  throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be configured");
}

const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const handler = createLeadHandler({
  secret: webhookSecret,
  upsertLead: async (lead) => {
    const { data, error } = await supabase.rpc("upsert_lead", {
      p_external_id: lead.external_id,
      p_name: lead.name,
      p_email: lead.email,
      p_company: lead.company,
      p_source: lead.source,
    });

    if (error) {
      if (error.code === "23505") {
        throw { status: 409, message: "Lead ID and email identify different records" };
      }
      throw error;
    }

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
        if (!response.ok) {
          console.error("Lead saved, but sheet sync dispatch failed", response.status);
        }
      }).catch((error) => console.error("Lead saved, but sheet sync dispatch failed", error)),
    );

    return data;
  },
});

Deno.serve(handler);

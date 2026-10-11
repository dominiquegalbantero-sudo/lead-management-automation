import { createClient } from "npm:@supabase/supabase-js@2.117.3";

export const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
export const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

export function createAdminClient() {
  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be configured");
  }
  return createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

export function corsHeaders(request: Request) {
  const configuredOrigin = Deno.env.get("APP_ORIGIN");
  const requestOrigin = request.headers.get("origin");
  const allowedOrigin = configuredOrigin
    ? requestOrigin === configuredOrigin ? configuredOrigin : "null"
    : "*";

  return {
    "access-control-allow-origin": allowedOrigin,
    "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-max-age": "86400",
    vary: "Origin",
  };
}

export function jsonResponse(request: Request, status: number, body: unknown) {
  return Response.json(body, {
    status,
    headers: corsHeaders(request),
  });
}

export async function getAuthenticatedUserId(
  request: Request,
  supabase: ReturnType<typeof createAdminClient>,
): Promise<string | null> {
  const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) return null;
  return data.user.id;
}

export function isServiceRoleRequest(request: Request) {
  return !!serviceRoleKey &&
    request.headers.get("authorization") === `Bearer ${serviceRoleKey}`;
}

export function isOptionsRequest(request: Request) {
  return request.method === "OPTIONS";
}

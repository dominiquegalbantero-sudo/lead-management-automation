# Lead Management and Automation

Supabase stores leads and provides the signed lead-reception endpoint. Google Sheets is connected with an OAuth consent flow; refresh tokens are encrypted in the database and used to keep syncing after the initial sign-in.

## Run the Flutter app

From the project folder, run:

```powershell
flutter pub get
flutter run -d chrome --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co
```

Run the app with the Supabase project URL and **publishable** key (available in the Supabase project API settings):

```powershell
flutter run -d chrome `
  --web-port=7357 `
  --dart-define=SUPABASE_URL=https://favwmjpzxjgdovvwrhqg.supabase.co `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<your-publishable-key>
```

The app opens on **Lead API reception** if the Supabase values are omitted. With both values configured, it shows Google or email sign-in/account creation, the leads dashboard, and Google Sheets connection. The Google login signs the user into Supabase; after that, **Connect with Google** separately grants the Google Sheets access needed for synchronization. The app never reads or displays the lead webhook signing secret or Google OAuth client secret.

For email confirmation during local development, add `http://localhost:7357/**` to **Supabase → Authentication → URL Configuration → Redirect URLs**. Sign up and open the confirmation link in the same browser profile used to run the app; the confirmation returns to that app origin so Supabase can complete its PKCE flow. For a hosted app, add its exact origin (for example, `https://your-app.example.com/**`) to the same allowlist.

Google Sheets uses user-consented OAuth, not a service account. The authorization requests offline access; the callback encrypts the refresh token with AES-GCM before storing it in `google_integrations`. The server decrypts it only to exchange it for a short-lived access token during sync, so users do not need to sign in for each sync or the following day. Keep `GOOGLE_TOKEN_ENCRYPTION_KEY` stable and backed up: changing or losing it makes stored refresh tokens unusable. If the Google consent screen is External and remains in Testing, Google expires refresh tokens after 7 days for the Sheets scope; reconnect the account when that happens, or complete the applicable OAuth publishing/verification process for longer-term use.

## Deploy

1. Create a Supabase project and apply [`supabase/schema.sql`](./supabase/schema.sql) in the Supabase SQL Editor.
2. In Google Cloud, enable the Google Sheets API, configure the OAuth consent screen (add your account as a test user if the app is in testing mode), and create an OAuth client for a Web application. Add both redirect URIs to the same client:
   `https://favwmjpzxjgdovvwrhqg.supabase.co/auth/v1/callback`
   `https://favwmjpzxjgdovvwrhqg.supabase.co/functions/v1/google-callback`
3. In **Supabase → Authentication → Sign In / Providers → Google**, enable Google and enter the same OAuth client ID and client secret. This enables **Continue with Google** for dashboard login. In **Authentication → URL Configuration**, allow the app redirect (for local testing, `http://localhost:7357/**`; use your deployed app URL for production).
4. Set the following Edge Function secrets. Supabase supplies `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to functions automatically. These same Google credentials are used by the separate Sheets consent flow.

   ```powershell
   .\node_modules\.bin\supabase.cmd secrets set `
     GOOGLE_OAUTH_CLIENT_ID="<google-client-id>" `
     GOOGLE_OAUTH_CLIENT_SECRET="<google-client-secret>" `
     GOOGLE_OAUTH_REDIRECT_URI="https://favwmjpzxjgdovvwrhqg.supabase.co/functions/v1/google-callback"
   ```

   `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET` are in the Google Cloud OAuth client you created. Generate the encryption key once and set it as a Supabase secret without committing it to the repository:

   ```powershell
   $key = node -e "process.stdout.write(require('node:crypto').randomBytes(32).toString('base64'))"
   $envFile = Join-Path $env:TEMP 'google-token-key.env'
   try {
     [System.IO.File]::WriteAllText($envFile, "GOOGLE_TOKEN_ENCRYPTION_KEY=$key")
     .\node_modules\.bin\supabase.cmd secrets set --env-file $envFile
   } finally {
     Remove-Item $envFile -ErrorAction SilentlyContinue
     Remove-Item Env:GOOGLE_TOKEN_ENCRYPTION_KEY -ErrorAction SilentlyContinue
   }
   ```

   Keep a secure backup of the encryption key. It must remain unchanged to decrypt saved refresh tokens.
5. Deploy the four functions:

   ```powershell
   .\node_modules\.bin\supabase.cmd functions deploy receive-lead --use-api --no-verify-jwt
   .\node_modules\.bin\supabase.cmd functions deploy google-auth --use-api --no-verify-jwt
   .\node_modules\.bin\supabase.cmd functions deploy google-callback --use-api --no-verify-jwt
   .\node_modules\.bin\supabase.cmd functions deploy sync-sheets --use-api --no-verify-jwt
   ```

   Function JWT verification is disabled in `supabase/config.toml` because each function performs its own authorization: HMAC for inbound leads, user-token validation for OAuth setup, one-time state validation for Google's callback, and service-role validation for sync.
6. Enable the Supabase `pg_cron` and `pg_net` extensions. For immediate retries and updates made directly in the database, schedule the sync worker once per minute. Create `lead_sync_url` and `lead_sync_bearer` secrets in Supabase Vault (`lead_sync_bearer` is the project service-role key), then run:

   ```sql
   select cron.schedule(
     'sync-pending-leads-every-minute',
     '* * * * *',
     $$
     select net.http_post(
       url := (select decrypted_secret from vault.decrypted_secrets where name = 'lead_sync_url'),
       headers := jsonb_build_object(
         'content-type', 'application/json',
         'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'lead_sync_bearer'),
         'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'lead_sync_bearer')
       ),
       body := '{}'::jsonb
     );
     $$
   );
   ```

   Set `lead_sync_url` to `https://<project-ref>.supabase.co/functions/v1/sync-sheets`. New webhook leads also dispatch a sync immediately; the queue and scheduled worker cover transient failures and other database updates.

## Receive a lead

Send `POST https://<project-ref>.supabase.co/functions/v1/receive-lead` with JSON containing `id`, `name`, `email`, `company`, and `source`. Sign the exact UTF-8 request body with HMAC-SHA256 over `<unix-timestamp>.<raw-body>`. Send the timestamp in `X-Lead-Timestamp` and the lowercase digest as `X-Lead-Signature: sha256=<hex>`. Timestamps more than five minutes from server time are rejected.

Example body:

```json
{
  "id": "partner-123",
  "name": "Alex Example",
  "email": "alex@example.com",
  "company": "Example Co",
  "source": "partner-site"
}
```

Example Node.js signing logic (the same exact serialized string must be sent as the request body):

```js
const { createHmac } = require("node:crypto");
const rawBody = JSON.stringify(lead);
const timestamp = Math.floor(Date.now() / 1000).toString();
const signature = createHmac("sha256", process.env.LEAD_WEBHOOK_SECRET)
  .update(`${timestamp}.${rawBody}`, "utf8")
  .digest("hex");
```

Send that `rawBody`, with `X-Lead-Timestamp: <timestamp>` and `X-Lead-Signature: sha256=<signature>`.

The database function serializes conflicting ID/email submissions and updates the matching row. IDs and normalized emails are unique; conflicting ID and email values that refer to two different leads return `409`. Every new or updated row gets deal stage `New` only when inserted and is queued for Sheets synchronization.

## Connect Google Sheets

Sign in to the Flutter dashboard, paste the spreadsheet ID (the value between `/d/` and `/edit` in its URL), and press **Connect with Google**. The app calls `POST /functions/v1/google-auth` with the user's Supabase access token and this JSON:

```json
{ "spreadsheet_id": "<ID from the Google Sheets URL>" }
```

The app opens Google's authorization page. Sign in to Google and approve access; when you return, the app checks the connection status. The callback stores only an AES-GCM-encrypted refresh token. The token is exchanged for short-lived access tokens when syncing; it is not exposed to the client. Queue items created before the integration are picked up when the authorization completes or by the scheduled worker.

The service-only `sync-sheets` function writes columns Record ID, Partner Lead ID, Name, Email, Company, Source, Stage, and Updated At. It uses the immutable database record ID for row matching, so changing a partner ID after an email match still updates the existing sheet row.

## Tests

Run the signed endpoint and deduplication-handler tests with:

```powershell
node --test supabase\functions\_shared\*.test.mjs
```

[`supabase/tests/lead_ingestion_test.sql`](./supabase/tests/lead_ingestion_test.sql) exercises the actual database upsert, including duplicate ID submissions and updates by normalized email. Run it against a Supabase database after applying `supabase/schema.sql` with `supabase test db` (the local database requires Docker).

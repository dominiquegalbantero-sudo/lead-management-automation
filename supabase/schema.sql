
create extension if not exists pgcrypto;

create type public.deal_stage as enum (
  'New',
  'Qualified',
  'Proposal',
  'Won',
  'Lost'
);

create table public.leads (
  id uuid primary key default gen_random_uuid(),
  external_id text unique,
  name text not null,
  email text not null,
  company text not null default '',
  source text not null default '',
  stage public.deal_stage not null default 'New',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Email is case-insensitive and whitespace is ignored.
create unique index leads_email_unique
on public.leads (lower(trim(email)));

create table public.google_integrations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  spreadsheet_id text not null,
  refresh_token_encrypted text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id)
);

create table public.google_oauth_states (
  state_hash text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  spreadsheet_id text not null,
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  created_at timestamptz not null default now()
);

create index google_oauth_states_expires_at_idx
on public.google_oauth_states (expires_at);

create table public.sheet_sync_queue (
  id bigint generated always as identity primary key,
  lead_id uuid not null references public.leads(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'synced', 'failed')),
  attempts integer not null default 0,
  last_error text,
  updated_at timestamptz not null default now(),
  unique (lead_id)
);

create index sheet_sync_queue_status_updated_at_idx
on public.sheet_sync_queue (status, updated_at);

create index leads_updated_at_idx
on public.leads (updated_at desc);

alter table public.leads enable row level security;
alter table public.google_integrations enable row level security;
alter table public.google_oauth_states enable row level security;
alter table public.sheet_sync_queue enable row level security;

-- Dashboard users can read leads after signing in.
create policy "Authenticated users can read leads"
on public.leads
for select
to authenticated
using (true);

-- Dashboard users can change the deal stage.
create policy "Authenticated users can update leads"
on public.leads
for update
to authenticated
using (true)
with check (true);

revoke update on public.leads from authenticated;
grant update (stage) on public.leads to authenticated;

-- No browser policies are created for OAuth credentials or the sync queue.
-- Only trusted server-side code should access these tables.

create or replace function public.touch_lead_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger leads_touch_updated_at
before update on public.leads
for each row execute function public.touch_lead_updated_at();

create or replace function public.queue_lead_sheet_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.sheet_sync_queue (lead_id, status, attempts, last_error, updated_at)
  values (new.id, 'pending', 0, null, now())
  on conflict (lead_id)
  do update set
    status = 'pending',
    attempts = 0,
    last_error = null,
    updated_at = now();

  return new;
end;
$$;

create trigger leads_queue_sheet_sync
after insert or update on public.leads
for each row execute function public.queue_lead_sheet_sync();

create or replace function public.upsert_lead(
  p_external_id text,
  p_name text,
  p_email text,
  p_company text,
  p_source text
)
returns public.leads
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lead_by_id public.leads%rowtype;
  v_lead_by_email public.leads%rowtype;
  v_result public.leads%rowtype;
  v_lock_key text;
  v_email text := lower(trim(p_email));
begin
  for v_lock_key in
    select lock_key
    from unnest(array['email:' || v_email, 'id:' || p_external_id]) as keys(lock_key)
    order by lock_key
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_lock_key, 0));
  end loop;

  select * into v_lead_by_id
  from public.leads
  where external_id = p_external_id
  for update;

  select * into v_lead_by_email
  from public.leads
  where lower(trim(email)) = v_email
  for update;

  if v_lead_by_id.id is not null
     and v_lead_by_email.id is not null
     and v_lead_by_id.id <> v_lead_by_email.id then
    raise exception using
      errcode = '23505',
      message = 'Lead ID and email identify different records';
  elsif v_lead_by_id.id is not null then
    update public.leads
    set name = p_name,
        email = v_email,
        company = p_company,
        source = p_source,
        updated_at = now()
    where id = v_lead_by_id.id
    returning * into v_result;
  elsif v_lead_by_email.id is not null then
    update public.leads
    set external_id = p_external_id,
        name = p_name,
        email = v_email,
        company = p_company,
        source = p_source,
        updated_at = now()
    where id = v_lead_by_email.id
    returning * into v_result;
  else
    insert into public.leads (external_id, name, email, company, source)
    values (p_external_id, p_name, v_email, p_company, p_source)
    returning * into v_result;
  end if;

  return v_result;
end;
$$;

create or replace function public.claim_sheet_sync(
  p_user_id uuid default null,
  p_limit integer default 100
)
returns setof public.leads
language sql
security definer
set search_path = ''
as $$
  with due as (
    select q.lead_id
    from public.sheet_sync_queue q
    where (
      (q.status in ('pending', 'failed') and q.attempts < 8)
      or (q.status = 'processing' and q.updated_at < now() - interval '5 minutes')
    )
    and (
      p_user_id is null
      or exists (
        select 1 from public.google_integrations g
        where g.user_id = p_user_id
      )
    )
    order by q.updated_at
    for update skip locked
    limit greatest(1, least(coalesce(p_limit, 100), 100))
  ),
  claimed as (
    update public.sheet_sync_queue q
    set status = 'processing',
        attempts = q.attempts + 1,
        updated_at = now()
    from due
    where q.lead_id = due.lead_id
    returning q.lead_id
  )
  select l.*
  from public.leads l
  join claimed c on c.lead_id = l.id;
$$;

create or replace function public.finish_sheet_sync(
  p_lead_id uuid,
  p_status text,
  p_lead_updated_at timestamptz,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_status not in ('synced', 'failed') then
    raise exception 'Invalid sheet sync status';
  end if;

  update public.sheet_sync_queue
  set status = p_status,
      last_error = case when p_status = 'failed' then left(coalesce(p_error, 'Sync failed'), 1000) else null end,
      updated_at = now()
  where lead_id = p_lead_id
    and status = 'processing'
    and exists (
  select 1 from public.leads l
  where l.id = p_lead_id and l.updated_at = p_lead_updated_at
    );
end;
$$;

create or replace function public.consume_google_oauth_state(p_state_hash text)
returns table (user_id uuid, spreadsheet_id text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.google_oauth_states
  where expires_at <= now();

  return query
  delete from public.google_oauth_states s
  where s.state_hash = p_state_hash
    and s.expires_at > now()
  returning s.user_id, s.spreadsheet_id;
end;
$$;

revoke all on function public.upsert_lead(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.claim_sheet_sync(uuid, integer) from public, anon, authenticated;
revoke all on function public.finish_sheet_sync(uuid, text, timestamptz, text) from public, anon, authenticated;
revoke all on function public.consume_google_oauth_state(text) from public, anon, authenticated;
grant execute on function public.upsert_lead(text, text, text, text, text) to service_role;
grant execute on function public.claim_sheet_sync(uuid, integer) to service_role;
grant execute on function public.finish_sheet_sync(uuid, text, timestamptz, text) to service_role;
grant execute on function public.consume_google_oauth_state(text) to service_role;

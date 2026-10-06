-- THROWAWAY DATABASES ONLY. Minimal stand-ins for what Supabase provides (roles, auth schema, helpers).
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key default gen_random_uuid(), email text unique);
create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant select on auth.users to service_role;

create schema if not exists t;
grant usage on schema t to public;
create or replace function t.check(p_ok boolean, p_name text, p_info text default null) returns void language plpgsql as $$
begin
  if coalesce(p_ok, false) then raise notice 'PASS  %', p_name;
  else raise exception 'FAIL  % :: %', p_name, coalesce(p_info, ''); end if;
end $$;
-- run a statement, return 'ok' or its SQLSTATE
create or replace function t.err(q text) returns text language plpgsql as $$
begin execute q; return 'ok'; exception when others then return sqlstate; end $$;
-- run a DML statement, return affected row count (or -1 on error)
create or replace function t.rows(q text) returns int language plpgsql as $$
declare n int; begin execute q; get diagnostics n = row_count; return n; exception when others then return -1; end $$;
create or replace function t.as_user(p_uid uuid) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), false) $$;
grant execute on all functions in schema t to public;
create or replace function t.check(p_ok boolean, p_name text, p_info jsonb) returns void language sql as $$ select t.check(p_ok, p_name, p_info::text) $$;
grant execute on all functions in schema t to public;

-- Trivia Tracker: online backup for each person's games (the "sync link")
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste all of this > Run.
-- It's wrapped in begin/commit, so either every step works or nothing changes.
-- Safe to run again.
--
-- What it does:
--   1. Adds a table, trivia_backups. Each row is one person's backup: their solo games,
--      the shared games they joined, and recent player first names, stored as one JSON value.
--      The row is found by a scrambled (sha256) copy of their secret sync code. The code itself
--      is never stored, the same way invite codes and player tokens work today.
--   2. Locks the table so the app can't read or write it directly, only through the two functions.
--   3. save_trivia_backup(code, data): saves or replaces that person's backup (max about 500 KB).
--   4. load_trivia_backup(code): returns that person's backup, or null if there isn't one yet.

begin;

-- 1. Table
create table if not exists public.trivia_backups (
  code_hash  text primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);

-- 2. Lock it down: no direct access, only through the functions below
alter table public.trivia_backups enable row level security;
revoke all on table public.trivia_backups from anon, authenticated;

-- 3. Save
create or replace function public.save_trivia_backup(p_sync_code text, p_data jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
begin
  if p_sync_code is null or length(p_sync_code) < 32 or length(p_sync_code) > 128 then
    raise exception 'Invalid sync code';
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    raise exception 'Invalid backup data';
  end if;
  if pg_column_size(p_data) > 500000 then
    raise exception 'Backup is too large';
  end if;

  insert into public.trivia_backups (code_hash, data, updated_at)
  values (encode(extensions.digest(convert_to(p_sync_code, 'UTF8'), 'sha256'), 'hex'), p_data, now())
  on conflict (code_hash)
  do update set data = excluded.data, updated_at = now();

  return jsonb_build_object('success', true, 'updated_at', now());
end;
$function$;

-- 4. Load
create or replace function public.load_trivia_backup(p_sync_code text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_row public.trivia_backups%rowtype;
begin
  if p_sync_code is null or length(p_sync_code) < 32 or length(p_sync_code) > 128 then
    raise exception 'Invalid sync code';
  end if;

  select * into v_row
  from public.trivia_backups
  where code_hash = encode(extensions.digest(convert_to(p_sync_code, 'UTF8'), 'sha256'), 'hex');

  if not found then
    return jsonb_build_object('data', null);
  end if;

  return jsonb_build_object('data', v_row.data, 'updated_at', v_row.updated_at);
end;
$function$;

-- Let the app (which uses the public publishable key) call the two functions
revoke all on function public.save_trivia_backup(text, jsonb) from public;
revoke all on function public.load_trivia_backup(text) from public;
grant execute on function public.save_trivia_backup(text, jsonb) to anon, authenticated;
grant execute on function public.load_trivia_backup(text) to anon, authenticated;

commit;

-- Afterwards, this should return two rows:
-- select proname from pg_proc where proname in ('save_trivia_backup', 'load_trivia_backup');

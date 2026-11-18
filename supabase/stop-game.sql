-- Trivia Tracker: database changes for the "Stop game" button in shared games
-- Run these in Supabase: Dashboard > SQL Editor > New query.
--
-- WHY: In a shared game, when a player taps Stop the app calls a new database
-- function, stop_trivia_player. It does one of two things:
--   keep score  -> marks the player as "stopped", so everyone's scoreboard shows "Stopped"
--   throw away  -> removes that player's answers, so no one sees their partial score
-- Until this function exists, the app still works: Stop just saves or forgets the game on
-- that phone only, and other players keep seeing the partial score.
--
-- ============================================================================
-- STEP 1 (safe, read-only): show how your existing tables and functions are built.
-- Run this and send the results back to Claude, so STEP 2 can use your real
-- table and column names. Nothing is changed.
-- ============================================================================
select p.proname as function_name, pg_get_functiondef(p.oid) as definition
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like '%trivia%';

select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name like '%trivia%'
order by table_name, ordinal_position;

-- ============================================================================
-- STEP 2 (DRAFT - do not run yet): this is the shape of the change. The table and
-- column names below (trivia_players, trivia_answers, player_token, player_id,
-- stopped_at) are guesses. They'll be replaced with your real names from STEP 1.
-- ============================================================================
-- 2a. Add a "stopped at" date/time to each player. Empty means still playing.
-- alter table public.trivia_players add column if not exists stopped_at timestamptz;
--
-- 2b. The new function the app calls.
-- create or replace function public.stop_trivia_player(p_player_token text, p_keep_score boolean)
-- returns void
-- language plpgsql
-- security definer
-- set search_path = public
-- as $$
-- declare v_player_id uuid;
-- begin
--   select id into v_player_id from trivia_players where player_token = p_player_token;
--   if v_player_id is null then
--     raise exception 'Player not found';
--   end if;
--   if not p_keep_score then
--     delete from trivia_answers where player_id = v_player_id;   -- throw away their answers
--   end if;
--   update trivia_players set stopped_at = now() where id = v_player_id;
-- end;
-- $$;
--
-- 2c. Let the app (which uses the public publishable key) call it, same as your other functions.
-- revoke all on function public.stop_trivia_player(text, boolean) from public;
-- grant execute on function public.stop_trivia_player(text, boolean) to anon, authenticated;
--
-- 2d. Change get_trivia_game so each player in "players" also returns stopped_at.
--     (Needs your current get_trivia_game from STEP 1; it's a one-line addition.)
--     The app already reads players[].stopped_at and shows a "Stopped" tag when it's set.

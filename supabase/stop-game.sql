-- Trivia Tracker: database changes for the "Stop game" button in shared games
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste all of this > Run.
-- It's wrapped in begin/commit, so either every step works or nothing changes.
-- Safe to run again: each step uses "if not exists" or "create or replace".
--
-- What it does:
--   1. Adds a "stopped_at" date/time to each player (empty = still playing).
--   2. Adds a new function, stop_trivia_player, that the app calls when a player taps Stop:
--        keep score  -> marks the player stopped, so everyone's scoreboard shows "Stopped"
--        throw away  -> deletes that player's answers, then marks them stopped
--   3. Changes get_trivia_game so each player also returns stopped_at (one added line).
--   4. Changes record_trivia_answer so a stopped player can't add more answers (one added line).

begin;

-- 1. New column
alter table public.trivia_players add column if not exists stopped_at timestamptz;

-- 2. New function
create or replace function public.stop_trivia_player(p_player_token text, p_keep_score boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_player_id uuid;
begin
  if p_player_token is null or length(p_player_token) < 20 then
    raise exception 'Invalid player token';
  end if;

  select id into v_player_id
  from public.trivia_players
  where token_hash =
    encode(extensions.digest(convert_to(p_player_token, 'UTF8'), 'sha256'), 'hex');

  if v_player_id is null then
    raise exception 'Invalid player session';
  end if;

  if not coalesce(p_keep_score, true) then
    delete from public.trivia_answers where player_id = v_player_id;
  end if;

  update public.trivia_players
  set stopped_at = coalesce(stopped_at, now())
  where id = v_player_id;

  return jsonb_build_object('success', true);
end;
$function$;

revoke all on function public.stop_trivia_player(text, boolean) from public;
grant execute on function public.stop_trivia_player(text, boolean) to anon, authenticated;

-- 3. get_trivia_game: same as before, plus 'stopped_at' for each player
create or replace function public.get_trivia_game(p_invite_code text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_game_id uuid;
  v_result jsonb;
begin
  select id into v_game_id
  from public.trivia_games
  where invite_hash =
    encode(extensions.digest(convert_to(p_invite_code, 'UTF8'), 'sha256'), 'hex');

  if v_game_id is null then
    raise exception 'Game not found';
  end if;

  select jsonb_build_object(
    'game', jsonb_build_object(
      'id', g.id,
      'video_title', g.video_title,
      'total_questions', g.total_questions,
      'created_at', g.created_at,
      'status', g.status,
      'creator_player_id', g.creator_player_id
    ),
    'players', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'player_id', p.id,
          'display_name', p.display_name,
          'stopped_at', p.stopped_at,                          -- NEW
          'correct', (
            select count(*) from public.trivia_answers a
            where a.player_id = p.id and a.is_correct
          ),
          'answered', (
            select count(*) from public.trivia_answers a
            where a.player_id = p.id
          )
        ) order by p.joined_at
      )
      from public.trivia_players p
      where p.game_id = g.id
    ), '[]'::jsonb)
  )
  into v_result
  from public.trivia_games g
  where g.id = v_game_id;

  return v_result;
end;
$function$;

-- 4. record_trivia_answer: same as before, but refuses answers from a stopped player
create or replace function public.record_trivia_answer(p_player_token text, p_question_number integer, p_is_correct boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_player_id uuid;
  v_game_id uuid;
  v_total integer;
begin
  select p.id, p.game_id, g.total_questions
  into v_player_id, v_game_id, v_total
  from public.trivia_players p
  join public.trivia_games g on g.id = p.game_id
  where p.token_hash =
    encode(extensions.digest(convert_to(p_player_token, 'UTF8'), 'sha256'), 'hex')
    and g.status = 'active'
    and p.stopped_at is null;                                  -- NEW

  if v_player_id is null then
    raise exception 'Invalid player session';
  end if;

  if p_question_number < 1 or p_question_number > v_total then
    raise exception 'Invalid question number';
  end if;

  insert into public.trivia_answers
    (player_id, question_number, is_correct)
  values (v_player_id, p_question_number, p_is_correct)
  on conflict (player_id, question_number)
  do update set
    is_correct = excluded.is_correct,
    answered_at = now();

  return jsonb_build_object('success', true);
end;
$function$;

commit;

-- Afterwards, this should return one row named stop_trivia_player:
-- select proname from pg_proc where proname = 'stop_trivia_player';

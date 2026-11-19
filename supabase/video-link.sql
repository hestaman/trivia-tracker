-- Trivia Tracker: save an optional video link with each shared game
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste all of this > Run.
-- It's wrapped in begin/commit, so either every step works or nothing changes.
-- Safe to run again.
--
-- What it does:
--   1. Adds a video_url column to trivia_games. It's empty for older games.
--   2. Replaces create_trivia_game with a version that takes the link as an optional 4th value.
--      Calls that leave the link out still work the same as before.
--   3. Changes get_trivia_game so the game also returns video_url, so everyone who joins
--      can tap "Open video". Everything else in it is unchanged, including stopped_at.
-- (Solo games keep their link on the device and in your online backup, so they need no change here.)

begin;

-- 1. New column
alter table public.trivia_games add column if not exists video_url text;

-- 2. create_trivia_game with an optional video link.
-- The old 3-value version is removed first. Otherwise Supabase would have two versions
-- and couldn't tell which one to use.
drop function if exists public.create_trivia_game(text, integer, text);

create or replace function public.create_trivia_game(p_video_title text, p_total_questions integer, p_player_name text, p_video_url text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_game_id uuid;
  v_player_id uuid;
  v_code text;
  v_token text;
  v_url text := nullif(trim(coalesce(p_video_url, '')), '');
begin
  if length(trim(p_video_title)) = 0
     or length(trim(p_video_title)) > 200 then
    raise exception 'Invalid video title';
  end if;

  if p_total_questions < 1 or p_total_questions > 500 then
    raise exception 'Invalid question count';
  end if;

  if length(trim(p_player_name)) = 0
     or length(trim(p_player_name)) > 40 then
    raise exception 'Invalid player name';
  end if;

  -- NEW: the link is optional, but if given it must be a normal web link
  if v_url is not null and (length(v_url) > 500 or v_url !~* '^https?://') then
    raise exception 'Invalid video link';
  end if;

  v_code := encode(extensions.gen_random_bytes(16), 'hex');
  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into public.trivia_games
    (video_title, total_questions, invite_hash, video_url)
  values (
    trim(p_video_title),
    p_total_questions,
    encode(extensions.digest(convert_to(v_code, 'UTF8'), 'sha256'), 'hex'),
    v_url
  )
  returning id into v_game_id;

  insert into public.trivia_players
    (game_id, display_name, token_hash)
  values (
    v_game_id,
    trim(p_player_name),
    encode(extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex')
  )
  returning id into v_player_id;

  update public.trivia_games
  set creator_player_id = v_player_id
  where id = v_game_id;

  return jsonb_build_object(
    'game_id', v_game_id,
    'invite_code', v_code,
    'player_id', v_player_id,
    'player_token', v_token
  );
end;
$function$;

revoke all on function public.create_trivia_game(text, integer, text, text) from public;
grant execute on function public.create_trivia_game(text, integer, text, text) to anon, authenticated;

-- 3. get_trivia_game: same as now, plus 'video_url' for the game
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
      'video_url', g.video_url,                                -- NEW
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
          'stopped_at', p.stopped_at,
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

commit;

-- Afterwards, this should return one row ending in "p_video_url text DEFAULT NULL::text":
-- select pg_get_function_arguments(oid) from pg_proc where proname = 'create_trivia_game';

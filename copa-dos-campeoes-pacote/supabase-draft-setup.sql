-- Copa dos Campeões 2026 — Draft online
-- Migração aditiva: não apaga tabelas, clubes, elencos nem histórico existente.
-- Execute no SQL Editor do projeto Supabase já usado pelo site.

create table if not exists public.draft_sessions (
  id integer primary key default 1 check (id = 1),
  status text not null default 'paused' check (status in ('paused','active','finished')),
  team_order text[] not null default '{}',
  player_pool jsonb not null default '[]'::jsonb check (jsonb_typeof(player_pool) = 'array'),
  current_pick integer not null default 0 check (current_pick >= 0),
  picks_per_team integer not null default 17 check (picks_per_team between 1 and 17),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  turn_started_at timestamptz not null default now(),
  turn_duration_seconds integer not null default 10800 check (turn_duration_seconds = 10800)
);

-- Safe upgrade if the table was created by an earlier draft prototype.
alter table public.draft_sessions add column if not exists turn_started_at timestamptz not null default now();
alter table public.draft_sessions add column if not exists turn_duration_seconds integer not null default 10800;
alter table public.draft_sessions alter column picks_per_team set default 17;

create table if not exists public.draft_picks (
  id bigint generated always as identity primary key,
  pick_number integer not null unique,
  club_id text not null,
  player_id text not null,
  player_name text not null,
  position text,
  overall integer,
  picked_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (player_id)
);

alter table public.draft_sessions enable row level security;
alter table public.draft_picks enable row level security;

drop policy if exists "active users can read draft session" on public.draft_sessions;
create policy "active users can read draft session"
  on public.draft_sessions for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.status = 'active'));

drop policy if exists "admins manage draft session" on public.draft_sessions;
create policy "admins manage draft session"
  on public.draft_sessions for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.status = 'active' and p.role = 'admin'))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.status = 'active' and p.role = 'admin'));

drop policy if exists "active users can read draft picks" on public.draft_picks;
create policy "active users can read draft picks"
  on public.draft_picks for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.status = 'active'));

-- Server-side turn synchronization. The server clock controls the three-hour deadline.
-- Serpentine order: A-B-C... then ...C-B-A, repeated until clubs reach 17 picks.
create or replace function public.draft_sync_turn()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile record;
  v_session public.draft_sessions%rowtype;
  v_n integer;
  v_round integer;
  v_offset integer;
  v_index integer;
  v_club text;
  v_club_picks integer;
  v_loops integer := 0;
  v_deadline timestamptz;
begin
  if v_user_id is null then raise exception 'Você precisa entrar na sua conta.'; end if;
  select role, status into v_profile from public.profiles where id = v_user_id;
  if not found or v_profile.status <> 'active' then raise exception 'A conta precisa estar ativa.'; end if;

  select * into v_session from public.draft_sessions where id = 1 for update;
  if not found then return jsonb_build_object('status','unconfigured'); end if;
  v_n := cardinality(v_session.team_order);
  if v_session.status <> 'active' or v_n < 2 then
    return jsonb_build_object('status',v_session.status,'current_pick',v_session.current_pick);
  end if;

  loop
    v_loops := v_loops + 1;
    if v_loops > v_n * 18 then
      update public.draft_sessions set status = 'finished', updated_at = now() where id = 1;
      return jsonb_build_object('status','finished','reason','all_clubs_completed');
    end if;

    v_round := floor(v_session.current_pick::numeric / v_n)::integer;
    v_offset := v_session.current_pick % v_n;
    v_index := case when v_round % 2 = 0 then v_offset else v_n - 1 - v_offset end;
    v_club := v_session.team_order[v_index + 1];
    select count(*) into v_club_picks from public.draft_picks where club_id = v_club;
    v_deadline := v_session.turn_started_at + make_interval(secs => v_session.turn_duration_seconds);

    if v_club_picks >= v_session.picks_per_team then
      v_session.current_pick := v_session.current_pick + 1;
      v_session.turn_started_at := now();
      update public.draft_sessions set current_pick = v_session.current_pick, turn_started_at = v_session.turn_started_at, updated_at = now() where id = 1;
      continue;
    end if;

    if now() >= v_deadline then
      v_session.current_pick := v_session.current_pick + 1;
      v_session.turn_started_at := now();
      update public.draft_sessions set current_pick = v_session.current_pick, turn_started_at = v_session.turn_started_at, updated_at = now() where id = 1;
      continue;
    end if;
    exit;
  end loop;

  return jsonb_build_object('status',v_session.status,'current_pick',v_session.current_pick,'club_id',v_club,'turn_started_at',v_session.turn_started_at,'deadline',v_deadline);
end;
$$;

-- All picks are atomic: verifies active account, linked club, snake order, 3-hour deadline,
-- duplicate player and 17-player limit. A pick is stored in the shared online squad/history.
create or replace function public.draft_pick_player(p_player_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_profile record;
  v_session public.draft_sessions%rowtype;
  v_n integer;
  v_round integer;
  v_offset integer;
  v_index integer;
  v_club_id text;
  v_expected_club text;
  v_player jsonb;
  v_team_picks integer;
  v_deadline timestamptz;
  v_pick_number integer;
begin
  if v_user_id is null then raise exception 'Você precisa entrar na sua conta.'; end if;
  select id, role, status, club_id into v_profile from public.profiles where id = v_user_id;
  if not found or v_profile.status <> 'active' then raise exception 'A conta precisa estar ativa.'; end if;
  if v_profile.club_id is null then raise exception 'Sua conta ainda não tem um clube vinculado.'; end if;
  v_club_id := v_profile.club_id::text;

  -- Advance an expired turn before validating the pick.
  perform public.draft_sync_turn();
  select * into v_session from public.draft_sessions where id = 1 for update;
  if not found then raise exception 'O administrador ainda não configurou o draft.'; end if;
  if v_session.status <> 'active' then raise exception 'O draft não está ativo.'; end if;
  v_n := cardinality(v_session.team_order);
  if v_n < 2 then raise exception 'A ordem dos clubes não foi configurada.'; end if;

  v_round := floor(v_session.current_pick::numeric / v_n)::integer;
  v_offset := v_session.current_pick % v_n;
  v_index := case when v_round % 2 = 0 then v_offset else v_n - 1 - v_offset end;
  v_expected_club := v_session.team_order[v_index + 1];
  if v_club_id <> v_expected_club then raise exception 'Ainda não é a vez do seu clube.'; end if;

  v_deadline := v_session.turn_started_at + make_interval(secs => v_session.turn_duration_seconds);
  if now() >= v_deadline then raise exception 'O prazo expirou. O turno seguinte está sendo sincronizado; atualize a tela.'; end if;

  select count(*) into v_team_picks from public.draft_picks where club_id = v_club_id;
  if v_team_picks >= 17 then raise exception 'Seu clube já completou as 17 escolhas.'; end if;
  select elem into v_player from jsonb_array_elements(v_session.player_pool) as item(elem) where item.elem->>'id' = p_player_id;
  if v_player is null then raise exception 'Jogador não encontrado na lista do draft.'; end if;
  if exists (select 1 from public.draft_picks where player_id = p_player_id) then raise exception 'Esse jogador já foi escolhido.'; end if;

  v_pick_number := v_session.current_pick + 1;
  insert into public.draft_picks(pick_number, club_id, player_id, player_name, position, overall, picked_by)
  values (v_pick_number, v_club_id, p_player_id, coalesce(v_player->>'name','Jogador'), v_player->>'position',
    case when coalesce(v_player->>'overall','') ~ '^\d+$' then (v_player->>'overall')::integer else null end, v_user_id);

  update public.draft_sessions set current_pick = current_pick + 1, turn_started_at = now(), updated_at = now() where id = 1;
  select count(*) into v_team_picks from public.draft_picks where club_id = v_club_id;
  if v_team_picks >= 17 then
    -- next call skips a completed club automatically; status becomes finished when all are complete.
    perform public.draft_sync_turn();
  end if;

  return jsonb_build_object('success',true,'pick_number',v_pick_number,'player_id',p_player_id,'player_name',v_player->>'name','club_id',v_club_id);
end;
$$;

revoke all on function public.draft_pick_player(text) from public;
revoke all on function public.draft_sync_turn() from public;
grant execute on function public.draft_pick_player(text) to authenticated;
grant execute on function public.draft_sync_turn() to authenticated;
grant select on public.draft_sessions, public.draft_picks to authenticated;
grant insert, update, delete on public.draft_sessions to authenticated;

insert into public.draft_sessions (id, status, team_order, player_pool, current_pick, picks_per_team, turn_started_at, turn_duration_seconds)
values (1, 'paused', '{}', '[]'::jsonb, 0, 17, now(), 10800)
on conflict (id) do nothing;

-- Para localizar os IDs reais dos clubes, execute:
-- select id, name from public.clubs order by name;

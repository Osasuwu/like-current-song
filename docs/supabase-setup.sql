-- Like Current Song — Supabase schema for the cross-device like counter
-- and per-artist track tracking.
--
-- Fully idempotent: safe on fresh projects and on existing ones being
-- upgraded for #24 (backfill) / #26 (artist follow). Run in the Supabase SQL Editor.

-- ── Table ───────────────────────────────────────────────────────────
create table if not exists public.track_likes (
    user_id    text not null,
    track_id   text not null,
    count      integer not null default 0,
    -- #24: marks rows where the first encounter found the track already in
    -- Spotify's Liked Songs (we treat that first encounter as count=2).
    -- Older rows keep the default `false` — no retroactive backfill.
    backfilled boolean not null default false,
    updated_at timestamptz not null default now(),
    primary key (user_id, track_id)
);

alter table public.track_likes
    add column if not exists backfilled boolean not null default false;

-- ── RPC ────────────────────────────────────────────────────────────
-- p_was_already_liked is the Spotify "already in Liked Songs" signal.
--   row absent → INSERT count = 2 if true else 1; backfilled mirrors flag.
--   row present → UPDATE count = count + 1; backfilled untouched.
create or replace function public.increment_track_like(
    p_user_id            text,
    p_track_id           text,
    p_was_already_liked  boolean default false
)
returns integer
language plpgsql
as $$
declare
    new_count integer;
begin
    insert into public.track_likes (user_id, track_id, count, backfilled, updated_at)
    values (
        p_user_id,
        p_track_id,
        case when p_was_already_liked then 2 else 1 end,
        p_was_already_liked,
        now()
    )
    on conflict (user_id, track_id) do update
        set count      = public.track_likes.count + 1,
            updated_at = now()
    returning count into new_count;

    return new_count;
end;
$$;


-- ── #26: per-artist track tracking ─────────────────────────────────
-- One row per (user, artist, track) that the user has liked. Used by
-- FollowArtistAction to count distinct tracks per artist and trigger
-- auto-follow when the user crosses a configured threshold.
create table if not exists public.artist_track_likes (
    user_id   text not null,
    artist_id text not null,
    track_id  text not null,
    created_at timestamptz not null default now(),
    primary key (user_id, artist_id, track_id)
);

-- Idempotent UPSERT + count. Re-recording the same (user, artist, track)
-- triple returns the same count as before — that's the contract.
create or replace function public.record_artist_track(
    p_user_id   text,
    p_artist_id text,
    p_track_id  text
)
returns integer
language plpgsql
as $$
declare
    new_count integer;
begin
    insert into public.artist_track_likes (user_id, artist_id, track_id)
    values (p_user_id, p_artist_id, p_track_id)
    on conflict (user_id, artist_id, track_id) do nothing;

    select count(*) into new_count
    from public.artist_track_likes
    where user_id = p_user_id and artist_id = p_artist_id;

    return new_count;
end;
$$;

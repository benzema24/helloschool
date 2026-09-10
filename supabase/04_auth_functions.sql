-- Hello Academy — sign-in and invitations
-- Run after 02_policies.sql.
--
-- Two rules live here:
--   1. Nobody signs themselves up. The school issues the invitation.
--   2. The school never learns a guardian's credentials, so the office cannot
--      sign in as a parent and read a child's medical file.

-- ── invitation codes ──────────────────────────────────────────────────────
-- Generated in the database, so the code is never derivable from anything the
-- browser knows. The alphabet leaves out O/0 and I/1, which people misread off
-- a printed slip and then phone the office about.
create or replace function generate_invite_code() returns text
language plpgsql volatile as $$
declare
  ab text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  out text := '';
  i int;
begin
  for i in 1..6 loop
    out := out || substr(ab, 1 + floor(random() * length(ab))::int, 1);
  end loop;
  return substr(out,1,3) || '-' || substr(out,4,3);
end $$;

create or replace function issue_invitation(p_guardian_id uuid, p_days int default 7)
returns invitation
language plpgsql security definer set search_path = public as $$
declare
  g guardian;
  inv invitation;
begin
  if not is_admin() then
    raise exception 'only the administration issues invitations';
  end if;

  select * into g from guardian where id = p_guardian_id;
  if g is null or g.school_id <> my_school() then
    raise exception 'no such guardian in this school';
  end if;

  insert into invitation (school_id, guardian_id, email, phone, code, expires_at, created_by)
  values (g.school_id, g.id, g.email, g.phone, generate_invite_code(),
          now() + make_interval(days => p_days), auth.uid())
  on conflict (guardian_id) where guardian_id is not null
  do update set code = generate_invite_code(),
                expires_at = now() + make_interval(days => p_days),
                sent_at = now(), used_at = null, created_by = auth.uid()
  returning * into inv;

  insert into audit_log (school_id, actor_user_id, action, detail)
  values (g.school_id, auth.uid(), 'invite.issue', g.name);

  return inv;
end $$;

-- ── first sign-in ─────────────────────────────────────────────────────────
-- Called once the one-time code has been verified by Supabase Auth. It only
-- stamps the caller's own row, so it cannot be used to fake someone else's.
create or replace function mark_guardian_joined() returns void
language plpgsql security definer set search_path = public as $$
begin
  update guardian set joined_at = coalesce(joined_at, now())
   where user_id = auth.uid();

  update invitation set used_at = coalesce(used_at, now())
   where guardian_id in (select id from guardian where user_id = auth.uid());
end $$;

grant execute on function issue_invitation(uuid, int) to authenticated;
grant execute on function mark_guardian_joined() to authenticated;
grant execute on function lesson_for_guardian(uuid) to authenticated;

-- ── notes that belong next to this, not in the code ───────────────────────
--
-- Email one-time codes are free and are the default path. SMS costs per
-- message and needs a provider configured in Supabase Auth; keep it for the
-- guardians who do not use email rather than as the main route.
--
-- Set the code lifetime and rate limits in Supabase Auth settings. Ten minutes
-- and a handful of attempts per hour is a reasonable starting point: long
-- enough for a parent to find the message, short enough that a code read over
-- someone's shoulder is worthless by the time it is used.
--
-- Staff sign in with a password. Turn on MFA for the admin role — that account
-- can read the medical information and contact details of every child in the
-- school, and is the one worth protecting hardest.
--
-- Changing a guardian's email or phone is an administration action, never a
-- self-service one: changing the address is taking over the account.

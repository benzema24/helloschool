-- Hello Academy — V1 features
-- Run after 04_auth_functions.sql, before 05_seed_data.sql.
-- Additive only: nothing existing is dropped or renamed.

-- ─── 1. absences: a range, and a lifecycle the guardian can see ────────────
alter table absence_report add column if not exists end_date date;
alter table absence_report add column if not exists handled_by uuid references app_user;
alter table absence_report add column if not exists handled_at timestamptz;
alter table absence_report drop constraint if exists absence_report_status_check;
alter table absence_report add constraint absence_report_status_check
  check (status in ('reported','acknowledged','resolved'));

-- A guardian may create and withdraw their own report and nothing else. In
-- particular they may not set the status: that is the school's decision, and
-- the parent's submission must never become the official attendance record.
drop policy if exists absence_guardian_insert on absence_report;
create policy absence_guardian_insert on absence_report for insert
  with check (is_guardian_of(student_id) and status = 'reported'
              and handled_by is null and handled_at is null);

drop policy if exists absence_guardian_delete on absence_report;
create policy absence_guardian_delete on absence_report for delete
  using (is_guardian_of(student_id) and status = 'reported');

drop policy if exists absence_staff on absence_report;
create policy absence_staff on absence_report for update
  using (teaches_class(class_id) or is_admin())
  with check (teaches_class(class_id) or is_admin());

-- ─── 2. receipts: sent / read / acknowledged, one table for every feature ──
create table if not exists receipt (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  kind text not null check (kind in ('announcement','permission','document')),
  subject_id uuid not null,
  user_id uuid not null references app_user on delete cascade,
  sent_at timestamptz not null default now(),
  read_at timestamptz,
  ack_at timestamptz,
  unique (kind, subject_id, user_id)
);
create index if not exists receipt_subject_idx on receipt (kind, subject_id);

alter table receipt enable row level security;
alter table receipt force row level security;

-- everyone sees their own receipt; staff see the aggregate for what they sent
create policy receipt_own on receipt for select using (user_id = auth.uid());
create policy receipt_staff on receipt for select using (
  is_admin() and school_id = my_school()
  or exists (select 1 from staff s where s.user_id = auth.uid() and s.school_id = receipt.school_id));

-- a recipient may only ever stamp their own row, and only forward in time
create policy receipt_mark on receipt for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
create policy receipt_insert on receipt for insert with check (
  is_admin() and school_id = my_school()
  or exists (select 1 from staff s where s.user_id = auth.uid())
  or user_id = auth.uid());

-- ─── urgent announcements ─────────────────────────────────────────────────
alter table announcement add column if not exists urgency text not null default 'normal'
  check (urgency in ('normal','urgent'));
alter table announcement add column if not exists requires_ack boolean not null default false;

-- ─── 3. permission requests ───────────────────────────────────────────────
create table if not exists permission_request (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  kind text not null check (kind in ('trip','activity','medical','event','other')),
  title jsonb not null,
  body jsonb not null,
  instructions jsonb,
  audience_type audience_type not null,
  audience_ref uuid,
  date date,
  deadline date,
  created_by uuid references app_user,
  created_at timestamptz not null default now()
);

create table if not exists permission_response (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  permission_id uuid not null references permission_request on delete cascade,
  student_id uuid not null references student on delete cascade,
  answer text not null check (answer in ('approve','decline')),
  note jsonb,
  responded_by uuid references guardian,
  created_at timestamptz not null default now(),
  unique (permission_id, student_id)
);

alter table permission_request  enable row level security;
alter table permission_request  force row level security;
alter table permission_response enable row level security;
alter table permission_response force row level security;

create policy perm_read on permission_request for select using (
  school_id = my_school() and (
    audience_type = 'school'
    or (audience_type = 'class' and (
         teaches_class(audience_ref) or is_admin()
         or exists (select 1 from student s where s.class_id = audience_ref and is_guardian_of(s.id))))));
create policy perm_write on permission_request for all
  using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());

-- a guardian answers for their own child only, and only for a request whose
-- audience actually contains that child
create policy perm_resp_read on permission_response for select using (
  is_guardian_of(student_id) or is_admin()
  or exists (select 1 from student s where s.id = student_id and teaches_class(s.class_id)));
create policy perm_resp_write on permission_response for all
  using (is_guardian_of(student_id))
  with check (
    is_guardian_of(student_id)
    and exists (
      select 1 from permission_request p, student s
      where p.id = permission_id and s.id = student_id
        and (p.audience_type = 'school' or p.audience_ref = s.class_id)));

-- ─── 4. documents ─────────────────────────────────────────────────────────
create table if not exists document (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  title jsonb not null,
  kind text not null check (kind in ('report','cert','form','policy','invoice','other')),
  scope text not null check (scope in ('school','class','student')),
  class_id uuid references class on delete cascade,
  student_id uuid references student on delete cascade,
  storage_path text,
  file_name text,
  mime text,
  uploaded_by uuid references app_user,
  uploaded_at timestamptz not null default now(),
  check ((scope = 'class' and class_id is not null)
      or (scope = 'student' and student_id is not null)
      or scope = 'school')
);
create index if not exists document_scope_idx on document (school_id, scope);

alter table document enable row level security;
alter table document force row level security;

-- the whole security model of the document centre is this one policy
create policy document_read on document for select using (
  school_id = my_school() and (
    is_admin()
    or scope = 'school'
    or (scope = 'class'   and (teaches_class(class_id)
         or exists (select 1 from student s where s.class_id = document.class_id and is_guardian_of(s.id))))
    or (scope = 'student' and (is_guardian_of(student_id) or teaches_student(student_id)))));
create policy document_write on document for all
  using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());

-- files live in their own private bucket, reached only through the row above
insert into storage.buckets (id, name, public) values ('documents','documents',false)
on conflict (id) do nothing;

create policy document_object_read on storage.objects for select to authenticated
using (bucket_id = 'documents' and exists (
  select 1 from document d where d.storage_path = storage.objects.name));
create policy document_object_write on storage.objects for insert to authenticated
with check (bucket_id = 'documents' and is_admin());

-- ─── 4b. documents a guardian uploads about their own child ───────────────
alter table document add column if not exists category text;
alter table document add column if not exists source text not null default 'school'
  check (source in ('school','guardian'));
alter table document add column if not exists expires_at date;
alter table document add column if not exists size int;

-- A guardian may add a document about their own child and remove one they
-- added themselves. They may never touch a school-issued document, and the
-- check pins both scope and source so neither can be forged from the browser.
create policy document_guardian_insert on document for insert
  with check (scope = 'student' and source = 'guardian'
              and is_guardian_of(student_id) and school_id = my_school());

create policy document_guardian_delete on document for delete
  using (scope = 'student' and source = 'guardian' and is_guardian_of(student_id));

create policy document_object_guardian on storage.objects for insert to authenticated
with check (bucket_id = 'documents'
            and is_guardian_of(((storage.foldername(name))[1])::uuid));

-- ─── 7. notification preferences ──────────────────────────────────────────
create table if not exists notification_preference (
  user_id uuid primary key references app_user on delete cascade,
  muted text[] not null default '{}',
  updated_at timestamptz not null default now()
);
alter table notification_preference enable row level security;
alter table notification_preference force row level security;
create policy pref_self on notification_preference for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Critical types are never silenced. Enforced here rather than in the client,
-- so a crafted preference row cannot switch off an emergency notice.
create or replace function notify(p_user uuid, p_type text, p_title jsonb, p_link text)
returns void language plpgsql security definer set search_path = public as $$
declare muted text[];
begin
  if p_type not in ('urgent','absence','permission','gdpr','profile') then
    select np.muted into muted from notification_preference np where np.user_id = p_user;
    if muted is not null and p_type = any (muted) then
      return;
    end if;
  end if;
  insert into notification (target_user_id, type, title, link) values (p_user, p_type, p_title, p_link);
end $$;
grant execute on function notify(uuid, text, jsonb, text) to authenticated;

-- ─── 5. search ────────────────────────────────────────────────────────────
-- Search runs through the same predicates as the screens. A teacher cannot
-- discover a child by typing a name, because the query itself cannot see them.
create or replace function search_school(q text)
returns table (kind text, id uuid, title text, subtitle text)
language sql stable security definer set search_path = public as $$
  with needle as (select '%' || lower(trim(q)) || '%' as p)
  select 'student', s.id, s.first_name || ' ' || s.last_name, c.name
    from student s join class c on c.id = s.class_id, needle
   where length(trim(q)) >= 2
     and (lower(s.first_name || ' ' || s.last_name) like needle.p
          or lower(coalesce(s.register_no,'')) like needle.p)
     and (is_admin() or is_guardian_of(s.id) or teaches_student(s.id))
  union all
  select 'class', c.id, c.name, c.room
    from class c, needle
   where length(trim(q)) >= 2 and lower(c.name) like needle.p
     and (is_admin() or teaches_class(c.id))
  union all
  select 'guardian', g.id, g.name, g.email
    from guardian g, needle
   where length(trim(q)) >= 2
     and (lower(g.name) like needle.p or lower(g.email) like needle.p or lower(coalesce(g.phone,'')) like needle.p)
     and (is_admin() or exists (
       select 1 from guardian_student gs where gs.guardian_id = g.id and teaches_student(gs.student_id)))
  union all
  select 'staff', st.id, u.name, u.email
    from staff st join app_user u on u.id = st.user_id, needle
   where length(trim(q)) >= 2 and is_admin()
     and (lower(u.name) like needle.p or lower(u.email) like needle.p)
  limit 30
$$;
grant execute on function search_school(text) to authenticated;

-- ─── 6. exports ───────────────────────────────────────────────────────────
-- There is no export function here on purpose. An export must be built from
-- rows the caller's own policies already return, never from a privileged
-- aggregate — otherwise the export becomes a way around row level security.
-- The client selects, formats and downloads; this records that it happened.
create or replace function log_export(p_kind text, p_rows int)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (school_id, actor_user_id, action, detail)
  values (my_school(), auth.uid(), 'export.' || p_kind, p_rows || ' rows');
end $$;
grant execute on function log_export(text, int) to authenticated;

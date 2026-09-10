-- Hello Academy — schema
-- Run this first, then 02_policies.sql, then 03_storage.sql.
-- Everything is scoped by school_id so a second school can be added without a rewrite.

create extension if not exists "pgcrypto";

-- ─── enums ────────────────────────────────────────────────────────────────
create type user_role        as enum ('parent','teacher','admin','super_admin');
create type class_stage      as enum ('early','primary');
create type attendance_state as enum ('present','absent','late','excused');
create type meal_type        as enum ('breakfast','snack_am','lunch','snack_pm');
create type consumption      as enum ('none','little','half','most','all');
create type assessment_type  as enum ('quiz','hw','exam','project','participation');
create type media_type       as enum ('image','video','illustration');
create type absence_reason   as enum ('illness','doctor','family','other');
create type audience_type    as enum ('school','grade_level','class','role');

-- ─── tenancy and identity ─────────────────────────────────────────────────
create table school (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  short_name text,
  city text, country text, address text, phone text, email text,
  locale text not null default 'sq',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table school_year (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  name text not null, start_date date not null, end_date date not null,
  active boolean not null default false
);

create table term (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  year_id uuid not null references school_year on delete cascade,
  name jsonb not null, start_date date not null, end_date date not null,
  current boolean not null default false
);

-- app_user.id matches auth.users.id: identity comes from Supabase Auth
create table app_user (
  id uuid primary key references auth.users on delete cascade,
  school_id uuid not null references school on delete cascade,
  name text not null, email text not null,
  role user_role not null,
  photo_url text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index on app_user (school_id, role);

create table guardian (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_user on delete cascade,
  school_id uuid not null references school on delete cascade,
  name text not null, email text not null, phone text,
  photo_url text,
  joined_at timestamptz,                -- first successful sign-in
  created_at timestamptz not null default now()
);

-- the school issues an invitation; nobody signs themselves up
create table invitation (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  guardian_id uuid references guardian on delete cascade,
  staff_id uuid references staff on delete cascade,
  email text, phone text,
  code text not null,
  sent_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  created_by uuid references app_user,
  check (guardian_id is not null or staff_id is not null)
);
create index on invitation (school_id, expires_at);
create unique index on invitation (guardian_id) where guardian_id is not null;

create table staff (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_user on delete cascade,
  school_id uuid not null references school on delete cascade,
  title jsonb not null,                 -- {"sq":"Edukatore","en":"Educator"}
  stage class_stage,                    -- 'early' for edukatore
  phone text, photo_url text,
  created_at timestamptz not null default now()
);

-- ─── structure ────────────────────────────────────────────────────────────
create table grade_level (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  key text not null, name jsonb not null, ordinal int not null,
  stage class_stage not null,
  -- lower grades are assessed descriptively, higher ones with a mark
  assessment text not null default 'numeric'
    check (assessment in ('none','descriptive','numeric')),
  unique (school_id, key)
);

-- the column groups of the paper register
create table curricular_area (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  key text not null, name jsonb not null, ordinal int not null,
  unique (school_id, key)
);

create table class (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  year_id uuid not null references school_year on delete cascade,
  grade_level_id uuid not null references grade_level,
  name text not null, short_name text, room text,
  age_label jsonb,                      -- kindergarten groups: {"sq":"5–6 vjeç"}
  homeroom_staff_id uuid references staff,
  stage class_stage not null,
  start_time time, end_time time,
  created_at timestamptz not null default now()
);
create index on class (school_id, year_id);

create table subject (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  key text not null, name jsonb not null, icon text,
  area_id uuid references curricular_area,
  ordinal int not null default 1,
  active boolean not null default true,
  unique (school_id, key)
);

create table staff_class (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff on delete cascade,
  class_id uuid not null references class on delete cascade,
  role text not null check (role in ('homeroom','subject','assistant')),
  subject_id uuid references subject,
  unique (staff_id, class_id, subject_id)
);
create index on staff_class (class_id);

-- which subjects a class actually takes: the school maintains this, and the
-- register columns follow it
create table class_subject (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references class on delete cascade,
  subject_id uuid not null references subject on delete cascade,
  ordinal int not null default 1,
  staff_id uuid references staff,
  unique (class_id, subject_id)
);

create table student (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  year_id uuid not null references school_year on delete cascade,
  class_id uuid not null references class,
  first_name text not null, last_name text not null,
  dob date not null, gender text,
  register_no text,                     -- numri amë, as in the paper register
  bus_morning uuid references bus_stop on delete set null,
  bus_afternoon uuid references bus_stop on delete set null,
  photo_url text,
  photo_consent boolean not null default false,
  photo_consent_at timestamptz,
  profile_confirmed_at timestamptz,
  enrolled_on date not null default current_date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on student (class_id);

create table guardian_student (
  id uuid primary key default gen_random_uuid(),
  guardian_id uuid not null references guardian on delete cascade,
  student_id uuid not null references student on delete cascade,
  relation jsonb, is_primary boolean default false,
  can_pickup boolean default true, emergency_order int default 1,
  unique (guardian_id, student_id)
);
create index on guardian_student (student_id);

create table period (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  class_id uuid not null references class on delete cascade,
  day int not null check (day between 1 and 7),
  ordinal int not null,
  start_time time not null, end_time time not null,
  subject_id uuid not null references subject,
  staff_id uuid references staff,
  room text,
  unique (class_id, day, ordinal)
);

-- ─── the daily record ─────────────────────────────────────────────────────
create table attendance (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  student_id uuid not null references student on delete cascade,
  class_id uuid not null references class,
  date date not null,
  status attendance_state not null,
  time time, note jsonb,
  recorded_by uuid references staff,
  created_at timestamptz not null default now(),
  unique (student_id, date)
);
create index on attendance (class_id, date);

create table absence_report (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  student_id uuid not null references student on delete cascade,
  class_id uuid not null references class,
  date date not null,
  reason absence_reason not null,
  note jsonb,
  reported_by uuid references guardian,
  status text not null default 'reported',
  created_at timestamptz not null default now(),
  unique (student_id, date)
);

create table meal (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  student_id uuid not null references student on delete cascade,
  class_id uuid not null references class,
  date date not null, type meal_type not null,
  consumption consumption not null, menu jsonb, time time,
  recorded_by uuid references staff,
  unique (student_id, date, type)
);

create table weekly_menu (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  week_start date not null,
  days jsonb not null,                  -- [{date, breakfast, snack_am, lunch, snack_pm}]
  published_at timestamptz, published_by uuid references app_user,
  unique (school_id, week_start)
);

create table activity (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  class_id uuid not null references class on delete cascade,
  date date not null, time time, category text,
  name jsonb not null, description jsonb,
  student_ids uuid[] not null default '{}',
  participation jsonb not null default '{}',
  recorded_by uuid references staff,
  created_at timestamptz not null default now()
);
create index on activity (class_id, date);

create table nap (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references student on delete cascade,
  date date not null, start_time time, minutes int,
  recorded_by uuid references staff,
  unique (student_id, date)
);

create table mood_entry (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references student on delete cascade,
  date date not null, time time, mood text not null,
  recorded_by uuid references staff
);

create table staff_note (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references student on delete cascade,
  class_id uuid not null references class,
  date date not null, text jsonb not null,
  author_id uuid references staff,
  visibility text not null default 'guardians',
  created_at timestamptz not null default now()
);

create table daily_report (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references student on delete cascade,
  class_id uuid not null references class,
  date date not null,
  published boolean not null default false,
  published_at timestamptz, published_by uuid references staff,
  unique (student_id, date)
);

create table media (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  class_id uuid not null references class on delete cascade,
  activity_id uuid references activity on delete set null,
  date date not null,
  type media_type not null default 'image',
  storage_path text,                    -- object key in the private bucket
  kind text, caption jsonb,
  student_ids uuid[] not null default '{}',
  author_id uuid references staff,
  created_at timestamptz not null default now()
);
create index on media (class_id, date);

-- the class register: one row per lesson taught
create table lesson (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  class_id uuid not null references class on delete cascade,
  date date not null,
  period_id uuid references period,
  ordinal int not null,
  subject_id uuid not null references subject,
  staff_id uuid references staff,
  topic jsonb not null,                 -- njësia mësuese
  note jsonb, homework jsonb,
  absent_ids uuid[] not null default '{}',
  -- [{student_id, text}] — a remark is private to that child's guardian
  remarks jsonb not null default '[]',
  recorded_by uuid references staff,
  recorded_at timestamptz,
  unique (class_id, date, ordinal)
);
create index on lesson (class_id, date);

-- ─── academic record ──────────────────────────────────────────────────────
create table grade (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  student_id uuid not null references student on delete cascade,
  class_id uuid not null references class,
  subject_id uuid not null references subject,
  term_id uuid references term,
  type assessment_type not null,
  value numeric(3,1) not null, max numeric(3,1) not null default 5,
  comment jsonb, date date not null,
  staff_id uuid references staff,
  created_at timestamptz not null default now()
);
create index on grade (student_id, subject_id, date);

-- the success matrix: one mark per student, subject and term
create table term_grade (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  student_id uuid not null references student on delete cascade,
  class_id uuid not null references class,
  subject_id uuid not null references subject,
  term_id uuid not null references term,
  value numeric(3,1) not null,
  recorded_by uuid references staff,
  created_at timestamptz not null default now(),
  unique (student_id, subject_id, term_id)
);

create table conduct (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references student on delete cascade,
  term_id uuid not null references term,
  value text not null,
  unique (student_id, term_id)
);

create table homework (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  class_id uuid not null references class on delete cascade,
  subject_id uuid references subject,
  title jsonb not null, description jsonb,
  assigned_date date not null, due_date date not null,
  staff_id uuid references staff,
  created_at timestamptz not null default now()
);

create table homework_status (
  id uuid primary key default gen_random_uuid(),
  homework_id uuid not null references homework on delete cascade,
  student_id uuid not null references student on delete cascade,
  status text not null default 'pending',
  updated_at timestamptz not null default now(),
  unique (homework_id, student_id)
);

-- ─── sensitive: separate table, narrower policy ───────────────────────────
create table medical_information (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references student on delete cascade unique,
  allergies text[] not null default '{}',
  allergies_answered boolean not null default false,
  food_restrictions text[] not null default '{}',
  medications text, clinic text,
  notes jsonb, doctor text, doctor_phone text,
  updated_at timestamptz not null default now()
);

create table authorised_pickup (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references student on delete cascade,
  name text not null, relation jsonb, phone text,
  id_checked boolean default false,
  added_by text default 'guardian'
);

create table emergency_contact (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references student on delete cascade,
  name text not null, relation text, phone text not null,
  created_at timestamptz not null default now()
);

-- ─── transport ────────────────────────────────────────────────────────────
create table bus_route (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  key text not null, name text not null, sub text,
  colour text not null,
  direction text not null check (direction in ('morning','afternoon')),
  departs time,
  unique (school_id, key)
);

create table bus_stop (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references bus_route on delete cascade,
  name text not null,
  time time,
  note text,
  -- filled in only if the school ever surveys the stops; with these present the
  -- same data drives a geographic map instead of the line diagram
  lat double precision, lng double precision,
  ordinal int not null
);
create index on bus_stop (route_id, ordinal);

-- ─── money ────────────────────────────────────────────────────────────────
create table fee_plan (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  key text not null, name jsonb not null,
  amount numeric(10,2) not null,
  currency text not null default 'EUR',
  period text not null default 'monthly' check (period in ('monthly','yearly','once')),
  grade_level_key text,                 -- which tuition a class falls under
  active boolean not null default true,
  unique (school_id, key)
);

create table invoice (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  student_id uuid not null references student on delete cascade,
  class_id uuid references class,
  plan_id uuid not null references fee_plan,
  period text not null,                 -- '2026-10'
  due_date date not null,
  amount numeric(10,2) not null,
  discount numeric(10,2) not null default 0,
  currency text not null default 'EUR',
  issued_at timestamptz not null default now(),
  status text not null default 'open' check (status in ('open','paid','void')),
  unique (student_id, plan_id, period)
);
create index on invoice (school_id, period);
create index on invoice (student_id);

create table payment (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  invoice_id uuid not null references invoice on delete cascade,
  student_id uuid not null references student,
  amount numeric(10,2) not null check (amount > 0),
  date date not null,
  method text not null check (method in ('bank','cash','card')),
  reference text,
  recorded_by uuid references app_user,
  created_at timestamptz not null default now()
);
create index on payment (invoice_id);

-- what is still owed on an invoice, without recomputing it in five places
create or replace view invoice_balance as
  select i.id, i.student_id, i.school_id, i.period, i.due_date, i.amount,
         coalesce(sum(p.amount), 0) as paid,
         i.amount - coalesce(sum(p.amount), 0) as balance,
         case
           when coalesce(sum(p.amount), 0) >= i.amount then 'paid'
           when coalesce(sum(p.amount), 0) > 0 then 'part'
           when i.due_date < current_date then 'overdue'
           else 'open'
         end as state
    from invoice i
    left join payment p on p.invoice_id = i.id
   group by i.id;

-- ─── school-wide ──────────────────────────────────────────────────────────
create table announcement (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  title jsonb not null, body jsonb not null,
  audience_type audience_type not null,
  audience_ref uuid,
  author_id uuid references app_user,
  published_at timestamptz not null default now(),
  pinned boolean not null default false
);

create table event (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  title jsonb not null, date date not null, time time, type text,
  audience_type audience_type not null, audience_ref uuid
);

create table conversation (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references school on delete cascade,
  subject jsonb,
  participant_user_ids uuid[] not null,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index on conversation using gin (participant_user_ids);

create table message (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversation on delete cascade,
  sender_user_id uuid not null references app_user,
  body jsonb not null,
  created_at timestamptz not null default now()
);
create index on message (conversation_id, created_at);

create table notification (
  id uuid primary key default gen_random_uuid(),
  target_user_id uuid not null references app_user on delete cascade,
  type text not null, title jsonb not null, link text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index on notification (target_user_id, read);

-- append only; no update or delete grant is ever issued on this table
create table audit_log (
  id bigserial primary key,
  school_id uuid references school,
  actor_user_id uuid references app_user,
  action text not null, detail text,
  created_at timestamptz not null default now()
);
create index on audit_log (school_id, created_at desc);

-- ─── updated_at ───────────────────────────────────────────────────────────
create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create trigger t_student_touch before update on student
  for each row execute function touch_updated_at();
create trigger t_medical_touch before update on medical_information
  for each row execute function touch_updated_at();

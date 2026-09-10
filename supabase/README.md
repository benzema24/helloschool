# Backend migration

Everything needed to turn the demo into a system that survives a reload. The
SQL is complete, the seed is the actual demo school exported row by row, and
the bootstrap script creates the accounts.

## Run order

```bash
# 1. create a project at supabase.com

# 2. SQL editor, in order:
01_schema.sql        # tables, enums, indexes, triggers
02_policies.sql      # row level security — the real access boundary
03_storage.sql       # two private buckets, for media and avatars
04_auth_functions.sql# invitation codes and first sign-in
06_v1_features.sql   # absences, receipts, permissions, documents, search, preferences

# 3. accounts. Must come before the seed: app_user.id has to equal the
#    auth user id, and this script pins each one.
npm install
SUPABASE_URL=... SUPABASE_SERVICE_KEY=... npm run bootstrap

# 4. SQL editor:
05_seed_data.sql     # the whole demo school as real rows
```

The last statement in the seed prints a count of students, guardians, staff,
lessons and attendance rows, so you can see at a glance whether it landed.

## What the seed contains

Hello Academy of Education, school year 2026/2027: 28 children across three
kindergarten groups and Klasa 1/A, 5/A and 8/A, 10 staff, 28 guardians, a full
timetable, ten days of the class register, term marks, attendance, meals,
activities, homework, announcements and the week's menu. It is the same data
the demo shows, exported from it, so nothing drifts between the two.

## Accounts

`bootstrap-users.mjs` gives every account one shared password, which is what
you want for a pilot where the school logs in as several roles to try it:

```bash
DEMO_PASSWORD='Hello2026!' npm run bootstrap
```

For real use, send invitations instead and let people set their own:

```bash
INVITE=1 npm run bootstrap
```

## How people sign in

**Guardians get a one-time code, not a password.** They use one phone, once or
twice a day, and a password is a thing to forget — which turns the school
office into a password reset desk by October. `requestGuardianCode()` sends it,
`verifyCode()` checks it. `shouldCreateUser: false` is the important flag: an
address the school has not enrolled gets nothing back.

Email codes are free. SMS costs per message and needs a provider configured in
Supabase Auth — keep it for the guardians who do not use email, not as the main
route.

**Staff sign in with a password**, because classroom tablets are shared and a
code to a personal phone does not fit that. Turn on MFA for the admin role: that
account reads the medical information and contact details of every child.

**Each guardian gets their own account**, not one per family. Photo consent and
medical edits have to be attributable to a person, the audit log has to name who
opened a file, and when parents separate a shared login becomes a problem while
two accounts simply carry on. `guardian_student` already models several
guardians per child and several children per guardian.

**Invitations come from the school.** `issue_invitation()` generates the code in
the database, so it is not derivable from anything the browser knows, and it
expires in seven days. The code alphabet leaves out O/0 and I/1, which people
misread off a printed slip. The admin screen prints one slip per guardian for
the September parents' meeting: child's name, the address, and the code.

Changing a guardian's email or phone is an administration action, never
self-service — changing the address is taking over the account.

The service key bypasses row level security completely. Keep it on a server,
keep it out of git, and rotate it once the migration is done. The anon key in
`.env.example` is the one that goes in the browser; it grants nothing on its
own, because every table is `force row level security`.

## The data layer

`data-layer.js` keeps the demo's function names — `loadDay`, `publishDay`,
`markAttendance`, `reportAbsence`, `uploadMedia`, `reportCard` — so the views
do not have to be rewritten. Replace the in-memory selector calls with these.

## What changes about security

In the demo, `canAccessStudent` decides both what to render and what to allow.
After this migration it only decides what to render. The policies are the
boundary, and they are enforced in Postgres where a crafted request cannot get
past them.

Three rules carry most of the weight:

- a guardian reaches a student through `guardian_student`
- staff reach a student through `staff_class` → `class`
- nobody reaches another `school_id`

Seven places are deliberately narrower than the student rule:

- **Medical information** — guardians, admins and homeroom staff only. A
  subject teacher who sees a child twice a week does not need their file.
- **Media** — read through `student_ids`, so a child without photo consent is
  not merely hidden in the interface; the row is not returned.
- **The success matrix** — `term_grade` is staff-only for a whole class. A
  guardian reads their own child's marks and never the class.
- **Register remarks** — the topic and homework of a lesson are class-wide,
  but a remark is about one child. `lesson_for_guardian()` returns the lesson
  with only that child's remark attached.
- **Absence reports** — a guardian may insert and withdraw their own, but the
  insert policy pins `status = 'reported'`: only staff may move it forward, so
  a parent's submission can never become the official attendance record.
- **Documents** — one policy covers school, class and student scope. A student
  document reaches that family and the class staff, nobody else.
- **Search** — `search_school()` applies the same predicates as the screens, so
  a teacher cannot discover a child by typing a name.

Two functions are deliberately *absent*. There is no server-side export: an
export must be assembled from rows the caller's own policies already returned,
never from a privileged aggregate, or the export becomes a way around row level
security. `log_export()` only records that one happened. And `notify()` refuses
to silence `urgent`, `absence`, `permission`, `gdpr` or `profile` regardless of
what a preference row says, so an emergency notice cannot be switched off.

## Still to do after this

- push notifications (web push, or an SMS gateway — check what parents use)
- EXIF stripping and video transcoding on upload
- offline write queue for staff; kindergarten wifi is bad everywhere
- GDPR export and delete as scheduled jobs
- retention: how long media is kept, and what happens when a child leaves

# Hello Academy of Education — architecture and product notes

A school platform for a private school covering preschool through Grade 9. This document
covers the product architecture, routes, data model, access rules and the migration path
from the demo build to production.

Branding lives in four places: the `<title>` tag, the `.logo-mark` / `.logo-full` rules in
the stylesheet (the school mark, embedded as base64 so the file stays self-contained), the
`--brand` / `--lg --lb --lp --lo --lk` colour tokens derived from that mark, and the school
record in `seed()`. Change those and the product is rebranded.

---

## 1. Product architecture

### The central idea

A student record is not one screen. It is a **stream of small events** — attendance, meals,
activities, moods, notes, photos, grades, homework — written mostly by teachers and read
mostly by parents. Everything else in the product is a projection of that stream:

```
   teachers write events  ─────────►  event store  ─────────►  parents read projections
   (bulk-first interfaces)          (per student, per day)      (timeline / academics)
```

Two projections matter, chosen by the student's stage:

| Stage                 | Projection            | What a parent asks                    |
|-----------------------|-----------------------|---------------------------------------|
| Early years (KG)      | **Day timeline**      | "How was my child's day?"             |
| Grades 1–9            | **Academic record**   | "How is my child doing?"              |

The same underlying tables serve both. `class.stage` (`early` \| `primary`) drives which
projection renders, which navigation appears, and which teacher tools are offered. This is
why the kindergarten and Grade 8 experiences feel like different products without being
different products.

### Layers

```
┌──────────────────────────────────────────────────────────────┐
│ UI            role-scoped views (parent / teacher / admin)    │
├──────────────────────────────────────────────────────────────┤
│ Access layer  canAccessStudent() · canAccessClass()           │
│               getStudentGuarded() · audit()                   │
├──────────────────────────────────────────────────────────────┤
│ Selectors     dayEntries() · attendanceStats() · gradesFor()  │
│               homeworkFor() · notificationsFor() …            │
├──────────────────────────────────────────────────────────────┤
│ Data          demo: in-memory seed  →  prod: Postgres + RLS   │
└──────────────────────────────────────────────────────────────┘
```

Every read of student data in the demo passes through the access layer, so the production
port is a substitution rather than a rewrite: the same predicates become RLS policies.

### Multi-tenancy

Every table carries `school_id`. The demo seeds one school; the schema, the access
predicates and the URL structure assume many. A `super_admin` role sits above `school_id`
scoping and is deliberately not implemented in the MVP — only reserved.

---

## 2. Route structure

Two applications, built from the same source and differing in one line:
`index.html` is the parent portal, `staff.html` is for educators, teachers and
administration. Each resolves only its own accounts, so a guardian's address
entered on the staff page is not found at all — the wrong door does not reveal
that the right one exists.

```
/login                                  sign-in, scoped to the portal

/parent
  /home                                 today, per selected child
  /child                                profile, guardians, medical, pickup, attendance
  /reports                              list of published daily reports
  /report?s={studentId}&d={date}        one day, full timeline
  /academics                            grades 1–9: subjects, trend, attendance
                                        early years: development areas, no marks
  /homework
  /photos
  /calendar                             month grid + events + announcements
  /ditari                               the class register, lesson by lesson
  /timetable                            grades 1–9: today's periods and the week
  /reportcard?t={termId}                end-of-term marks, printable
  /menu?w={weekStart}                   the week's meals, published ahead
  /payments                             this child's invoices and balance
  /transport?dir={morning|afternoon}    bus lines, the child's stop, next pickup
  /messages  ?c={conversationId}
  /notifications
  /more                                 everything not in the phone tab bar
  /setup?s={studentId}&step={step}      guardian completes the child's profile
  /profile                              language, children, GDPR actions

/teacher
  /dashboard                            today's classes, to-do, quick actions
  /classes
  /class?c={classId}                    student cards
  /students                             searchable roster
  /student?s={studentId}
  /attendance?c={classId}
  /daysheet?c={classId}                 THE core teacher workflow (see §4)
  /activities
  /homework
  /grades
  /messages
  /calendar

/admin
  /dashboard  /students  /parents  /teachers  /classes  /subjects
  /attendance  /announcements  /calendar  /reports  /settings
  /menu                                 publish and edit the week's meals
  /transport?dir={morning|afternoon}    the bus timetable and who rides
  /ditari?c={classId}[&v=matrica]       the register for any class
  /subjects?c={classId}                 which subjects each class takes
  /finance?p={period}                   the ledger: billed, collected, overdue
  /fees                                 the fee plans the school bills
  /invites                              who has an invitation, and who has signed in
  /teachers                             staff list
  /staff?s={staffId}                    one member of staff and their assignments
  /import                               CSV intake for the student roster
```

Production adds `/s/{schoolSlug}` in front of everything, or resolves the tenant from the
host. Student and class ids appear in URLs and are **never** trusted: the guard runs on
every request, which is why `#/parent/report?s={anotherChild}` renders a refusal screen.

---

## 3. Data model

UUID primary keys, `created_at` / `updated_at` on mutable tables, `school_id` everywhere.

### Identity and structure

| Entity | Key fields |
|---|---|
| `school` | name, address, phone, email, locale |
| `school_year` | school_id, name, start_date, end_date, active |
| `user` | school_id, name, email, role (`parent`\|`teacher`\|`admin`\|`super_admin`), active |
| `parent` | user_id, school_id, name, email, phone |
| `teacher` | user_id, school_id, title, stage (`early`\|`primary`), phone |
| `student` | school_id, year_id, class_id, first_name, last_name, dob, gender, **photo_consent**, enrolled_on |
| `parent_student` | parent_id, student_id, relation, is_primary, can_pickup, emergency_order |
| `grade_level` | school_id, key, name, ordinal, stage (`early`\|`primary`), assessment (`none`\|`descriptive`\|`numeric`) |
| `class` | school_id, year_id, grade_level_id, name, room, age_label, homeroom_teacher_id, stage, start_time, end_time |
| `subject` | school_id, key, name, icon, area_id, ordinal, active |
| `curricular_area` | school_id, key, name, ordinal — the column groups in the register |
| `class_subject` | class_id, subject_id, ordinal, staff_id — **which subjects a class actually takes** |
| `term_grade` | student_id, class_id, subject_id, term_id, value, recorded_by |
| `conduct` | student_id, term_id, value |
| `teacher_class` | teacher_id, class_id, role (`homeroom`\|`subject`), subject_id |

### Daily record (early years and, partly, all years)

| Entity | Key fields |
|---|---|
| `attendance` | student_id, class_id, date, status (`present`\|`absent`\|`late`\|`excused`), time, note, recorded_by |
| `meal` | student_id, class_id, date, type (`breakfast`\|`snack_am`\|`lunch`\|`snack_pm`), consumption (`none`…`all`), menu, time |
| `activity` | class_id, date, time, category, name, description, student_ids[], participation{student_id → level} |
| `nap` | student_id, date, start_time, minutes |
| `mood_entry` | student_id, date, time, mood |
| `teacher_note` | student_id, class_id, date, text, author_id, visibility (`guardians`) |
| `daily_report` | student_id, class_id, date, **published**, published_at, published_by |
| `photo` | school_id, class_id, activity_id, date, kind, media_type (`image`\|`video`\|`illustration`), src, caption, student_ids[], author_id, storage |

`daily_report` is a **publication marker**, not a copy of the day. Records exist as soon as
a teacher types them; parents see nothing until `published = true`. This gives teachers a
working draft all day and gives parents one clean moment of delivery.

### Academic record (grades 1–9)

| Entity | Key fields |
|---|---|
| `grade` | student_id, class_id, subject_id, type (`quiz`\|`hw`\|`exam`\|`project`\|`participation`), value, max, comment, date, teacher_id |
| `homework` | class_id, subject_id, title, description, assigned_date, due_date, teacher_id, attachment |
| `homework_status` | homework_id, student_id, status (`pending`\|`completed`) |

### School-wide

`announcement` (audience: school \| grade_level \| class \| role), `event` (date, type,
scope), `conversation` + `message`, `notification` (target, type, title, link, read),
`medical_information` (allergies, food_restrictions, notes, doctor — restricted),
`authorised_pickup`, `emergency_contact` (student_id, name, relation, phone),
`absence_report` (student_id, class_id, date, reason, note, reported_by, status),
`period` (class_id, day, ordinal, start, end, subject_id, staff_id, room),
`lesson` — the class register: (class_id, date, period_id, subject_id, staff_id, topic, note,
homework, absent_ids[], remarks[{student_id, text}], recorded_by, recorded_at),
`weekly_menu` (school_id, week_start, days[]), `term` (name, start, end, current),
`audit_log`.

`student` also carries `photo_consent`, `photo_consent_at` and `profile_confirmed_at`;
`medical_information` carries `medications`, `clinic` and `allergies_answered`. Those five
fields are what the profile-completion flow writes, and what the school currently chases on
paper every September.

### Access rules, as policies

```sql
-- a parent sees only their own children
create policy parent_reads_own_child on student for select using (
  exists (select 1 from parent_student ps
          join parent p on p.id = ps.parent_id
          where ps.student_id = student.id and p.user_id = auth.uid())
);

-- a teacher sees only students in classes they are assigned to
create policy teacher_reads_assigned on student for select using (
  exists (select 1 from teacher_class tc
          join teacher t on t.id = tc.teacher_id
          where tc.class_id = student.class_id and t.user_id = auth.uid())
);

-- daily records inherit the student policy
create policy parent_reads_published_day on daily_report for select using (
  published and exists (select 1 from parent_student ps join parent p on p.id = ps.parent_id
                        where ps.student_id = daily_report.student_id and p.user_id = auth.uid())
);

-- medical information is narrower than the student row itself
create policy medical_restricted on medical_information for select using (
  is_guardian_of(student_id) or has_role('admin') or is_homeroom_teacher_of(student_id)
);
```

Photos are stored in a private bucket. `photo.student_ids` is filtered by
`student.photo_consent` at write time, and delivery uses short-lived signed URLs, so a
leaked URL expires rather than becoming a permanent public link to a child.

---

## 4. Main UX decisions

**1. The teacher's day is one sheet, not thirty screens.**
`/teacher/daysheet` walks a class through attendance → meals → activities → mood & nap →
notes → photos → publish. Every step opens with a class-wide action (*Mark all present*,
*Everyone ate everything*, *Apply to class*, *Nap 1h20 for everyone*) and the per-student
rows below exist to record exceptions. A teacher with 25 children touches the exceptions
only. The publish step shows what is about to be sent and to how many parents.

**2. Publishing is an explicit act.**
Parents get one notification when the day is complete, not twelve as it is typed. Before
that, the parent screen says so plainly and offers yesterday's report.

**3. The parent home screen answers one question.**
Greeting, child switcher, then six cells: attendance, meals, mood, nap, activities, note.
The timeline sits below. Parents with more than one child get a switcher; parents with one
child never see it.

**4. Different ages, different vocabulary.**
Kindergarten has no marks and no homework. `/parent/academics` for an early-years child
shows development areas with qualitative levels; `/parent/homework` explains that there is
no homework and offers one idea for home. For Grade 5 the same routes show subject cards,
a grade trend and due dates.

**5. Grades are shown as progress, not ranking.**
No class position, no percentile, no leaderboard. Each subject shows the child's own
average and its own bar. Every grade carries the teacher's comment, because the comment is
what a parent can act on.

**6. Privacy is visible in the interface.**
Medical information is collapsed behind a *Show* control and logged when opened. Photo
consent is shown on the child profile, on the teacher's student card, and again on the
photo step before publishing, listing exactly which children will be included. Opening
another family's record renders an explanation of the rule, not a blank error.

**7. Nothing is hardcoded text.**
Every UI string comes from `I18N.sq` / `I18N.en`; every piece of content (activity names,
notes, menus, announcements) is stored as `{sq, en}` and read through `L()`. Adding a
language is adding a dictionary.

**8. The bus timetable is a line diagram, not a fake map.**
The school's printed timetable is nine runs and sixty-odd stops, and it is the thing parents
photograph and keep on their phone. It is now a screen: morning and afternoon, each line in
its own colour, every stop with its time.

There are no coordinates for these stops, so this does not draw a geographic map with
invented positions — a map that is wrong about where a child waits is worse than no map. It
draws the lines converging on the school, which is what the poster does and what a parent
reads. `bus_stop` carries `lat`/`lng` columns anyway: if the school ever surveys the stops,
the same data drives a real map without any other change.

The part that beats paper: a guardian picks their child's stop once, and from then on the
screen opens with *your stop*, the time, and how many minutes away it is. The office can
change a time and every parent has it immediately, which a printed poster cannot do.

**9. In the parent app, nothing is a placeholder.**
Every control either opens the screen it names or does the thing it says. The six tiles on
today's card are links: attendance and the note open the day's report, meals open the week's
menu, homework opens homework. A subject card opens that subject — its marks, the teacher's
comments, the trend, the recent homework. A homework row opens the task in full and can be
marked done from inside it. A photo opens in a viewer with arrow keys, a caption, who is in
it, and a save button.

The two privacy buttons were the last placeholders and are now real: *export* downloads a
JSON file with everything the school holds on that child — profile, health, attendance,
meals, reports, notes, marks, the register, invoices, payments — and *delete* opens a
request that reaches the administration's own screen, with a note that some records are kept
by law. A guardian can do neither for a child that is not theirs.

**10. The child's picture is where a parent reaches for it.**
On the hero card, on the avatar, with a small camera badge. It was previously a button in a
list on another screen, which nobody would find.

**11. Two front doors, because they are two audiences.**
Parents and staff do not share a building entrance and should not share a login page. The
parent portal talks about the child's day; the staff portal talks about a class. More
usefully, each one resolves only its own accounts, so entering a parent's address on the
staff page returns nothing rather than "wrong password" — which would confirm the account
exists. It is one codebase and one deployment; only the variant constant differs.

**12. Money is the administration's, and the guardian's own line only.**
`/admin/finance` is the ledger: billed, collected, outstanding and overdue for a month, with
a filter for who is behind, one-tap recording of a payment, and generating next month from
this month's lines. Generating also bills children who enrolled since, who have no lines to
repeat — otherwise a child who joined in November is never invoiced.

A guardian sees `/parent/payments`: their own child's invoices and balance, and nothing
school-wide. **Teachers see none of it at all**, in the interface and in the policies.
Whether a family is behind on tuition has no business reaching the person teaching the
child, and that is the kind of leak that ends a school's trust in a system.

Part payments are first-class: an invoice moves *unpaid → part paid → paid* as money
arrives, because families pay in instalments and a system that only understands paid and
unpaid gets worked around with a paper ledger within a month.

**13. Guardians get a one-time code; staff get a password.**
A guardian uses one phone, once or twice a day, and a password is a thing to forget — which
turns the school office into a password reset desk by October. They enter an email or phone
number and a six-digit code, and the session lasts for months. Staff get a password instead,
because classroom tablets are shared and a code sent to a personal phone does not fit that;
the admin account, which can read every child's medical file, additionally gets MFA.

The school never learns a guardian's credentials. That is the point: if the office could
hand out passwords, anyone in the office could sign in as a parent and read a child's
medical information, and the audit log would be worthless.

Each guardian has their own account, not one per family. Consent and medical edits must be
attributable to a person, the audit log has to name who opened a file, and when parents
separate a shared login becomes a problem while two accounts simply carry on.

Nobody self-registers. `/admin/invites` shows every guardian as *joined*, *invited*,
*expired* or *not invited*, issues codes that expire in seven days, and prints one slip per
family for the September parents' meeting. The code alphabet leaves out O/0 and I/1, which
people misread off paper and then phone the office about.

**14. Staff are created by the school, and reach nobody until assigned.**
`/admin/staff` adds an educator or a teacher: a user account, a staff record, and a title.
At that moment they can reach no class and no child — `staff_class` is empty. Assignments
are added one at a time, each naming a class, a role and optionally a subject, and it is
those rows the access rules read. Making someone homeroom staff moves the previous one to
subject role rather than leaving two, because the register names exactly one; and the last
assignment on a class cannot be removed, because a class without staff is a class no one
can see. Deactivation is a flag, not a delete: the marks and lessons someone recorded stay
attributed to them.

**15. The subject list belongs to the school, not to the code.**
`class_subject` is a real table and `subjectsForClass()` reads it. The school adds a subject,
puts it in a curricular area, and ticks it on for the classes that take it — and the register
columns follow immediately. Nothing about *Kimi* or *Gjuhë Gjermane* is written into the app.
A subject that already has marks recorded against it cannot be pulled out from under them;
the toggle refuses and says why.

**16. The register is one screen with two faces.**
The paper book is a single object: the daily lesson pages and the success matrix live
between the same covers. `/ditari` follows that — one navigation entry, one class picker,
and a switch between *Orët e ditës* and *Matrica e suksesit*. Changing face keeps the class
you were in.

The matrix puts children down the left with their number, register number, and the
*name · parent's name · surname* form the register uses, and the subjects across the top
grouped by curricular area. Three rows per child — Semestri I, Semestri II, N.P — plus the
average, the success level and conduct. The first three columns stay pinned while the
subjects scroll, which is what makes it usable on a phone at all. The final mark appears
only once both terms are in, exactly as on paper, so a half-finished year looks half
finished rather than falsely complete.

Tapping a cell is fine for a correction, but nobody fills a register cell by cell:
*Plotëso një lëndë* opens one subject for the whole class with a 1–5 control per child, and
stays open as the teacher works down the list.

**17. Reading a class and writing to it are different permissions.**
A guardian legitimately reads their child's class — announcements, the register's class-wide
lines, the activity list — so `canAccessClass` returns true for them. Using that same check
to guard a *write* was a real hole, and it is now closed: every mutating action asks
`canWriteClass`, which answers only for the staff assigned to that class and for the
administration. The two names sit next to each other in the source with a comment saying why.

**18. The matrix is staff-only as a class, and the guardian's own row.**
A guardian seeing every child's marks would be the single worst privacy failure this product
could have, so `/parent/ditari` shows the lesson entries only, with no matrix face at all, and
`render()` refuses any route whose section does not match the session role.

But the *form* of the matrix is worth keeping for a guardian: it is the layout the school
already uses and the one a parent recognises. So the marks screen renders the same grid —
same curricular areas, same I / II / N.P rows — holding exactly one child, read-only, with
the number and parent-name columns dropped. The panel takes the students to show as an
argument, so there is one grid in the codebase rather than a second one to keep in step.

**19. The register is one row per lesson, and it has two audiences.**
`/teacher/ditari` lists the day's periods straight from the timetable, and each one is
recorded with the topic covered, who was missing from *that lesson* rather than that day,
the homework set, and optionally a remark about one child. The split matters: the topic and
the homework are class-wide and every guardian sees them, while a remark is about one child
and only that child's guardian ever sees it. `/parent/ditari` reads the same rows filtered
that way. Today's lessons deliberately start unrecorded, because that is the teacher's
actual working state at 08:00.

**20. Marks are words in the lower grades and numbers higher up.**
`grade_level.assessment` decides: grade 1 shows *Shkëlqyeshëm* / *Shumë mirë* / *Mirë* /
*Mjaftueshëm* / *Duhet përkrahje*, grade 5 and up show 1–5. The underlying value is the same
number in both cases, so a school that changes where the boundary sits changes one field, not
the data. Every place a mark is spoken — the parent home card, the subject cards, the recent
grades list, the teacher's table, the report card — goes through a single `markLabel(class, value)`
call, which is why no raw number can leak into a descriptive class.

**21. The daily loop runs in both directions.**
A guardian reports an absence before 08:00 and the educator sees it named on the
attendance screen before she marks anyone — the two most common events in a school day
finally meet. Guardians and staff can start a conversation rather than only replying to
one, and an educator can send a single message to every guardian in her group. None of
this is new machinery: absences ride the existing notification path, broadcasts become a
class-scoped announcement, and the message compose reuses the conversation model.

**22. Photos and video are the product, so uploading has to be one tap.**
The photo step of the day sheet takes real files — several at once, from the gallery or
straight from the camera — and the consent filter runs at the moment of upload: the modal
names who will be included and who will be left out before anything is saved, and a child
without consent is never written into `student_ids`. Images are re-encoded to 1600px on the
device before they are stored, so a phone photo does not sit in memory at full resolution;
video is referenced rather than copied. Children, guardians and staff can each carry a
profile picture, which then replaces the initials avatar everywhere that person appears.

**23. Kindergarten staff are edukatore, and each group has her own.**
The word follows the class, not the person: `staffWord(cls)` returns *edukatorja* for an
early-years group and *mësuesi/ja* for grades 1–9, so a kindergarten parent never reads
school vocabulary that does not belong to their child's day. Each group has one edukatore
as homeroom staff, and the access rules mean she reaches her own group and no other — an
edukatore opening another group's day sheet gets the refusal screen, same as any other
boundary in the product.

**24. The school owns the record; the guardian completes it.**
A parent never creates a child — the school enrols them, and the guardian fills in what the
school cannot know: allergies, medication, the family doctor, a backup contact, who may
collect the child, and photo consent. `/parent/setup` walks those five sections one at a
time, saving each step as the parent moves on, and a completion ring follows the child
through the parent's home screen and the admin roster until it is done. Confirming stamps
`profile_confirmed_at` and notifies the homeroom teacher, so an allergy added last week
reaches the person serving lunch today. Photo consent is re-asked each school year rather
than inherited, which is why a consent given in a previous year still shows as outstanding.

**25. Getting a roster in has to take minutes, not a week.**
`/admin/import` accepts a paste from Excel or Google Sheets, validates every row against the
real class list, flags duplicates and bad dates before anything is written, and creates the
student, the guardian and the invitation together. Class matching is deliberately lenient —
a school writes `5/A` where the roster says `Klasa 5/A` — because an import that rejects a
whole file over a naming convention is an import nobody uses.

**26. The palette comes from the school's mark.**
The five colours in the *hello* logo drive the interface: the purple becomes the primary
`--brand` (deepened for text contrast), the blue carries day-to-day child content, the
green, orange and pink serve status and category work. Charts use the raw logo colours.
The result reads as the school's product without turning the interface into a rainbow.

**27. On a phone, a tab bar of four and a More screen — never a hidden menu.**
The desktop sidebar has fourteen entries; a phone tab bar holds five. The fifth is *More*,
which lists everything else and carries the unread badge, so nothing in the product is
unreachable from a phone. The third tab follows the child's age: a kindergarten parent gets
photos, a grade parent gets the register. A test walks the whole parent menu and fails if
any screen cannot be reached from the tab bar or from More.

**28. Responsive by role.**
Parent: mobile-first, bottom tab bar under 860px, sidebar on desktop. Teacher: designed for
a tablet in the room — large touch targets, segmented controls, no modal per student.
Admin: desktop tables and charts.

---

## 5. Demo build vs production

The delivered `hello-academy.html` is a **single-file demo**: no build step, no server, no
persistence. Open it and present. Reloading resets the data; the sparkle button in the
top bar reseeds it mid-demo.

What the demo is honest about:

| Demo | Production |
|---|---|
| Sign-in flow real, but the code is shown on screen | Supabase Auth sends it by email or SMS; MFA on the admin role |
| Access checks in the client | Postgres RLS + server-side checks; client checks are UX only |
| Uploads held in browser storage, per device | Private object storage, signed URLs, EXIF stripping, virus scan, video transcoding |
| `audit()` writes to an array | Append-only audit table, no delete grant |
| Browser storage: survives a reload, never leaves the device | Postgres, migrations, backups, retention policy |
| — | GDPR export/delete jobs, consent records with timestamps, DPA with the school |

### The application already speaks to it

`config.js` holds two lines. Empty, both apps run on browser storage as before;
filled in, they run on Postgres — and nothing else changes, because the client
layer was built to fit the application rather than the other way round.

It talks to PostgREST and GoTrue with plain `fetch`, so there is no library and
no build step, and the single-file deployment survives. On sign-in it loads
every table at once; row level security does the filtering, so a guardian's
request returns their own children and a teacher's returns their classes,
using the same call.

Writes are the interesting part. Fifteen feature files mutate the in-memory
`DB` directly, and rewriting all of them to call a repository would have been
a rewrite of the whole product. Instead the layer snapshots `DB`, and after
each render diffs it per collection by id, pushing inserts, updates and
deletes. Upserts run parent-table-first and deletes in reverse, so foreign
keys hold. An unchanged screen sends nothing.

Uploaded pictures go to the private bucket before their row is written, and
the row carries the path rather than the bytes — a data URL in a table column
would be both slow and impossible to expire.

### The migration is written and runnable, not just described

`supabase/` is the migration itself, ready to execute:

- `01_schema.sql` — 40 tables with enums, indexes and triggers
- `02_policies.sql` — 84 row level security policies; the demo's `canAccessStudent`
  and `canAccessClass` rewritten where they actually count
- `04_auth_functions.sql` — invitation codes generated in the database, and the
  first-sign-in stamp; plus the notes on code lifetime, rate limits and MFA
- `03_storage.sql` — two private buckets; media is read through `student_ids`, so
  photo consent is enforced at the storage layer
- `05_seed_data.sql` — **the demo school exported row by row**, 28 children, 10 staff,
  28 guardians, the timetable, ten days of the register, marks and attendance. It is
  generated from the running app, so the two cannot drift apart.
- `bootstrap-users.mjs` — creates the auth accounts and pins each id to the one used
  in the seed, because `app_user.id = auth.users.id` is what every policy stands on
- `data-layer.js` — the same function names the demo uses, backed by Postgres

`supabase/README.md` has the run order. After the migration the client-side access
checks become what they should be: a way to decide what to render, not the boundary.

### Mapping to the preferred stack

```
app/
  (auth)/login/page.tsx
  (parent)/parent/{home,child,reports,academics,homework,photos,calendar,messages}/page.tsx
  (teacher)/teacher/{dashboard,classes,students,attendance,daysheet,homework,grades}/page.tsx
  (admin)/admin/{dashboard,students,parents,teachers,classes,announcements,reports}/page.tsx
components/
  ui/                  shadcn/ui primitives
  day/                 Timeline, TimelineEntry, MoodPicker, MealRow, ConsumptionSeg
  class/               RosterRow, BulkBar, AttendanceSeg
  charts/              Sparkline, BarChart, Donut, Ring   (recharts in production)
lib/
  db/schema.ts         Drizzle or Prisma schema — §3 of this document
  access.ts            canAccessStudent / canAccessClass — mirrors the RLS policies
  selectors/           dayEntries, attendanceStats, gradesFor …
  i18n/{sq,en}.ts
```

The demo's function names match this layout on purpose: `dayEntries`, `attendanceStats`,
`canAccessStudent`, `timelineHTML` port across with their logic intact.

---

## 6. Presenting it

**Flow 1 — the kindergarten day (about three minutes).**
Log in as *Teacher · Early years* (Teuta Hoxha). Open **Today** → the day sheet for Grupi
Lulet. *Mark all present*, switch one child to Late. Meals → Lunch → type a menu →
*Apply to class: Most* → drop one child to Half. Activities → *Add activity* → the form is
pre-filled with "Painting autumn trees" → Save. Mood & nap → tap a mood for Emma →
*Nap 1h20 for everyone*. Notes → Emma → write a sentence. Photos → *Add photo* (note the
consent line naming exactly who is included). Publish → *Publish the day*.

Then log in as *Parent* (Arta Krasniqi). Emma's home screen now shows the attendance, the
meal, the activity, the mood, the note and the photo, and the notification badge is lit.
Open the timeline for the full day.

**Flow 2 — the older student (about a minute).**
Log in as *Teacher · Grades* (Blerim Gashi). *New homework* → class 5/A → Save.
*Add grade* → Rron Krasniqi → Science → 5 → Save. Switch to the parent, select Rron in the
switcher: the homework and the grade are there, with the subject average and trend updated.

Seed data covers Hello Academy of Education with 14 students across 3 classes, 3 teachers, 14 parents, roughly
24 school days of attendance, 10 days of full kindergarten records, grades across nine
subjects, homework, announcements, events, conversations and notifications — so no screen
in the demo is empty.

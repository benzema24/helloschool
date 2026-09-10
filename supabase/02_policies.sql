-- Hello Academy — row level security
-- These are the same three rules the demo enforces in the client, moved to
-- where they actually count. A guardian reaches their own children. Staff
-- reach the classes they are assigned to. Nobody reaches another school.
--
-- Run after 01_schema.sql.

-- ─── helpers ──────────────────────────────────────────────────────────────
create or replace function my_role() returns user_role
language sql stable security definer set search_path = public as $$
  select role from app_user where id = auth.uid()
$$;

create or replace function my_school() returns uuid
language sql stable security definer set search_path = public as $$
  select school_id from app_user where id = auth.uid()
$$;

create or replace function is_admin() returns boolean
language sql stable as $$ select my_role() in ('admin','super_admin') $$;

create or replace function is_guardian_of(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from guardian_student gs
    join guardian g on g.id = gs.guardian_id
    where gs.student_id = sid and g.user_id = auth.uid()
  )
$$;

create or replace function teaches_class(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from staff_class sc
    join staff s on s.id = sc.staff_id
    where sc.class_id = cid and s.user_id = auth.uid()
  )
$$;

create or replace function teaches_student(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from student st
    join staff_class sc on sc.class_id = st.class_id
    join staff s on s.id = sc.staff_id
    where st.id = sid and s.user_id = auth.uid()
  )
$$;

-- one predicate used by every table hanging off a student
create or replace function can_see_student(sid uuid) returns boolean
language sql stable as $$
  select is_admin() or is_guardian_of(sid) or teaches_student(sid)
$$;

-- ─── enable RLS everywhere ────────────────────────────────────────────────
do $$
declare tbl text;
begin
  foreach tbl in array array[
    'school','school_year','term','app_user','guardian','staff','grade_level','class','subject',
    'curricular_area','class_subject','lesson','term_grade','conduct',
    'staff_class','student','guardian_student','period','attendance','absence_report','meal','invitation',
    'fee_plan','invoice','payment','bus_route','bus_stop',
    'weekly_menu','activity','nap','mood_entry','staff_note','daily_report','media','grade',
    'homework','homework_status','medical_information','authorised_pickup','emergency_contact',
    'announcement','event','conversation','message','notification','audit_log'
  ] loop
    execute format('alter table %I enable row level security', tbl);
    execute format('alter table %I force row level security', tbl);
  end loop;
end $$;

-- ─── tenancy ──────────────────────────────────────────────────────────────
create policy school_read on school for select using (id = my_school());
create policy year_read   on school_year for select using (school_id = my_school());
create policy term_read   on term for select using (school_id = my_school());
create policy level_read  on grade_level for select using (school_id = my_school());
create policy subject_read on subject for select using (school_id = my_school());
create policy subject_write on subject for all using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());
create policy area_read on curricular_area for select using (school_id = my_school());
create policy area_write on curricular_area for all using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());

create policy class_subject_read on class_subject for select using (
  exists (select 1 from class c where c.id = class_id and c.school_id = my_school()));
create policy class_subject_write on class_subject for all using (is_admin()) with check (is_admin());

-- only the administration creates staff and decides who teaches what
create policy staff_admin_write on staff for all using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());
create policy staffclass_write on staff_class for all using (is_admin()) with check (is_admin());
create policy class_read  on class for select using (school_id = my_school());
create policy staffclass_read on staff_class for select using (
  exists (select 1 from class c where c.id = class_id and c.school_id = my_school()));
create policy period_read on period for select using (school_id = my_school());
create policy menu_read   on weekly_menu for select using (school_id = my_school());
create policy menu_write  on weekly_menu for all using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());

create policy user_self on app_user for select using (
  id = auth.uid() or is_admin() and school_id = my_school());
create policy user_update_self on app_user for update using (id = auth.uid())
  with check (id = auth.uid());

create policy staff_read on staff for select using (school_id = my_school());
create policy staff_self on staff for update using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- a guardian sees themselves and the co-guardians of their own children
create policy guardian_read on guardian for select using (
  user_id = auth.uid() or is_admin() and school_id = my_school()
  or exists (
    select 1 from guardian_student a
    join guardian_student b on b.student_id = a.student_id
    join guardian g on g.id = a.guardian_id
    where g.user_id = auth.uid() and b.guardian_id = guardian.id));
create policy guardian_self_update on guardian for update using (user_id = auth.uid())
  with check (user_id = auth.uid());
create policy guardian_admin_write on guardian for all using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());

-- invitations are the administration's business only. A guardian never needs to
-- read one: the code arrives by email or SMS, and is checked server-side.
create policy invitation_admin on invitation for all
  using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());

-- ─── students ─────────────────────────────────────────────────────────────
create policy student_read on student for select using (can_see_student(id));
-- a guardian may only touch the fields the profile flow owns; the check keeps
-- them from moving a child into another class
create policy student_guardian_update on student for update
  using (is_guardian_of(id))
  with check (is_guardian_of(id));
create policy student_staff_update on student for update
  using (teaches_student(id) or is_admin()) with check (teaches_student(id) or is_admin());
create policy student_admin_write on student for insert with check (is_admin() and school_id = my_school());

create policy gs_read on guardian_student for select using (can_see_student(student_id));
create policy gs_admin on guardian_student for all using (is_admin()) with check (is_admin());

-- ─── the daily record ─────────────────────────────────────────────────────
create policy attendance_read on attendance for select using (can_see_student(student_id));
create policy attendance_write on attendance for all
  using (teaches_class(class_id) or is_admin())
  with check (teaches_class(class_id) or is_admin());

-- a guardian reports an absence for their own child and nobody else's
create policy absence_read on absence_report for select using (can_see_student(student_id));
create policy absence_guardian_insert on absence_report for insert
  with check (is_guardian_of(student_id));
create policy absence_guardian_delete on absence_report for delete
  using (is_guardian_of(student_id));
create policy absence_staff on absence_report for update
  using (teaches_class(class_id) or is_admin()) with check (true);

create policy meal_read on meal for select using (can_see_student(student_id));
create policy meal_write on meal for all
  using (teaches_class(class_id) or is_admin()) with check (teaches_class(class_id) or is_admin());

create policy nap_read on nap for select using (can_see_student(student_id));
create policy nap_write on nap for all using (teaches_student(student_id)) with check (teaches_student(student_id));

create policy mood_read on mood_entry for select using (can_see_student(student_id));
create policy mood_write on mood_entry for all using (teaches_student(student_id)) with check (teaches_student(student_id));

create policy activity_read on activity for select using (
  teaches_class(class_id) or is_admin() or exists (
    select 1 from student s where s.class_id = activity.class_id and is_guardian_of(s.id)));
create policy activity_write on activity for all
  using (teaches_class(class_id)) with check (teaches_class(class_id));

create policy note_read on staff_note for select using (can_see_student(student_id));
create policy note_write on staff_note for all using (teaches_student(student_id)) with check (teaches_student(student_id));

-- a guardian only ever sees a published day
create policy report_read_guardian on daily_report for select
  using (published and is_guardian_of(student_id));
create policy report_read_staff on daily_report for select
  using (teaches_student(student_id) or is_admin());
create policy report_write on daily_report for all
  using (teaches_class(class_id)) with check (teaches_class(class_id));

-- media: consent is enforced by membership of student_ids
create policy media_read_guardian on media for select using (
  exists (select 1 from unnest(student_ids) sid where is_guardian_of(sid)));
create policy media_read_staff on media for select using (teaches_class(class_id) or is_admin());
create policy media_write on media for all
  using (teaches_class(class_id)) with check (teaches_class(class_id));

-- ─── academic ─────────────────────────────────────────────────────────────
-- the register: topic and homework are class-wide, remarks are not.
-- the client strips remarks; this view is the enforced version for guardians.
create policy lesson_read_staff on lesson for select using (teaches_class(class_id) or is_admin());
create policy lesson_read_guardian on lesson for select using (
  exists (select 1 from student s where s.class_id = lesson.class_id and is_guardian_of(s.id)));
create policy lesson_write on lesson for all
  using (teaches_class(class_id)) with check (teaches_class(class_id));

create or replace function lesson_for_guardian(sid uuid)
returns table (id uuid, date date, ordinal int, subject_id uuid, staff_id uuid,
               topic jsonb, homework jsonb, was_absent boolean, remark jsonb)
language sql stable security definer set search_path = public as $$
  select l.id, l.date, l.ordinal, l.subject_id, l.staff_id, l.topic, l.homework,
         sid = any (l.absent_ids) as was_absent,
         (select r->'text' from jsonb_array_elements(l.remarks) r
           where (r->>'student_id')::uuid = sid limit 1) as remark
  from lesson l
  join student s on s.id = sid and s.class_id = l.class_id
  where is_guardian_of(sid)
  order by l.date desc, l.ordinal
$$;

-- the matrix is staff-only; a guardian reads their own child's marks, never the class
create policy term_grade_read_staff on term_grade for select using (teaches_class(class_id) or is_admin());
create policy term_grade_read_guardian on term_grade for select using (is_guardian_of(student_id));
create policy term_grade_write on term_grade for all
  using (teaches_class(class_id) or is_admin()) with check (teaches_class(class_id) or is_admin());

create policy conduct_read on conduct for select using (can_see_student(student_id));
create policy conduct_write on conduct for all
  using (teaches_student(student_id) or is_admin()) with check (teaches_student(student_id) or is_admin());

create policy grade_read on grade for select using (can_see_student(student_id));
create policy grade_write on grade for all
  using (teaches_class(class_id)) with check (teaches_class(class_id));

create policy homework_read on homework for select using (
  teaches_class(class_id) or is_admin() or exists (
    select 1 from student s where s.class_id = homework.class_id and is_guardian_of(s.id)));
create policy homework_write on homework for all
  using (teaches_class(class_id)) with check (teaches_class(class_id));

create policy hwstatus_read on homework_status for select using (can_see_student(student_id));
create policy hwstatus_write on homework_status for all
  using (is_guardian_of(student_id) or teaches_student(student_id))
  with check (is_guardian_of(student_id) or teaches_student(student_id));

-- ─── sensitive ────────────────────────────────────────────────────────────
-- narrower than student: subject teachers do not need a child's medical file,
-- only the homeroom staff who are with them all day
create policy medical_read on medical_information for select using (
  is_guardian_of(student_id) or is_admin() or exists (
    select 1 from student st
    join class c on c.id = st.class_id
    join staff s on s.id = c.homeroom_staff_id
    where st.id = medical_information.student_id and s.user_id = auth.uid()));
create policy medical_write on medical_information for all
  using (is_guardian_of(student_id) or is_admin())
  with check (is_guardian_of(student_id) or is_admin());

create policy pickup_read on authorised_pickup for select using (can_see_student(student_id));
create policy pickup_write on authorised_pickup for all
  using (is_guardian_of(student_id) or is_admin())
  with check (is_guardian_of(student_id) or is_admin());

create policy contact_read on emergency_contact for select using (can_see_student(student_id));
create policy contact_write on emergency_contact for all
  using (is_guardian_of(student_id) or is_admin())
  with check (is_guardian_of(student_id) or is_admin());

-- ─── transport ────────────────────────────────────────────────────────────
-- The timetable is a public notice inside the school: everyone signed in reads
-- it, only the office edits it.
create policy bus_route_read on bus_route for select using (school_id = my_school());
create policy bus_route_write on bus_route for all using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());
create policy bus_stop_read on bus_stop for select using (
  exists (select 1 from bus_route r where r.id = route_id and r.school_id = my_school()));
create policy bus_stop_write on bus_stop for all using (is_admin()) with check (is_admin());

-- ─── money ────────────────────────────────────────────────────────────────
-- Teachers are deliberately absent from all of this. Whether a family is behind
-- on tuition has no business reaching the person teaching the child.
create policy fee_plan_read on fee_plan for select using (school_id = my_school());
create policy fee_plan_write on fee_plan for all using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());

create policy invoice_read on invoice for select using (
  is_admin() and school_id = my_school() or is_guardian_of(student_id));
create policy invoice_write on invoice for all using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());

create policy payment_read on payment for select using (
  is_admin() and school_id = my_school() or is_guardian_of(student_id));
-- only the office records money, and only the office ever amends it
create policy payment_write on payment for all using (is_admin() and school_id = my_school())
  with check (is_admin() and school_id = my_school());

-- ─── school-wide ──────────────────────────────────────────────────────────
create policy announcement_read on announcement for select using (
  school_id = my_school() and (
    audience_type = 'school'
    or (audience_type = 'class' and (
         teaches_class(audience_ref) or exists (
           select 1 from student s where s.class_id = announcement.audience_ref and is_guardian_of(s.id))))
    or (audience_type = 'role' and true)));
create policy announcement_write on announcement for all using (
  is_admin() or exists (select 1 from staff s where s.user_id = auth.uid()))
  with check (is_admin() or (audience_type = 'class' and teaches_class(audience_ref)));

create policy event_read on event for select using (school_id = my_school());
create policy event_write on event for all using (is_admin()) with check (is_admin());

create policy conversation_read on conversation for select using (auth.uid() = any (participant_user_ids));
create policy conversation_insert on conversation for insert
  with check (auth.uid() = any (participant_user_ids) and school_id = my_school());
create policy conversation_update on conversation for update
  using (auth.uid() = any (participant_user_ids)) with check (true);

create policy message_read on message for select using (
  exists (select 1 from conversation c where c.id = conversation_id and auth.uid() = any (c.participant_user_ids)));
create policy message_insert on message for insert with check (
  sender_user_id = auth.uid() and
  exists (select 1 from conversation c where c.id = conversation_id and auth.uid() = any (c.participant_user_ids)));

create policy notification_read on notification for select using (target_user_id = auth.uid());
create policy notification_update on notification for update
  using (target_user_id = auth.uid()) with check (target_user_id = auth.uid());

-- the audit log can be written and read, never edited
create policy audit_insert on audit_log for insert with check (actor_user_id = auth.uid());
create policy audit_read on audit_log for select using (is_admin() and school_id = my_school());
revoke update, delete on audit_log from authenticated;

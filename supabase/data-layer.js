/**
 * Hello Academy — data layer
 *
 * The demo reads everything from an in-memory `DB` object. This file is the
 * replacement: the same function names, backed by Postgres. Swap the selector
 * calls in the app for these and the interface does not change.
 *
 * The access checks in the demo (canAccessStudent, canAccessClass) stay in the
 * client as UX — they decide what to render. They are no longer the security
 * boundary; row level security is. If a policy and a client check disagree,
 * the policy wins and the query returns nothing.
 *
 * npm i @supabase/supabase-js
 */

import { createClient } from '@supabase/supabase-js';

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY
);

/* ── session ────────────────────────────────────────────────────────────── */

export async function signIn(email, password) {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
  return data.user;
}

export async function signOut() {
  await supabase.auth.signOut();
}

/** Everything the shell needs on boot: who you are, and what you can reach. */
export async function loadSession() {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;

  const { data: me } = await supabase
    .from('app_user')
    .select('id, name, email, role, photo_url, school_id')
    .eq('id', user.id)
    .single();

  if (me.role === 'parent') {
    const { data: guardian } = await supabase
      .from('guardian').select('id, name, phone, email, photo_url')
      .eq('user_id', user.id).single();
    const { data: children } = await supabase
      .from('student')
      .select('*, class:class_id(*), guardian_student!inner(guardian_id)')
      .eq('guardian_student.guardian_id', guardian.id);
    return { user: me, guardian, children };
  }

  if (me.role === 'teacher') {
    const { data: staff } = await supabase
      .from('staff').select('id, title, stage, phone, photo_url')
      .eq('user_id', user.id).single();
    const { data: classes } = await supabase
      .from('class').select('*, staff_class!inner(staff_id, role, subject_id)')
      .eq('staff_class.staff_id', staff.id);
    return { user: me, staff, classes };
  }

  const { data: classes } = await supabase.from('class').select('*');
  return { user: me, classes };
}

/* ── the day ────────────────────────────────────────────────────────────── */

/**
 * One round trip for a child's whole day. RLS filters it: an unpublished day
 * simply comes back with report === null for a guardian.
 */
export async function loadDay(studentId, date) {
  const [attendance, meals, activities, nap, mood, notes, report, media] = await Promise.all([
    supabase.from('attendance').select('*').eq('student_id', studentId).eq('date', date).maybeSingle(),
    supabase.from('meal').select('*').eq('student_id', studentId).eq('date', date).order('time'),
    supabase.from('activity').select('*').contains('student_ids', [studentId]).eq('date', date).order('time'),
    supabase.from('nap').select('*').eq('student_id', studentId).eq('date', date).maybeSingle(),
    supabase.from('mood_entry').select('*').eq('student_id', studentId).eq('date', date),
    supabase.from('staff_note').select('*').eq('student_id', studentId).eq('date', date),
    supabase.from('daily_report').select('*').eq('student_id', studentId).eq('date', date).maybeSingle(),
    supabase.from('media').select('*').contains('student_ids', [studentId]).eq('date', date),
  ]);
  return {
    attendance: attendance.data, meals: meals.data ?? [], activities: activities.data ?? [],
    nap: nap.data, mood: mood.data ?? [], notes: notes.data ?? [],
    report: report.data, media: await withSignedUrls(media.data ?? []),
  };
}

/* ── media ──────────────────────────────────────────────────────────────── */

/** Objects are private. URLs are minted per request and expire in an hour. */
export async function withSignedUrls(rows) {
  const paths = rows.filter(r => r.storage_path).map(r => r.storage_path);
  if (!paths.length) return rows;
  const { data } = await supabase.storage.from('media').createSignedUrls(paths, 3600);
  const byPath = Object.fromEntries((data ?? []).map(d => [d.path, d.signedUrl]));
  return rows.map(r => ({ ...r, src: byPath[r.storage_path] ?? null }));
}

/**
 * Consent is applied here, at write time, exactly as the demo does: the tagged
 * children are the consented ones, and nobody else can ever be added later.
 */
export async function uploadMedia({ schoolId, classId, file, caption, date, authorStaffId }) {
  const { data: consented } = await supabase
    .from('student').select('id').eq('class_id', classId).eq('photo_consent', true);

  const ext = file.name.split('.').pop().toLowerCase();
  const path = `${schoolId}/${classId}/${crypto.randomUUID()}.${ext}`;

  const { error: upErr } = await supabase.storage
    .from('media').upload(path, file, { cacheControl: '3600', upsert: false });
  if (upErr) throw upErr;

  const { data, error } = await supabase.from('media').insert({
    school_id: schoolId,
    class_id: classId,
    date,
    type: file.type.startsWith('video') ? 'video' : 'image',
    storage_path: path,
    caption,
    student_ids: consented.map(s => s.id),
    author_id: authorStaffId,
  }).select().single();
  if (error) throw error;

  await logAudit('media.upload', `class=${classId} consented=${consented.length}`);
  return data;
}

/* ── writes the demo already models ─────────────────────────────────────── */

export async function markAttendance(classId, rows, staffId) {
  const { error } = await supabase.from('attendance').upsert(
    rows.map(r => ({ ...r, class_id: classId, recorded_by: staffId })),
    { onConflict: 'student_id,date' }
  );
  if (error) throw error;
  await logAudit('attendance.save', `class=${classId} n=${rows.length}`);
}

export async function reportAbsence({ studentId, classId, schoolId, date, reason, note, guardianId }) {
  const { data, error } = await supabase.from('absence_report')
    .insert({ student_id: studentId, class_id: classId, school_id: schoolId,
              date, reason, note, reported_by: guardianId })
    .select().single();
  if (error) throw error;
  await logAudit('absence.report', `${studentId} ${date} ${reason}`);
  return data;
}

export async function publishDay(classId, date, staffId) {
  const { data: students } = await supabase.from('student').select('id').eq('class_id', classId);
  const { error } = await supabase.from('daily_report').upsert(
    students.map(s => ({ student_id: s.id, class_id: classId, date,
                         published: true, published_at: new Date().toISOString(), published_by: staffId })),
    { onConflict: 'student_id,date' }
  );
  if (error) throw error;
  await logAudit('day.publish', `class=${classId} ${date}`);
}

/** The profile-completion flow. A guardian may write only these fields. */
export async function saveChildProfile(studentId, { medical, contacts, pickups, photoConsent }) {
  if (medical) {
    await supabase.from('medical_information')
      .upsert({ student_id: studentId, ...medical }, { onConflict: 'student_id' });
  }
  if (photoConsent !== undefined) {
    await supabase.from('student')
      .update({ photo_consent: photoConsent, photo_consent_at: new Date().toISOString() })
      .eq('id', studentId);
  }
  if (contacts) {
    await supabase.from('emergency_contact').delete().eq('student_id', studentId);
    if (contacts.length) await supabase.from('emergency_contact').insert(
      contacts.map(c => ({ ...c, student_id: studentId })));
  }
  if (pickups) {
    await supabase.from('authorised_pickup').delete().eq('student_id', studentId).eq('added_by', 'guardian');
    if (pickups.length) await supabase.from('authorised_pickup').insert(
      pickups.map(p => ({ ...p, student_id: studentId, added_by: 'guardian' })));
  }
  await supabase.from('student')
    .update({ profile_confirmed_at: new Date().toISOString() }).eq('id', studentId);
  await logAudit('profile.confirm', studentId);
}

/* ── the report card ────────────────────────────────────────────────────── */

export async function reportCard(studentId, termId) {
  const { data: term } = await supabase.from('term').select('*').eq('id', termId).single();
  const { data: grades } = await supabase
    .from('grade').select('*, subject:subject_id(*)')
    .eq('student_id', studentId)
    .gte('date', term.start_date).lte('date', term.end_date);

  const bySubject = new Map();
  for (const g of grades) {
    const k = g.subject_id;
    if (!bySubject.has(k)) bySubject.set(k, { subject: g.subject, values: [] });
    bySubject.get(k).values.push(Number(g.value));
  }
  const rows = [...bySubject.values()].map(r => {
    const avg = r.values.reduce((a, b) => a + b, 0) / r.values.length;
    return { subject: r.subject, count: r.values.length, avg,
             mark: Math.max(1, Math.min(5, Math.round(avg))) };
  });
  const overall = rows.length ? rows.reduce((a, r) => a + r.avg, 0) / rows.length : null;
  return { term, rows, overall };
}

/* ── live updates ───────────────────────────────────────────────────────── */

/**
 * A guardian's screen updates the moment the educator publishes, without a
 * refresh. RLS applies to realtime too: you are only pushed rows you may read.
 */
export function subscribeToChild(studentId, onChange) {
  return supabase.channel(`child:${studentId}`)
    .on('postgres_changes',
        { event: '*', schema: 'public', table: 'daily_report', filter: `student_id=eq.${studentId}` },
        onChange)
    .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'media' }, onChange)
    .subscribe();
}

/* ── audit ──────────────────────────────────────────────────────────────── */

export async function logAudit(action, detail) {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return;
  const { data: me } = await supabase.from('app_user').select('school_id').eq('id', user.id).single();
  await supabase.from('audit_log').insert({
    school_id: me?.school_id, actor_user_id: user.id, action, detail,
  });
}

/* ── signing in ─────────────────────────────────────────────────────────── */

/**
 * Guardians get a one-time code, not a password. They use one phone and have
 * nothing to remember, and the school never learns their credentials — which
 * matters, because the office must not be able to sign in as a parent and read
 * a child's medical file.
 *
 * Supabase sends the email itself. `shouldCreateUser: false` is the important
 * part: an address the school has not enrolled gets nothing back.
 */
export async function requestGuardianCode(email) {
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { shouldCreateUser: false },
  });
  if (error) throw error;
}

/** The same, by phone, for guardians who do not use email. Costs per message. */
export async function requestGuardianCodeBySms(phone) {
  const { error } = await supabase.auth.signInWithOtp({
    phone,
    options: { shouldCreateUser: false },
  });
  if (error) throw error;
}

export async function verifyCode({ email, phone, token }) {
  const { data, error } = await supabase.auth.verifyOtp(
    email ? { email, token, type: 'email' } : { phone, token, type: 'sms' }
  );
  if (error) throw error;
  await supabase.rpc('mark_guardian_joined');
  return data.session;
}

/** Staff share classroom tablets, so they use a password. */
export async function signInStaff(email, password) {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
  return data.session;
}

/* ── invitations ────────────────────────────────────────────────────────── */

/**
 * Creates or replaces a guardian's invitation. The code is generated server-side
 * so it is never guessable from anything the browser knows, and it expires.
 * Sending it — email, SMS, or a printed slip for the September meeting — is a
 * separate step, because schools do all three.
 */
export async function issueInvitation(guardianId, { days = 7 } = {}) {
  const { data, error } = await supabase.rpc('issue_invitation', {
    p_guardian_id: guardianId,
    p_days: days,
  });
  if (error) throw error;
  await logAudit('invite.issue', guardianId);
  return data;
}

export async function invitationStatus() {
  const { data, error } = await supabase
    .from('guardian')
    .select('id, name, email, phone, joined_at, invitation(code, expires_at, used_at)');
  if (error) throw error;
  return data.map(g => ({
    ...g,
    state: g.joined_at ? 'joined'
      : !g.invitation?.[0] ? 'none'
      : new Date(g.invitation[0].expires_at) < new Date() ? 'expired'
      : 'sent',
  }));
}

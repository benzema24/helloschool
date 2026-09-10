/**
 * Creates the auth accounts for everyone in 05_seed_data.sql.
 *
 * app_user.id must equal the Supabase auth user id — every access policy is
 * built on that link — so this runs BEFORE the seed SQL and pins each account
 * to the id already used in the data.
 *
 *   npm i @supabase/supabase-js
 *   SUPABASE_URL=... SUPABASE_SERVICE_KEY=... node bootstrap-users.mjs
 *
 * The service key bypasses row level security. Keep it out of the browser,
 * out of git, and rotate it when you are done.
 */
import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_KEY;
if (!url || !key) {
  console.error('Set SUPABASE_URL and SUPABASE_SERVICE_KEY first.');
  process.exit(1);
}
const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });

// Pulled straight out of 05_seed_data.sql so the two files cannot drift apart.
const sql = readFileSync(new URL('./05_seed_data.sql', import.meta.url), 'utf8');
const block = sql.split('insert into app_user')[1];
if (!block) { console.error('No app_user rows found in 05_seed_data.sql'); process.exit(1); }
const rows = [...block.split(';')[0].matchAll(
  /\(\s*'([0-9a-f-]{36})',\s*'[0-9a-f-]{36}',\s*'((?:[^']|'')*)',\s*'((?:[^']|'')*)',\s*'(\w+)'/g
)].map(m => ({ id: m[1], name: m[2].replace(/''/g, "'"), email: m[3].replace(/''/g, "'"), role: m[4] }));

console.log(`Found ${rows.length} accounts to create.`);

// A shared password is fine for a pilot everyone can log into. For anything
// real, drop the password and call inviteUserByEmail instead — the line below.
const DEMO_PASSWORD = process.env.DEMO_PASSWORD || 'Hello2026!';
const INVITE = process.env.INVITE === '1';

let made = 0, skipped = 0, failed = 0;
for (const r of rows) {
  try {
    if (INVITE) {
      const { error } = await admin.auth.admin.inviteUserByEmail(r.email, {
        data: { name: r.name, role: r.role },
      });
      if (error) throw error;
    } else {
      const { error } = await admin.auth.admin.createUser({
        id: r.id,                     // pinned, so app_user.id lines up
        email: r.email,
        password: DEMO_PASSWORD,
        email_confirm: true,
        user_metadata: { name: r.name, role: r.role },
      });
      if (error) throw error;
    }
    made++;
  } catch (e) {
    if (String(e.message || e).match(/already|registered|exists/i)) skipped++;
    else { failed++; console.error(`  ${r.email}: ${e.message || e}`); }
  }
}

console.log(`Created ${made}, already present ${skipped}, failed ${failed}.`);
if (!INVITE) console.log(`Everyone can sign in with: ${DEMO_PASSWORD}`);
console.log('Now run 05_seed_data.sql in the SQL editor.');

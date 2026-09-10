# Hello Academy of Education — demo

A static demo of the school platform. No build step, no server, no database. Everything
runs in the browser from a single `index.html`.

## Deploy to Vercel

**Option A — command line (fastest)**

```bash
npm i -g vercel      # once
cd hello-academy     # this folder
vercel               # follow the prompts, accept the defaults
vercel --prod        # when you are happy with the preview
```

Vercel will detect a static site. There is no framework to select and no build command
to set — if it asks, leave both empty and set the output directory to `./`.

**Option B — GitHub**

Push this folder to a repository, then on vercel.com choose *Add New → Project*, import
the repo, leave the framework preset as *Other*, and deploy.

**Option C — drag and drop**

On vercel.com choose *Add New → Project → Deploy without Git*, and drop this folder in.

You will get a URL like `hello-academy.vercel.app`. Send that to anyone; it opens on any
phone, tablet or laptop with nothing to install.

## Adding it to a phone's home screen

Because a web app manifest and icons ship with the site, the demo installs like an app:

- **iPhone** — open the URL in Safari, tap Share, then *Add to Home Screen*.
- **Android** — open in Chrome, tap the menu, then *Install app* / *Add to Home screen*.

It then launches full screen with the Hello Academy icon and no browser chrome, which is
worth doing before the meeting: it makes the demo look like the real product.

## Files

## Two applications, one deployment

| Address | Who it is for |
|---|---|
| `/` (`index.html`) | **Parents.** Sign in with the email or phone number given to the school. |
| `/staff.html` | **Staff.** Educators, teachers and administration, by work email and password. |

They are built from the same source and differ in one line. Each resolves only
its own accounts: a guardian's address entered on the staff page is simply not
found, so the wrong door never reveals that the right one exists. Each page
links to the other, for anyone who lands on the wrong one.

Give parents the plain address. Give staff the one ending in `/staff.html`.

| File | Purpose |
|---|---|
| `index.html` | The parent portal |
| `staff.html` | The staff and administration portal |
| `manifest.webmanifest`, `manifest-staff.webmanifest` | Home-screen install, one per portal |
| `icon-192.png`, `icon-512.png`, `icon-maskable-512.png` | App icons |
| `apple-touch-icon.png`, `favicon-32.png` | iOS home screen and browser tab |
| `og.png` | Link preview card for WhatsApp, Slack, email |
| `vercel.json` | Cache and security headers, and `noindex` so the demo stays unlisted |

## Connecting the real database

Both apps run on browser storage until you fill in two lines. Then they run on
Postgres, and the data is the same on every device.

1. Create a project at **supabase.com**.
2. In the SQL editor run, in order: `supabase/01_schema.sql`,
   `02_policies.sql`, `03_storage.sql`, `04_auth_functions.sql`.
3. Create the accounts: `cd supabase && npm install && SUPABASE_URL=… SUPABASE_SERVICE_KEY=… npm run bootstrap`
4. Run `supabase/05_seed_data.sql` to load the school.
5. Open **`config.js`** in this folder and paste the two values from
   *Settings → API*:

```js
window.HELLO_CONFIG = {
  supabaseUrl: 'https://xxxxxxxx.supabase.co',
  supabaseAnonKey: 'eyJhbGciOi...'
};
```

6. Redeploy.

That is the whole change. The anon key belongs in the browser: it grants
nothing by itself, because every table has row level security forced on. The
service key is used once, from your terminal, and never goes in this file.

With `config.js` filled in, the demo role cards stop working — there is a real
database now, so people sign in properly. Guardians get a one-time code by
email, staff use their password. A small chip in the top bar shows *Saved*,
*Saving…* or *Not saved*, so you can see the connection is alive.

Everything loads on sign-in and every change is pushed a moment later, so the
whole application works against the server without any screen being rewritten.
Photos go to a private bucket and the row keeps only the path; links are signed
and expire after an hour.

## The data is kept between visits (without a database)

Both portals save into the browser's own storage, so what you enter survives a
reload and you stay signed in. *Cilësimet → Ruajtja e të dhënave* (staff) and
*Profili* (parent) show when it last saved, download a copy as JSON, and clear
it.

The limit is worth being straight about: it is **per device and per browser**.
What a teacher enters on a tablet does not appear on a parent's phone, and an
iPhone in private mode keeps nothing. It is persistence, not sharing. Sharing
needs the database in `supabase/`.

Photos are kept until the browser's storage fills, then they are dropped while
everything else is saved, and you are told. Videos are never kept — the browser
discards them at reload regardless.

## Before the presentation

- The sparkle button in the top bar reseeds the demo and clears what you saved.
- The kindergarten's *today* starts empty on purpose — that is the beginning of demo
  flow 1. If you want to open on the parent view instead, run flow 1 once first.
- Albanian is the default. The SQ/EN switch in the top bar changes every string,
  including the content.
- The site is served with `noindex`, so it will not appear in search results. It is still
  reachable by anyone with the link, so treat the URL as semi-private.

## This is a demo, not a production system

There is no real authentication — the login page picks a role directly. All data lives
in the browser tab and disappears on reload. Access rules are enforced in the client for
the purpose of showing how they behave, not for security. `ARCHITECTURE.md` sets out
what changes on the way to production: real auth, Postgres with row-level security,
private photo storage with signed URLs, audit logging and GDPR export and deletion.

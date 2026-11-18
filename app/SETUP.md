# Nava Bhasha — App Setup

The app (`index.html`) is a single static page. It needs a free
[Supabase](https://supabase.com) project behind it for sign-up / log-in and
for saving progress. No build step, no server of your own.

Files in this folder:

| File | What it is |
|---|---|
| `index.html` | The whole app — landing page, auth, dashboard, session logging |
| `config.js` | Where your Supabase URL + anon key go (you edit this once) |
| `supabase-schema.sql` | The database tables + security rules (you run this once) |
| `SETUP.md` | This file |

---

## Step 1 — Create a free Supabase project

1. Go to [supabase.com](https://supabase.com) and sign in (GitHub sign-in works).
2. **New project** → pick a name (e.g. `nava-bhasha`), set a database password
   (save it in your password manager — the app never needs it, but you might),
   choose the region closest to you, and keep the **Free** plan.
3. Wait ~2 minutes while the project provisions.

## Step 2 — Create the tables

1. In your project dashboard, open **SQL Editor** → **New query**.
2. Paste the entire contents of `supabase-schema.sql` and click **Run**.
3. You should see "Success. No rows returned." That created three tables —
   `profiles`, `track_progress`, `sessions` — turned on Row Level Security so
   each user can only see their own data, and added a trigger that gives every
   new sign-up a profile plus the nine track rows.

## Step 3 — Connect the app to your project

1. In the dashboard, go to **Settings → API**.
2. Copy the **Project URL** and the **anon public** key.
3. Open `config.js` and replace the two placeholders:

   ```js
   window.NAVA_CONFIG = {
     SUPABASE_URL: "https://your-project-ref.supabase.co",
     SUPABASE_ANON_KEY: "eyJ...your-anon-key..."
   };
   ```

   The anon key is designed to be public — the Row Level Security policies
   from Step 2 are what actually protect the data. (Never put the
   `service_role` key in this file.)
4. Commit and push `config.js` with the real values filled in.

## Step 4 — Serve the app with GitHub Pages

1. Push this folder's contents to your GitHub repo (the app files must sit
   where you want them served — the repo root is simplest).
2. In the repo: **Settings → Pages**.
3. Under **Build and deployment**, choose **Deploy from a branch**, branch
   **main**, folder **/ (root)**, and save.
4. After a minute, Pages shows your URL:
   `https://<your-username>.github.io/<repo-name>/`
5. Open it — you should see the league landing page with working
   sign-up / log-in forms. (The app also works opened straight from disk,
   but Pages is the shareable home.)

## Step 5 — Set the auth Site URL (important, once Pages is live)

Supabase sends confirmation and password-reset emails whose links must point
back at your app:

1. Dashboard → **Authentication → URL Configuration**.
2. Set **Site URL** to your GitHub Pages URL from Step 4, e.g.
   `https://<your-username>.github.io/<repo-name>/`
3. Save.

### How confirmation emails behave on the free tier

- By default, **email confirmation is ON**: a new user signs up, gets a
  "Confirm your signup" email, clicks the link, and only then can log in.
  The app detects this and tells them to check their email.
- Free-tier email sending is rate-limited (a handful of emails per hour) and
  the mails come from Supabase's shared sender, so they occasionally land in
  spam. Fine for a personal league; if you outgrow it, you can plug in your
  own SMTP under **Authentication → Emails**.
- If you'd rather skip confirmation while testing: **Authentication →
  Providers → Email** → turn off **Confirm email**. Anyone can then sign up
  and log in immediately with any address — convenient, less safe. Your call.
- The confirmation link only works if the **Site URL** above is set to the
  Pages URL (or to `http://localhost:…` while testing locally) — that's the
  one setting people usually miss.

## Daily use

- Sign up once, log in, and the dashboard shows your nine tracks, total
  points, and streak.
- **Week 1 is placement week**: with no sessions logged yet, the dashboard
  runs in placement mode — set each track's level (0–5) from its card as you
  probe it.
- **Log today's session** each evening: anchor (15 min), two satellites
  (5 min each — the card suggests the two most-due languages), script sprint
  (5 min). Points are automatic: 10 per minute, split by block to each
  language. Chaos day? Flip the **eclipse** toggle — a 10-minute anchor-only
  session that keeps your streak alive.
- **Sundays** end with the Boss Fight: pick the track, record a win (+100)
  or showing up (+25).

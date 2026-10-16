# THINKAKAIN — a 30-level puzzle tower

A static, no-build-step puzzle game (vanilla HTML/CSS/JS) hosted on **GitHub Pages**,
with **Supabase** as the server-authoritative backend: auth, progress, and every
answer live server-side, so view-source reveals nothing.

Live at **https://thinkakain.github.io/thinkakain/** (repo `thinkakain/thinkakain`).

## How it works

- Each level is one self-contained page (`levels/level-N.html`), built one at a
  time from [`levels/_template.html`](levels/_template.html).
- **Answers never ship in client code.** All validation runs in Postgres
  `SECURITY DEFINER` functions; the `level_secrets` table has no client read
  access at all (RLS enabled, zero policies).
- Players register with **username + password** (Supabase Auth derives an
  internal `<username>@thinkakain.app` email; players never see it). Progress
  (`highest_level`, cleared levels) is server-side and resumes on any device.
- `BUILT_LEVELS` in `js/engine.js` and the `BUILT` constant in `index.html`
  track how many levels exist — bump both each time a level ships.

## Design rules (standing)

- **No explanatory text** on levels. No hint buttons. The clue lives in the
  page itself — the player figures out the rest through trial and error.
- **Every level is standalone.** Never reuse a previous level's answer.
- Passwords are hashed by Supabase Auth and never stored by us; passcodes live
  only in `level_secrets` and are checked server-side.

## One-time Supabase setup

1. **Create a project** at [supabase.com](https://supabase.com) (free tier is fine).
   Note the project URL and the **publishable** key (Project Settings → API).
   Never use the `service_role` key in this repo.

2. **Run the schema.** In the Supabase dashboard go to
   Database → SQL → New query, paste the entire contents of
   [`supabase/schema.sql`](supabase/schema.sql), and run it.
   It wipes the previous build's tables first, then creates the fresh
   tables, Row Level Security policies, and RPC functions.
   It contains **no secrets** and is safe to commit.

3. **Seed the secrets — per level, as built.** Open
   [`supabase/seed.sql`](supabase/seed.sql) (git-ignored — never commit it),
   add one row for the new level (see the examples in the file), paste it into
   a SQL editor query, and run it. The file is idempotent: re-running is safe.
   Verify in the Table editor that `level_secrets` has one row per built level.

4. **Wire up the client.** Copy your values into [`js/config.js`](js/config.js):
   ```js
   window.ThinkakainConfig = {
     SUPABASE_URL: "https://xyzcompany.supabase.co",
     SUPABASE_ANON_KEY: "sb_publishable_..."
   };
   ```
   The publishable key is public by design — RLS protects everything.

5. **Auth settings.** In the dashboard go to Authentication → Providers →
   Email and make sure **"Confirm email" is OFF** (the derived
   `@thinkakain.app` addresses can't receive mail). Everything else can stay
   default.

## Adding a level

1. Copy [`levels/_template.html`](levels/_template.html) → `levels/level-N.html`.
2. Set the level number/title in `initLevel`, build the puzzle inside
   `<main id="level-main">`, and pick ONE resolver:
   - passcode → `Thinkakain.mountPasscode(N, {...})`
   - timed hold → `Thinkakain.submitHold(N, ms)` then `Thinkakain.onSolved(…)`
   - click sequence → `Thinkakain.submitSequence(N, ids)` then `Thinkakain.onSolved(…)`
3. **Add the secret** to `level_secrets` via the SQL editor — never in the repo:
   ```sql
   insert into level_secrets (level, answer)
     values (1, 'YOURCODE')
     on conflict (level) do update set answer = excluded.answer;
   ```
   For hold levels set `hold_answer` (word; hold seconds = its letter count,
   ±400 ms). For sequence levels set `sequence` (int array of the click order).
   For public display data (ticker words, canvas data — never answers) put it
   in `clues` as JSON and fetch it client-side with `Thinkakain.clues(N)`.
4. Bump `BUILT_LEVELS` in `js/engine.js` **and** the `BUILT` constant in
   `index.html` so the level grid, Continue button, and Next-level links
   include the new level.

## Push discipline

Pushes go through `gh_push.py`, which replaces the whole repo tree from local
files — so **always push with `--preserve js/config.js`**. That flag fetches
the remote copy of the config (which holds Nopy's pasted publishable key)
before building the tree, so his key is never overwritten. Overwriting it once
took the live site down as "Tower offline" — it must not recur.

## File map

| Path | What |
|---|---|
| `index.html` | Landing: login/register gate, level grid, Continue |
| `levels/level-N.html` | One self-contained puzzle page per level (0 built so far) |
| `levels/_template.html` | Copy-paste template for new levels |
| `css/style.css` | Shared dark tower aesthetic, mobile-first |
| `js/config.js` | Supabase URL + publishable key (Nopy fills in; preserved on push) |
| `js/backend.js` | Supabase data layer: auth, progress, clue fetch, RPC validators |
| `js/engine.js` | UI engine: headers, passcode forms, success overlay (zero answers) |
| `supabase/schema.sql` | Tables + RLS + RPC functions — safe to commit |
| `supabase/seed.sql` | Answers/sequences — **git-ignored, never commit** |
| `.gitignore` | Keeps `seed.sql` (and `.env`) out of the repo |

## Security notes

- `level_secrets` has RLS enabled with **no policies**: clients cannot
  SELECT/INSERT/UPDATE/DELETE it, period. Only `SECURITY DEFINER` functions
  touch it.
- `level_clears` rows are written exclusively by those functions; clients have
  read-only access to their own rows.
- `progress` allows owners to read and update their own row (cosmetic level
  grid). This grants no answers: every level's verdict comes from an RPC.
- Supplied `clues` payloads are public page content by design (ticker words,
  canvas data, story text). A determined player can always read what the page
  shows them — the protection is against static answer harvesting from
  view-source or the public repo.

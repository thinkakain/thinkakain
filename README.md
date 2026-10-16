# THINKAKAIN — a 30-level puzzle tower

A static, no-build-step puzzle game (vanilla HTML/CSS/JS) hosted on **GitHub Pages**,
with **Supabase** as the server-authoritative backend: auth, progress, and every
answer live server-side, so view-source reveals nothing.

## How it works

- Each level is one self-contained page (`levels/level-N.html`). The player
  enters a passcode or performs an interactive action (hold timing, star-click
  sequence) to advance.
- **Answers never ship in client code.** All validation runs in Postgres
  `SECURITY DEFINER` functions; the `floor_secrets` table has no client read
  access at all (RLS enabled, zero policies).
- Every 5th level is a **boss gate** validated against the marks the *server*
  recorded for the player's previous four levels — un-Googlable by construction.
- Players register with **username + password** (Supabase Auth derives an
  internal `<username>@overthink.local` email; players never see it). Progress
  (`highest_floor`, cleared levels, marks) is server-side and resumes on any
  device. Marks are also mirrored to localStorage purely as a convenience
  display — never trusted for validation.

## One-time Supabase setup

1. **Create a project** at [supabase.com](https://supabase.com) (free tier is fine).
   Note the project URL and the **anon public** key
   (Project Settings → API). Never use the `service_role` key in this repo.

2. **Run the schema.** In the Supabase dashboard go to
   Database → SQL → New query, paste the entire contents of
   [`supabase/schema.sql`](supabase/schema.sql), and run it.
   This creates tables, Row Level Security policies, and the RPC functions.
   It contains **no secrets** and is safe to commit.

3. **Seed the secrets — once.** Open [`supabase/seed.sql`](supabase/seed.sql),
   paste it into a **new** SQL editor query, and run it. Then **delete your
   local copy** (it is already in `.gitignore`). Never commit it — the repo
   is public. Verify in the Table editor that `floor_secrets` has 10 rows.

4. **Wire up the client.** Copy your values into [`js/config.js`](js/config.js):
   ```js
   window.ThinkakainConfig = {
     SUPABASE_URL: "https://xyzcompany.supabase.co",
     SUPABASE_ANON_KEY: "eyJhbGciOi..."
   };
   ```
   The anon key is public by design — RLS protects everything.

5. **Auth settings.** In the dashboard go to Authentication → Providers →
   Email and make sure **"Confirm email" is OFF** (the derived
   `@overthink.local` addresses can't receive mail). Everything else can stay
   default.

6. **Deploy to GitHub Pages.** Push this folder's contents to a repo
   (as the repo root, or under `docs/`), then
   Settings → Pages → Deploy from a branch → `main` / `/root` (or `/docs`).
   The game is fully static — no build step.

7. **Smoke test.** Open the site, create an account, clear Level 1
   (watch the tab title), and confirm the tower marks you and Level 2 unlocks.

## Adding levels 11–30

1. Copy [`levels/_template.html`](levels/_template.html) → `levels/level-11.html`.
2. Set the level number/title in `initLevel`, write the puzzle, add two hints,
   and pick the resolver:
   - passcode → `Thinkakain.mountPasscode(11, {...})`
   - boss gate → `Thinkakain.mountBoss(11, {...})`
   - timed hold → `Thinkakain.submitHold(11, ms)` then `Thinkakain.onSolved(res.mark, …)`
   - click sequence → `Thinkakain.submitSequence(11, ids)` then `Thinkakain.onSolved(res.mark, …)`
3. **Add the secrets** to `floor_secrets` (SQL editor — never in the repo):
   ```sql
   insert into floor_secrets (level, answer, mark, clues) values
     (11, 'YOURCODE', 'X', '{}');
   ```
   For hold levels set `hold_answer` (word; hold seconds = its letter count).
   For sequence levels set `sequence` (int array). For public display data
   (ticker words, canvas words, story HTML…) put it in `clues` as JSON —
   fetch it client-side with `Thinkakain.clues(11)`.
4. Bump `BUILT_LEVELS` in `js/engine.js` **and** the `BUILT` constant in
   `index.html` so the level grid, Continue button, and Next-level links
   include the new level.
5. Boss levels: every 5th level should call `mountBoss` — the
   `validate_boss` function automatically checks marks from the previous
   four levels, no per-level configuration needed.

## File map

| Path | What |
|---|---|
| `index.html` | Landing: login/register gate, how-to-play, level grid, marks, Continue |
| `levels/level-N.html` | One self-contained puzzle page per level (1–10 built) |
| `levels/_template.html` | Copy-paste template for levels 11–30 |
| `css/style.css` | Shared dark tower aesthetic, mobile-first |
| `js/config.js` | Supabase URL + anon key (you fill these in) |
| `js/backend.js` | Supabase data layer: auth, progress, clue fetch, RPC validators |
| `js/engine.js` | UI engine: headers, hints, forms, success overlay (zero answers) |
| `supabase/schema.sql` | Tables + RLS + RPC functions — safe to commit |
| `supabase/seed.sql` | Answers/marks/sequences — **git-ignored, run once, then delete** |
| `.gitignore` | Keeps `seed.sql` (and `.env`) out of the repo |

## Security notes

- `floor_secrets` has RLS enabled with **no policies**: clients cannot
  SELECT/INSERT/UPDATE/DELETE it, period. Only `SECURITY DEFINER` functions
  touch it.
- `floor_marks` / `floor_clears` are written exclusively by those functions;
  clients have read-only access to their own rows.
- `progress` allows owners to read and update their own row (cosmetic level
  grid). This grants no answers: boss gates re-validate against server-side
  marks, and every level's verdict comes from an RPC.
- Supplied `clues` payloads are public page content by design (ticker words,
  canvas words, the woven story). A determined player can always read what
  the page shows them — the protection is against static answer harvesting
  from view-source or the public repo.

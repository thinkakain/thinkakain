/* ============================================================
   THINKAKAIN — Supabase configuration
   ------------------------------------------------------------
   Fill in your project's URL and anon key (Supabase dashboard →
   Project Settings → API). Then this file is safe to commit.

   The "anon" key is PUBLIC BY DESIGN: it ships in client-side code
   for every Supabase app. It grants no power on its own — every
   table here is protected by Row Level Security, the answers table
   (floor_secrets) has NO client read access at all, and all answer
   checking runs inside SECURITY DEFINER Postgres functions.

   NEVER put the service_role key here (or anywhere in the repo).
   ============================================================ */
window.ThinkakainConfig = {
  SUPABASE_URL: "https://uujnmldifkbcirvagglo.supabase.co", // from chat 2026-10-15 18:07 CDT
  SUPABASE_ANON_KEY: "sb_publishable_WoDAdJ0-r2KlYEplwIXJXg_UuNgY_Px"  // fill after the secure form
};

/* ============================================================
   THINKAKAIN — Supabase data layer (real backend, no stubs)
   ------------------------------------------------------------
   All answer validation happens server-side in Postgres
   SECURITY DEFINER functions (see supabase/schema.sql).
   This file NEVER sees answers — it only passes guesses through
   and receives {correct} verdicts.

   Auth uses username + password. Because Supabase Auth needs an
   email, the app derives one: <username>@thinkakain.app.
   Players never see or type the email.
   ============================================================ */
(function () {
  "use strict";

  var client = null;

  function config() { return window.ThinkakainConfig || {}; }

  function isConfigured() {
    var c = config();
    return !!(c.SUPABASE_URL && c.SUPABASE_ANON_KEY &&
              c.SUPABASE_URL.indexOf("http") === 0);
  }

  function db() {
    if (!window.supabase) {
      throw new Error("Supabase JS library failed to load (check your connection).");
    }
    if (!client) {
      if (!isConfigured()) {
        throw new Error("Supabase is not configured yet — see README, " +
                        "“One-time Supabase setup”.");
      }
      client = window.supabase.createClient(
        config().SUPABASE_URL, config().SUPABASE_ANON_KEY);
    }
    return client;
  }

  function validUsername(u) { return /^[A-Za-z0-9_]{3,16}$/.test(u); }
  function emailFor(u) { return u.toLowerCase() + "@thinkakain.app"; }

  function friendlyError(err) {
    var m = String((err && err.message) || err || "");
    if (/username taken/i.test(m)) return "That username is taken — try another.";
    if (/already registered|already exists/i.test(m)) {
      return "That username is taken — try signing in instead.";
    }
    if (/invalid login|invalid credentials/i.test(m)) return "Wrong username or password.";
    if (/invalid username/i.test(m)) {
      return "Username must be 3–16 characters: letters, numbers, underscore.";
    }
    if (/password/i.test(m)) return "Password must be at least 6 characters.";
    if (/not authenticated/i.test(m)) return "Your session expired — please sign in again.";
    return m || "Something went wrong. Try again.";
  }

  async function ensureProfile(username) {
    var r = await db().rpc("ensure_profile", { p_username: username });
    if (r.error) throw new Error(friendlyError(r.error));
    return r.data;
  }

  window.Backend = {
    isConfigured: isConfigured,
    friendlyError: friendlyError,

    signUp: async function (username, password) {
      username = String(username).trim();
      if (!validUsername(username)) throw new Error(friendlyError("invalid username"));
      var r = await db().auth.signUp({ email: emailFor(username), password: password });
      if (r.error) throw new Error(friendlyError(r.error));
      // NOTE: keep "Confirm email" OFF in Supabase Auth settings —
      // @thinkakain.app addresses can't receive mail.
      await ensureProfile(username);
      return r.data;
    },

    signIn: async function (username, password) {
      username = String(username).trim();
      var r = await db().auth.signInWithPassword({
        email: emailFor(username), password: password
      });
      if (r.error) throw new Error(friendlyError(r.error));
      await ensureProfile(username); // idempotent: backfills missing rows
      return r.data;
    },

    signOut: async function () { await db().auth.signOut(); },

    getSession: async function () {
      var r = await db().auth.getSession();
      if (r.error) throw r.error;
      return r.data.session || null;
    },

    onAuthChange: function (cb) { return db().auth.onAuthStateChange(cb); },

    // Server is the source of truth: highest unlocked level and cleared
    // levels. All reads are RLS-scoped to the player.
    fetchProgress: async function () {
      var u = (await db().auth.getUser()).data.user;
      if (!u) return null;
      var pr = await db().from("progress")
        .select("highest_level,username").eq("user_id", u.id).maybeSingle();
      if (pr.error) throw pr.error;
      var cl = await db().from("level_clears").select("level").eq("user_id", u.id);
      if (cl.error) throw cl.error;
      var cleared = (cl.data || []).map(function (r) { return r.level; });
      return {
        highest_level: (pr.data && pr.data.highest_level) || 1,
        username: (pr.data && pr.data.username) || "",
        cleared: cleared
      };
    },

    // Public per-level display data. Contains no answers.
    getClues: async function (level) {
      var r = await db().rpc("get_level_clues", { p_level: level });
      if (r.error) throw r.error;
      return r.data || {};
    },

    // Each returns {correct: bool}.
    validateGuess: async function (level, guess) {
      var r = await db().rpc("validate_guess", { p_level: level, p_guess: guess });
      if (r.error) throw r.error;
      return r.data;
    },
    validateHold: async function (level, holdMs) {
      var r = await db().rpc("validate_hold",
        { p_level: level, p_hold_ms: Math.round(holdMs) });
      if (r.error) throw r.error;
      return r.data;
    },
    validateSequence: async function (level, seq) {
      var r = await db().rpc("validate_sequence", { p_level: level, p_seq: seq });
      if (r.error) throw r.error;
      return r.data;
    },
    // Equation levels: submits the full arrangement; the server checks
    // tile multiset + mathematical truth. Returns {correct: bool}.
    validateEquation: async function (level, expr) {
      var r = await db().rpc("validate_equation", { p_level: level, p_expr: expr });
      if (r.error) throw r.error;
      return r.data;
    },
    // Pouring levels: submits the move list [[from,to],...]; the server
    // replays the physics and checks the goal. Returns {correct: bool}.
    validatePours: async function (level, moves) {
      var r = await db().rpc("validate_pours", { p_level: level, p_moves: moves });
      if (r.error) throw r.error;
      return r.data;
    },
    // Magnet levels: submits the move string (UDLR); the server replays
    // the slides and checks the goal. Returns {correct: bool}.
    validateMagnet: async function (level, movesStr) {
      var r = await db().rpc("validate_magnet", { p_level: level, p_moves: movesStr });
      if (r.error) throw r.error;
      return r.data;
    },
    // Life-stage levels: submits the click history (baby indices); the server
    // replays the aging and checks for nine teens. Returns {correct: bool}.
    validateLife: async function (level, clicks) {
      var r = await db().rpc("validate_life", { p_level: level, p_clicks: clicks });
      if (r.error) throw r.error;
      return r.data;
    }
  };
})();

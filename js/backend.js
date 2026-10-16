/* ============================================================
   OVERTHINK — Supabase data layer (real backend, no stubs)
   ------------------------------------------------------------
   All answer validation happens server-side in Postgres
   SECURITY DEFINER functions (see supabase/schema.sql).
   This file NEVER sees answers — it only passes guesses through
   and receives {correct, mark} verdicts.

   Auth uses username + password. Because Supabase Auth needs an
   email, the app derives one: <username>@overthink.local.
   Players never see or type the email.
   ============================================================ */
(function () {
  "use strict";

  var client = null;

  function config() { return window.OverthinkConfig || {}; }

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
  function emailFor(u) { return u.toLowerCase() + "@overthink.local"; }

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
      // @overthink.local addresses can't receive mail.
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

    // Server is the source of truth: highest unlocked level, cleared
    // levels, and earned marks. All reads are RLS-scoped to the player.
    fetchProgress: async function () {
      var u = (await db().auth.getUser()).data.user;
      if (!u) return null;
      var pr = await db().from("progress")
        .select("highest_floor,username").eq("user_id", u.id).maybeSingle();
      if (pr.error) throw pr.error;
      var cl = await db().from("floor_clears").select("floor").eq("user_id", u.id);
      if (cl.error) throw cl.error;
      var mk = await db().from("floor_marks").select("floor,mark").eq("user_id", u.id);
      if (mk.error) throw mk.error;
      var cleared = (cl.data || []).map(function (r) { return r.floor; });
      var marks = {};
      (mk.data || []).forEach(function (r) { marks[r.floor] = r.mark; });
      return {
        highest_floor: (pr.data && pr.data.highest_floor) || 1,
        username: (pr.data && pr.data.username) || "",
        cleared: cleared,
        marks: marks
      };
    },

    // Public per-level display data (ticker words, canvas word, story…).
    // Contains no answers.
    getClues: async function (level) {
      var r = await db().rpc("get_floor_clues", { p_floor: level });
      if (r.error) throw r.error;
      return r.data || {};
    },

    // Each returns {correct: bool, mark: "X"|null}. Mark only when correct.
    validateGuess: async function (level, guess) {
      var r = await db().rpc("validate_guess", { p_floor: level, p_guess: guess });
      if (r.error) throw r.error;
      return r.data;
    },
    validateHold: async function (level, holdMs) {
      var r = await db().rpc("validate_hold",
        { p_floor: level, p_hold_ms: Math.round(holdMs) });
      if (r.error) throw r.error;
      return r.data;
    },
    validateSequence: async function (level, seq) {
      var r = await db().rpc("validate_sequence", { p_floor: level, p_seq: seq });
      if (r.error) throw r.error;
      return r.data;
    },
    // Boss gates: {correct: bool}. No mark — gates award none.
    validateBoss: async function (level, letters) {
      var r = await db().rpc("validate_boss", { p_floor: level, p_letters: letters });
      if (r.error) throw r.error;
      return r.data;
    }
  };
})();

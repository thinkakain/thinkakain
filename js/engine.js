/* ============================================================
   THINKAKAIN — UI engine (vanilla JS)
   ------------------------------------------------------------
   Renders headers, passcode forms, and success overlays.
   Contains ZERO answers or solutions — every verdict comes
   from the server via js/backend.js.

   Level pages use (all async where noted):
     await Thinkakain.initLevel({level, title, ...}) -> bool playable
     Thinkakain.mountPasscode(level, {wrongMessage, successFlavor})
     await Thinkakain.submitHold(level, elapsedMs)  -> {correct}
     await Thinkakain.submitSequence(level, ids)    -> {correct}
     await Thinkakain.submitEquation(level, expr)  -> {correct}
     await Thinkakain.submitPours(level, moves)     -> {correct}
     Thinkakain.onSolved(flavorHtml)                -> success overlay
     await Thinkakain.clues(level)                  -> public clue payload
   ============================================================ */
(function () {
  "use strict";

  var TOTAL_LEVELS = 30;
  var BUILT_LEVELS = 20; // bump as levels are built, one at a time

  var cfg = null;
  var progressCache = null;

  /* ---------------- small utilities ---------------- */

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function make(tag, cls, html) {
    var d = document.createElement(tag);
    if (cls) d.className = cls;
    if (html != null) d.innerHTML = html;
    return d;
  }

  async function getProgress(force) {
    if (!force && progressCache) return progressCache;
    progressCache = await window.Backend.fetchProgress();
    return progressCache;
  }

  /* ---------------- header / locked / errors ---------------- */

  function renderHeader(p) {
    var header = document.getElementById("tower-header");
    if (!header) return;
    header.innerHTML = "";

    var back = make("a", "back-link", "&larr; Tower");
    back.href = "../index.html";

    var mid = make("div", "header-mid");
    mid.appendChild(make("div", "level-label",
      esc(cfg.levelLabel || ("Level " + cfg.level))));
    if (cfg.title) mid.appendChild(make("div", "level-title", esc(cfg.title)));

    header.appendChild(back);
    header.appendChild(mid);

    if (!cfg.hideProgress) {
      var prog = make("div", "header-progress");
      var pct = Math.round((p.cleared.length / TOTAL_LEVELS) * 100);
      prog.appendChild(make("div", "hp-bar",
        '<div class="hp-fill" style="width:' + pct + '%"></div>'));
      prog.appendChild(make("div", "hp-text", p.cleared.length + "/" + TOTAL_LEVELS));
      header.appendChild(prog);
    }
  }

  function renderNotice(html) {
    var main = document.getElementById("level-main");
    if (!main) return;
    main.innerHTML = "";
    var card = make("div", "puzzle-card locked-card", html);
    var a = make("a", "btn", "Back to the tower");
    a.href = "../index.html";
    card.appendChild(a);
    main.appendChild(card);
  }

  function renderReviewHeader() {
    var header = document.getElementById("tower-header");
    if (!header) return;
    header.innerHTML = "";
    var back = make("a", "back-link", "&larr; Tower");
    back.href = "../index.html?review=1";
    var mid = make("div", "header-mid");
    mid.appendChild(make("div", "level-label",
      esc(cfg.levelLabel || ("Level " + cfg.level)) + " · REVIEW"));
    if (cfg.title) mid.appendChild(make("div", "level-title", esc(cfg.title)));
    header.appendChild(back);
    header.appendChild(mid);
  }

  /* ---------------- success ---------------- */

  function showSuccess(flavorHtml) {
    progressCache = null; // progress changed — refetch next time
    var overlay = make("div", "success-overlay");
    var card = make("div", "success-card");
    card.appendChild(make("div", "check-wrap",
      '<svg class="check-svg" viewBox="0 0 56 56">' +
      '<circle cx="28" cy="28" r="25"/>' +
      '<path d="M17 29l8 8 15-16"/>' +
      "</svg>"));
    var txt = '<div class="success-kicker">Correct!</div>';
    if (flavorHtml) txt += '<div class="success-flavor">' + flavorHtml + "</div>";
    card.appendChild(make("div", "success-text", txt));
    var next = make("a", "btn next-btn", "");
    if (cfg.level >= BUILT_LEVELS) {
      next.href = "../index.html";
      next.textContent = "Back to the tower";
    } else {
      next.href = "level-" + (cfg.level + 1) + ".html";
      next.textContent = "Next level \u2192"; // arrow, not emoji
    }
    card.appendChild(next);
    overlay.appendChild(card);
    document.body.appendChild(overlay);
  }

  function shakeIt(form, msgEl, message) {
    if (msgEl) msgEl.textContent = message;
    form.classList.remove("shake");
    void form.offsetWidth; // restart the CSS animation
    form.classList.add("shake");
  }

  /* ---------------- public API ---------------- */

  // Gate: configured backend -> logged-in session -> level unlocked.
  // Returns true when the level is playable.
  async function initLevel(options) {
    cfg = options;
    if (!window.Backend.isConfigured()) {
      renderNotice("<div class='locked-big'>Not configured</div>" +
        "<p class='muted'>The tower's backend isn't set up yet. " +
        "See README → One-time Supabase setup.</p>");
      return false;
    }
    // Review mode (?review=1): skip login and level locks so the
    // designer can open any level page directly. Reveals no answers —
    // every verdict still comes from the server.
    if (/[?&]review=1/.test(location.search)) {
      renderReviewHeader();
      return true;
    }
    var session;
    try {
      session = await window.Backend.getSession();
    } catch (e) {
      renderNotice("<div class='locked-big'>Connection error</div>" +
        "<p class='muted'>" + esc(e.message) + "</p>");
      return false;
    }
    if (!session) {
      location.href = "../index.html"; // the landing page hosts login
      return false;
    }
    var p;
    try {
      p = await getProgress();
    } catch (e) {
      renderNotice("<div class='locked-big'>Hmm</div>" +
        "<p class='muted'>Could not load your progress: " +
        esc(window.Backend.friendlyError(e)) + "</p>");
      return false;
    }
    renderHeader(p);
    if (options.level > p.highest_level) {
      renderNotice("<div class='locked-big'>Locked</div>" +
        "<p class='muted'>This level opens after you clear Level " +
        p.highest_level + ".</p>");
      return false;
    }
    return true;
  }

  // Passcode form. The guess is validated server-side; the client
  // never knows the answer.
  function mountPasscode(level, opts) {
    opts = opts || {};
    var slot = document.getElementById("passcode-slot");
    if (!slot || !cfg) return;
    var form = make("form", "passcode-form");
    form.setAttribute("autocomplete", "off");
    var input = make("input", "passcode-input");
    input.type = "text";
    input.placeholder = "Enter passcode";
    input.setAttribute("aria-label", "Passcode");
    input.setAttribute("autocomplete", "off");
    input.setAttribute("autocapitalize", "characters");
    input.setAttribute("spellcheck", "false");
    var btn = make("button", "btn", "Unlock");
    btn.type = "submit";
    var msg = make("div", "passcode-msg");
    form.appendChild(input);
    form.appendChild(btn);
    slot.appendChild(form);
    slot.appendChild(msg);

    var busy = false;
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      if (busy) return;
      busy = true;
      btn.disabled = true;
      msg.textContent = "";
      var guess = input.value;
      if (opts.normalize) guess = opts.normalize(guess);
      window.Backend.validateGuess(level, guess).then(function (res) {
        busy = false;
        btn.disabled = false;
        if (res && res.correct) {
          showSuccess(opts.successFlavor);
        } else {
          shakeIt(form, msg, opts.wrongMessage || "Not quite. Try again.");
        }
      }).catch(function (err) {
        busy = false;
        btn.disabled = false;
        shakeIt(form, msg, window.Backend.friendlyError(err));
      });
    });
  }

  // Interactive levels: thin wrappers over the backend validators.
  // Each resolves to {correct}. Levels call onSolved() on success.
  function submitHold(level, elapsedMs) {
    return window.Backend.validateHold(level, elapsedMs);
  }
  function submitSequence(level, ids) {
    return window.Backend.validateSequence(level, ids);
  }
  function submitEquation(level, expr) {
    return window.Backend.validateEquation(level, expr);
  }
  function submitPours(level, moves) {
    return window.Backend.validatePours(level, moves);
  }
  function submitMagnet(level, movesStr) {
    return window.Backend.validateMagnet(level, movesStr);
  }
  function onSolved(flavorHtml) {
    showSuccess(flavorHtml);
  }

  // Public per-level display data (no answers). Throws when offline.
  function clues(level) {
    return window.Backend.getClues(level);
  }

  window.Thinkakain = {
    initLevel: initLevel,
    mountPasscode: mountPasscode,
    submitHold: submitHold,
    submitSequence: submitSequence,
    submitEquation: submitEquation,
    submitPours: submitPours,
    submitMagnet: submitMagnet,
    onSolved: onSolved,
    clues: clues,
    getProgress: getProgress,
    TOTAL_LEVELS: TOTAL_LEVELS,
    BUILT_LEVELS: BUILT_LEVELS
  };
})();

/* ============================================================
   OVERTHINK — UI engine (vanilla JS)
   ------------------------------------------------------------
   This file renders headers, hints, passcode forms, and success
   overlays. It contains ZERO answers, marks, or solutions — every
   verdict comes from the server via js/backend.js.

   Floor pages use (all async where noted):
     await Overthink.initFloor({floor, title, ...}) -> bool playable
     Overthink.hints(slotId, [hint1, hint2])
     Overthink.mountPasscode(floor, {wrongMessage, successFlavor})
     Overthink.mountBoss(floor, {wrongMessage, successFlavor})
     await Overthink.submitHold(floor, elapsedMs)  -> {correct, mark}
     await Overthink.submitSequence(floor, ids)    -> {correct, mark}
     Overthink.onSolved(mark, flavorHtml)          -> success overlay
     await Overthink.clues(floor)                  -> public clue payload
     Overthink.cachedMarks()                       -> {floor: mark} (display only)
   ============================================================ */
(function () {
  "use strict";

  var TOTAL_FLOORS = 30;
  var BUILT_FLOORS = 10; // bump as floors 11-30 are added

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

  // Marks are cached locally ONLY as a convenience display
  // ("your marks: K E _ _"). They are never trusted for validation —
  // boss gates re-check against the server's floor_marks records.
  var MARKS_KEY = "overthink_marks";
  function cacheMark(floor, mark) {
    if (!mark) return;
    try {
      var m = JSON.parse(localStorage.getItem(MARKS_KEY) || "{}");
      m[floor] = mark;
      localStorage.setItem(MARKS_KEY, JSON.stringify(m));
    } catch (e) {}
  }
  function cachedMarks() {
    try { return JSON.parse(localStorage.getItem(MARKS_KEY) || "{}"); }
    catch (e) { return {}; }
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
    mid.appendChild(make("div", "floor-label",
      esc(cfg.floorLabel || ("Floor " + cfg.floor))));
    if (cfg.title) mid.appendChild(make("div", "floor-title", esc(cfg.title)));

    header.appendChild(back);
    header.appendChild(mid);

    if (!cfg.hideProgress) {
      var prog = make("div", "header-progress");
      var pct = Math.round((p.cleared.length / TOTAL_FLOORS) * 100);
      prog.appendChild(make("div", "hp-bar",
        '<div class="hp-fill" style="width:' + pct + '%"></div>'));
      prog.appendChild(make("div", "hp-text", p.cleared.length + "/" + TOTAL_FLOORS));
      header.appendChild(prog);
    }
  }

  function renderNotice(html) {
    var main = document.getElementById("floor-main");
    if (!main) return;
    main.innerHTML = "";
    var card = make("div", "puzzle-card locked-card", html);
    var a = make("a", "btn", "Back to the tower");
    a.href = "../index.html";
    card.appendChild(a);
    main.appendChild(card);
  }

  /* ---------------- success ---------------- */

  function showSuccess(mark, flavorHtml) {
    if (mark) cacheMark(cfg.floor, mark);
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
    if (mark) {
      txt += '<div class="success-mark">The tower marks you: <b>' +
             esc(mark) + "</b></div>";
    }
    card.appendChild(make("div", "success-text", txt));
    var next = make("a", "btn next-btn", "");
    if (cfg.floor >= BUILT_FLOORS) {
      next.href = "../index.html";
      next.textContent = "Back to the tower";
    } else {
      next.href = "floor-" + (cfg.floor + 1) + ".html";
      next.textContent = "Next floor \u2192"; // arrow, not emoji
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

  // Gate: configured backend -> logged-in session -> floor unlocked.
  // Returns true when the floor is playable.
  async function initFloor(options) {
    cfg = options;
    if (!window.Backend.isConfigured()) {
      renderNotice("<div class='locked-big'>Not configured</div>" +
        "<p class='muted'>The tower's backend isn't set up yet. " +
        "See README → One-time Supabase setup.</p>");
      return false;
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
    if (options.floor > p.highest_floor) {
      renderNotice("<div class='locked-big'>Locked</div>" +
        "<p class='muted'>This floor opens after you clear Floor " +
        p.highest_floor + ".</p>");
      return false;
    }
    return true;
  }

  // Two-level hints: one button reveals Hint 1, then Hint 2.
  function hints(slotId, hintArray) {
    var slot = document.getElementById(slotId);
    if (!slot || !hintArray || !hintArray.length) return;
    var box = make("div", "hint-box");
    var btn = make("button", "btn btn-ghost hint-btn", "Reveal a hint");
    btn.type = "button";
    var shown = 0;
    btn.addEventListener("click", function () {
      if (shown < hintArray.length) {
        box.appendChild(make("div", "hint-text",
          "<span class='hint-tag'>Hint " + (shown + 1) + "</span>" +
          esc(hintArray[shown])));
        shown++;
        if (shown >= hintArray.length) {
          btn.textContent = "No more hints";
          btn.disabled = true;
        } else {
          btn.textContent = "Reveal another hint";
        }
      }
    });
    slot.appendChild(btn);
    slot.appendChild(box);
  }

  // Passcode form. The guess is validated server-side; the client
  // never knows the answer.
  function mountPasscode(floor, opts) {
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
      window.Backend.validateGuess(floor, input.value).then(function (res) {
        busy = false;
        btn.disabled = false;
        if (res && res.correct) {
          showSuccess(res.mark, opts.successFlavor);
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

  // Boss gates: same form, validated against the player's own marks.
  function mountBoss(floor, opts) {
    opts = opts || {};
    var slot = document.getElementById("passcode-slot");
    if (!slot || !cfg) return;
    var form = make("form", "passcode-form");
    form.setAttribute("autocomplete", "off");
    var input = make("input", "passcode-input");
    input.type = "text";
    input.placeholder = "Speak your marks";
    input.setAttribute("aria-label", "Marks");
    input.setAttribute("autocomplete", "off");
    input.setAttribute("autocapitalize", "characters");
    input.setAttribute("spellcheck", "false");
    var btn = make("button", "btn", "Open the gate");
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
      window.Backend.validateBoss(floor, input.value).then(function (res) {
        busy = false;
        btn.disabled = false;
        if (res && res.correct) {
          showSuccess(null, opts.successFlavor);
        } else {
          shakeIt(form, msg,
            opts.wrongMessage || "The gate does not recognize those marks.");
        }
      }).catch(function (err) {
        busy = false;
        btn.disabled = false;
        shakeIt(form, msg, window.Backend.friendlyError(err));
      });
    });
  }

  // Interactive floors: thin wrappers over the backend validators.
  // Each resolves to {correct, mark}. Floors call onSolved() on success.
  function submitHold(floor, elapsedMs) {
    return window.Backend.validateHold(floor, elapsedMs);
  }
  function submitSequence(floor, ids) {
    return window.Backend.validateSequence(floor, ids);
  }
  function onSolved(mark, flavorHtml) {
    showSuccess(mark, flavorHtml);
  }

  // Public per-floor display data (no answers). Throws when offline.
  function clues(floor) {
    return window.Backend.getClues(floor);
  }

  window.Overthink = {
    initFloor: initFloor,
    hints: hints,
    mountPasscode: mountPasscode,
    mountBoss: mountBoss,
    submitHold: submitHold,
    submitSequence: submitSequence,
    onSolved: onSolved,
    clues: clues,
    getProgress: getProgress,
    cachedMarks: cachedMarks,
    TOTAL_FLOORS: TOTAL_FLOORS,
    BUILT_FLOORS: BUILT_FLOORS
  };
})();

/* app.js — Datadog Assistant onboarding wizard.
 * Vanilla JS. Single `state` object; steps re-render from it.
 * Talks to window.pywebview.api, falling back to window.MockApi for browser preview.
 */
(function () {
  "use strict";

  /* ---------------------------------------------------------------- bridge */
  function api() {
    if (window.pywebview && window.pywebview.api) return window.pywebview.api;
    return window.MockApi;
  }
  // Safe call: returns a Promise even if a method is missing.
  function call(method, arg) {
    var a = api();
    try {
      if (a && typeof a[method] === "function") {
        return Promise.resolve(a[method](arg));
      }
    } catch (e) {
      return Promise.reject(e);
    }
    return Promise.reject(new Error("bridge method unavailable: " + method));
  }

  /* ----------------------------------------------------------------- icons */
  var SVG_CHECK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>';
  var SVG_CHECK_FILL = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>';
  var SVG_X = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>';
  var SPINNER = '<span class="spinner" aria-hidden="true"></span>';

  /* ----------------------------------------------------------------- state */
  var STEPS = ["welcome", "region", "auth", "options", "install", "done"];
  var STEP_LABELS = {
    welcome: "Welcome",
    region: "Region",
    auth: "Sign in",
    options: "Options",
    install: "Install",
    done: "Done"
  };

  var state = {
    stepIndex: 0,
    init: null,
    loadingInit: true,

    site: "",
    appSubdomain: "app",
    tagFilter: "",

    authMethod: null, // "keys" | "oauth" | "lastpass"

    // keys
    apiKey: "",
    appKey: "",
    keysValidated: false,
    keysChecking: false,
    keysError: "",

    // oauth
    oauthClientId: "",

    // lastpass
    lp: {
      cliInstalled: false,
      installing: false,
      installError: "",
      email: "",
      password: "",
      otp: "",
      mfaRequired: false,
      loggingIn: false,
      loggedIn: false,
      loginError: "",
      entries: null,
      loadingEntries: false,
      entry: "",
      apiField: "datadogAPIKey",
      appField: "datadogAPPKey",
      testing: false,
      tested: false,
      testError: "",
      neverExpire: true
    },

    // install
    installing: false,
    installDone: false,
    installError: "",
    progress: 0,
    progressMsg: "",
    logLines: []
  };

  /* -------------------------------------------------------------- elements */
  var stageEl, stepperEl, footbarEl, backBtn, nextBtn, appVersionEl;

  /* --------------------------------------------------------------- helpers */
  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }
  function currentStep() { return STEPS[state.stepIndex]; }
  function reducedMotion() {
    return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  }

  /* ---------------------------------------------------------- step content */
  function viewWelcome() {
    return '' +
      '<div class="step" data-step="welcome">' +
        '<div class="hero-mark" aria-hidden="true">🐶</div>' +
        '<p class="eyebrow">Welcome</p>' +
        '<h1 class="title">Datadog Assistant</h1>' +
        '<p class="lede">Datadog alerts you can\'t miss, right in your menu bar.</p>' +
        '<span class="welcome-meta">⏱️ Takes about a minute · no Terminal needed</span>' +
      '</div>';
  }

  function viewRegion() {
    var sites = (state.init && state.init.sites) || [];
    var opts = sites.map(function (s) {
      var sel = s.value === state.site ? " selected" : "";
      return '<option value="' + esc(s.value) + '"' + sel + '>' + esc(s.label) + '</option>';
    }).join("");
    return '' +
      '<div class="step" data-step="region">' +
        '<p class="eyebrow">Step 1</p>' +
        '<h1 class="title">Choose your Datadog region</h1>' +
        '<p class="lede">Pick the site your Datadog organization lives on so we connect to the right place.</p>' +
        '<div class="field">' +
          '<label class="field-label" for="siteSel">Datadog site</label>' +
          '<select class="select" id="siteSel">' + opts + '</select>' +
        '</div>' +
        '<div class="field">' +
          '<label class="field-label" for="subdomain">Company subdomain <span class="opt">· optional</span></label>' +
          '<input class="input" id="subdomain" type="text" autocomplete="off" spellcheck="false" ' +
            'value="' + esc(state.appSubdomain) + '" placeholder="app" />' +
          '<p class="hint">Most orgs use <strong>app</strong>. If you sign in at something like ' +
            '<em>acme</em>.datadoghq.com, set your custom subdomain here.</p>' +
        '</div>' +
      '</div>';
  }

  function authCard(method, icon, title, tag, desc) {
    var sel = state.authMethod === method ? " selected" : "";
    var tagHtml = tag ? '<span class="tag">' + esc(tag) + '</span>' : "";
    return '' +
      '<button type="button" class="card' + sel + '" data-method="' + method + '" ' +
        'aria-pressed="' + (state.authMethod === method) + '">' +
        '<span class="card-ico" aria-hidden="true">' + icon + '</span>' +
        '<span class="card-body">' +
          '<span class="card-title">' + esc(title) + tagHtml + '</span>' +
          '<span class="card-desc">' + esc(desc) + '</span>' +
        '</span>' +
        '<span class="card-check" aria-hidden="true">' + SVG_CHECK + '</span>' +
      '</button>';
  }

  function viewAuth() {
    var cards = '' +
      authCard("keys", "🔑", "API + App keys", "Quickest", "Paste two keys from your Datadog account.") +
      authCard("oauth", "🌐", "OAuth", null, "Sign in through your browser, no keys to copy.") +
      authCard("lastpass", "🔒", "LastPass", null, "Pull keys from a shared LastPass vault entry.");

    var panel = "";
    if (state.authMethod === "keys") panel = panelKeys();
    else if (state.authMethod === "oauth") panel = panelOauth();
    else if (state.authMethod === "lastpass") panel = panelLastpass();

    return '' +
      '<div class="step" data-step="auth">' +
        '<p class="eyebrow">Step 2</p>' +
        '<h1 class="title">How should we sign in?</h1>' +
        '<p class="lede">Choose how Datadog Assistant authenticates. You can change this later in settings.</p>' +
        '<div class="cards">' + cards + '</div>' +
        '<div id="authPanel">' + panel + '</div>' +
      '</div>';
  }

  function panelKeys() {
    var status = "";
    if (state.keysChecking) {
      status = '<div class="status" style="color:var(--text-dim);background:var(--field-bg)">' + SPINNER + ' Checking…</div>';
    } else if (state.keysValidated) {
      status = '<div class="status good">' + SVG_CHECK_FILL + ' Keys verified</div>';
    } else if (state.keysError) {
      status = '<div class="status bad">' + SVG_X + ' ' + esc(state.keysError) + '</div>';
    }
    return '' +
      '<div class="panel">' +
        '<h3>API &amp; Application keys</h3>' +
        '<div class="field">' +
          '<label class="field-label" for="apiKey">API key</label>' +
          '<input class="input" id="apiKey" type="password" autocomplete="off" spellcheck="false" ' +
            'placeholder="••••••••••••••••" value="' + esc(state.apiKey) + '" />' +
        '</div>' +
        '<div class="field">' +
          '<label class="field-label" for="appKey">Application key</label>' +
          '<input class="input" id="appKey" type="password" autocomplete="off" spellcheck="false" ' +
            'placeholder="••••••••••••••••" value="' + esc(state.appKey) + '" />' +
        '</div>' +
        '<div class="input-row" style="align-items:center;gap:14px">' +
          '<button type="button" class="btn btn-secondary btn-sm" id="validateKeys"' +
            (state.keysChecking ? ' disabled' : '') + ' style="flex:0 0 auto">Validate</button>' +
          status +
        '</div>' +
      '</div>';
  }

  function panelOauth() {
    return '' +
      '<div class="panel">' +
        '<h3>OAuth sign-in</h3>' +
        '<div class="field">' +
          '<label class="field-label" for="oauthId">OAuth Client ID</label>' +
          '<input class="input" id="oauthId" type="text" autocomplete="off" spellcheck="false" ' +
            'placeholder="ddog-oauth-xxxxxxxx" value="' + esc(state.oauthClientId) + '" />' +
          '<p class="hint">After install, you\'ll finish signing in from the menu — a browser window opens to authorize Datadog Assistant.</p>' +
        '</div>' +
        '<button type="button" class="linkbtn" id="oauthDocs">Open Datadog OAuth docs ↗</button>' +
      '</div>';
  }

  function panelLastpass() {
    var lp = state.lp;
    var inner = "";

    // a. install CLI
    if (!lp.cliInstalled) {
      var instErr = "";
      if (lp.installError) {
        instErr = '<p class="inline-msg bad">' + esc(lp.installError) + '</p>';
      }
      inner += '' +
        '<div class="field">' +
          '<button type="button" class="btn btn-secondary btn-sm" id="lpInstall"' +
            (lp.installing ? ' disabled' : '') + '>' +
            (lp.installing ? (SPINNER + ' Installing LastPass CLI…') : 'Install LastPass CLI') +
          '</button>' +
          '<p class="hint">We\'ll install <code>lastpass-cli</code> via Homebrew. This can take a moment.</p>' +
          instErr +
        '</div>';
      return '<div class="panel"><h3>LastPass</h3>' + inner + '</div>';
    }

    // b. login (until logged in)
    if (!lp.loggedIn) {
      var loginErr = lp.loginError ? '<p class="inline-msg bad">' + esc(lp.loginError) + '</p>' : "";
      var otpField = "";
      if (lp.mfaRequired) {
        otpField = '' +
          '<div class="field">' +
            '<label class="field-label" for="lpOtp">6-digit code</label>' +
            '<input class="input" id="lpOtp" type="text" inputmode="numeric" autocomplete="one-time-code" ' +
              'maxlength="6" placeholder="123456" value="' + esc(lp.otp) + '" />' +
            '<p class="hint">Enter the code from your authenticator app to finish signing in.</p>' +
          '</div>';
      }
      inner += '' +
        '<div class="field">' +
          '<label class="field-label" for="lpEmail">LastPass email</label>' +
          '<input class="input" id="lpEmail" type="email" autocomplete="username" spellcheck="false" ' +
            'placeholder="you@company.com" value="' + esc(lp.email) + '" />' +
        '</div>' +
        '<div class="field">' +
          '<label class="field-label" for="lpPass">Master password</label>' +
          '<input class="input" id="lpPass" type="password" autocomplete="current-password" ' +
            'placeholder="••••••••" value="' + esc(lp.password) + '" />' +
        '</div>' +
        otpField +
        '<button type="button" class="btn btn-secondary btn-sm" id="lpLogin"' +
          (lp.loggingIn ? ' disabled' : '') + '>' +
          (lp.loggingIn ? (SPINNER + ' Signing in…') : (lp.mfaRequired ? 'Verify code' : 'Sign in')) +
        '</button>' +
        loginErr;
      return '<div class="panel"><h3>LastPass</h3>' + inner + '</div>';
    }

    // c. entry picker + d. keep signed in
    var entries = lp.entries || [];
    var entryOpts = '<option value="">— choose or type below —</option>' +
      entries.map(function (e) {
        return '<option value="' + esc(e) + '"' + (e === lp.entry ? " selected" : "") + '>' + esc(e) + '</option>';
      }).join("");

    var testStatus = "";
    if (lp.testing) {
      testStatus = '<div class="status" style="color:var(--text-dim);background:var(--field-bg)">' + SPINNER + ' Testing…</div>';
    } else if (lp.tested) {
      testStatus = '<div class="status good">' + SVG_CHECK_FILL + ' Entry works</div>';
    } else if (lp.testError) {
      testStatus = '<div class="status bad">' + SVG_X + ' ' + esc(lp.testError) + '</div>';
    }

    inner += '' +
      '<div class="badge-on">' + SVG_CHECK_FILL + ' Signed in to LastPass</div>' +
      '<div class="field" style="margin-top:16px">' +
        '<label class="field-label" for="lpEntrySel">Vault entry</label>' +
        (lp.loadingEntries
          ? '<p class="hint">' + SPINNER + ' Loading entries…</p>'
          : '<select class="select" id="lpEntrySel">' + entryOpts + '</select>') +
        '<input class="input" id="lpEntryText" type="text" autocomplete="off" spellcheck="false" ' +
          'style="margin-top:9px" placeholder="…or type the entry name" value="' + esc(lp.entry) + '" />' +
      '</div>' +
      '<div class="input-row">' +
        '<div class="field" style="flex:1;margin-bottom:0">' +
          '<label class="field-label" for="lpApiField">API key field</label>' +
          '<input class="input" id="lpApiField" type="text" spellcheck="false" value="' + esc(lp.apiField) + '" />' +
        '</div>' +
        '<div class="field" style="flex:1;margin-bottom:0">' +
          '<label class="field-label" for="lpAppField">App key field</label>' +
          '<input class="input" id="lpAppField" type="text" spellcheck="false" value="' + esc(lp.appField) + '" />' +
        '</div>' +
      '</div>' +
      '<div class="input-row" style="align-items:center;gap:14px;margin-top:14px">' +
        '<button type="button" class="btn btn-secondary btn-sm" id="lpTest"' +
          (lp.testing ? ' disabled' : '') + ' style="flex:0 0 auto">Test</button>' +
        testStatus +
      '</div>' +
      '<div class="toggle-row">' +
        '<button type="button" class="toggle" id="lpNeverExpire" role="switch" ' +
          'aria-checked="' + (lp.neverExpire ? "true" : "false") + '" aria-label="Keep me signed in"></button>' +
        '<span class="toggle-text">' +
          '<span class="t-title">Keep me signed in</span>' +
          '<span class="t-note">Stays unlocked until you restart your Mac; you\'ll re-enter your master password once after a reboot.</span>' +
        '</span>' +
      '</div>';

    return '<div class="panel"><h3>LastPass</h3>' + inner + '</div>';
  }

  function viewOptions() {
    return '' +
      '<div class="step" data-step="options">' +
        '<p class="eyebrow">Step 3</p>' +
        '<h1 class="title">Fine-tune what you see</h1>' +
        '<p class="lede">Optional — you can always change this later from the menu.</p>' +
        '<div class="field">' +
          '<label class="field-label" for="tagFilter">Tag filter <span class="opt">· optional</span></label>' +
          '<input class="input" id="tagFilter" type="text" autocomplete="off" spellcheck="false" ' +
            'placeholder="team:sre env:prod" value="' + esc(state.tagFilter) + '" />' +
          '<p class="hint">Only show monitors matching these space-separated tags. Leave blank to show all monitors.</p>' +
        '</div>' +
      '</div>';
  }

  function viewInstall() {
    var pct = Math.round(state.progress * 100);
    var logHtml = state.logLines.map(function (l) {
      return '<div class="log-line">' + esc(l) + '</div>';
    }).join("");

    var errBlock = "";
    if (state.installError) {
      errBlock = '' +
        '<div class="status bad" style="margin-top:14px">' + SVG_X + ' ' + esc(state.installError) + '</div>' +
        '<div style="margin-top:14px"><button type="button" class="btn btn-secondary btn-sm" id="retryInstall">Try again</button></div>';
    }

    var heading = state.installError ? "Installation hit a snag"
      : (state.installDone ? "Installed" : "Setting things up…");

    return '' +
      '<div class="step" data-step="install">' +
        '<p class="eyebrow">Installing</p>' +
        '<h1 class="title">' + esc(heading) + '</h1>' +
        '<p class="lede">Hang tight — Datadog Assistant is being installed and configured. Please don\'t close this window.</p>' +
        '<div class="progress-wrap">' +
          '<div class="progress-track"><div class="progress-fill" id="progFill" style="width:' + pct + '%"></div></div>' +
          '<div class="progress-meta">' +
            '<span id="progMsg">' + esc(state.progressMsg || "Starting…") + '</span>' +
            '<span id="progPct">' + pct + '%</span>' +
          '</div>' +
        '</div>' +
        '<div class="log" id="logBox" role="log" aria-label="Install log">' + logHtml + '</div>' +
        errBlock +
      '</div>';
  }

  function viewDone() {
    return '' +
      '<div class="step" data-step="done">' +
        '<div class="done-mark" aria-hidden="true">🎉</div>' +
        '<p class="eyebrow">All set</p>' +
        '<h1 class="title">You\'re all set</h1>' +
        '<p class="lede">🐶 is now in your menu bar — it flips to ‼️ the moment a monitor fires. Click it any time to see what\'s alerting. You can close this window.</p>' +
        '<button type="button" class="btn btn-primary" id="finishBtn">Done</button>' +
      '</div>';
  }

  /* ----------------------------------------------------------- validation */
  function authValid() {
    if (state.authMethod === "keys") return state.keysValidated;
    if (state.authMethod === "oauth") return state.oauthClientId.trim().length > 0;
    if (state.authMethod === "lastpass") {
      var lp = state.lp;
      return lp.loggedIn && lp.tested && lp.entry.trim().length > 0;
    }
    return false;
  }

  function stepValid(step) {
    switch (step) {
      case "welcome": return true;
      case "region": return !!state.site;
      case "auth": return authValid();
      case "options": return true;
      case "install": return state.installDone;
      case "done": return true;
      default: return false;
    }
  }

  /* ------------------------------------------------------------- chrome UI */
  function renderStepper() {
    // Only show the meaningful wizard steps in the rail (skip welcome).
    var shown = ["region", "auth", "options", "install", "done"];
    var html = shown.map(function (s) {
      var idx = STEPS.indexOf(s);
      var cls = "step-item";
      var dot;
      if (idx < state.stepIndex) { cls += " done"; dot = SVG_CHECK_FILL; }
      else if (idx === state.stepIndex) { cls += " active"; dot = String(shown.indexOf(s) + 1); }
      else { dot = String(shown.indexOf(s) + 1); }
      return '<div class="' + cls + '"><span class="step-dot">' + dot + '</span>' +
        '<span>' + esc(STEP_LABELS[s]) + '</span></div>';
    }).join("");
    stepperEl.innerHTML = html;
  }

  function renderFooter() {
    var step = currentStep();
    // Welcome, install and done manage their own primary actions.
    if (step === "welcome") {
      footbarEl.removeAttribute("data-hidden");
      backBtn.setAttribute("data-hidden", "true");
      nextBtn.textContent = "Get started";
      nextBtn.disabled = state.loadingInit;
      return;
    }
    if (step === "install" || step === "done") {
      footbarEl.setAttribute("data-hidden", "true");
      return;
    }
    footbarEl.removeAttribute("data-hidden");
    backBtn.removeAttribute("data-hidden");
    backBtn.disabled = false;
    nextBtn.textContent = (step === "options") ? "Install" : "Continue";
    nextBtn.disabled = !stepValid(step);
  }

  /* --------------------------------------------------------------- render */
  function viewFor(step) {
    switch (step) {
      case "welcome": return viewWelcome();
      case "region": return viewRegion();
      case "auth": return viewAuth();
      case "options": return viewOptions();
      case "install": return viewInstall();
      case "done": return viewDone();
      default: return "";
    }
  }

  // Full re-render of the current step (used on step change).
  function renderStep(animateOut) {
    var step = currentStep();
    function paint() {
      stageEl.innerHTML = viewFor(step);
      bindStep();
      renderStepper();
      renderFooter();
      stageEl.scrollTop = 0;
    }
    var existing = stageEl.querySelector(".step");
    if (animateOut && existing && !reducedMotion()) {
      existing.classList.add("leaving");
      setTimeout(paint, 200);
    } else {
      paint();
    }
  }

  // Lightweight re-render of just the auth panel (keeps card focus, no flash).
  function refreshAuthPanel() {
    var holder = document.getElementById("authPanel");
    if (!holder) { renderStep(false); return; }
    if (state.authMethod === "keys") holder.innerHTML = panelKeys();
    else if (state.authMethod === "oauth") holder.innerHTML = panelOauth();
    else if (state.authMethod === "lastpass") holder.innerHTML = panelLastpass();
    else holder.innerHTML = "";
    bindAuthPanel();
    // update card selected styling
    Array.prototype.forEach.call(stageEl.querySelectorAll(".card"), function (c) {
      var on = c.getAttribute("data-method") === state.authMethod;
      c.classList.toggle("selected", on);
      c.setAttribute("aria-pressed", on ? "true" : "false");
    });
    renderFooter();
  }

  /* -------------------------------------------------------------- binding */
  function bindStep() {
    var step = currentStep();
    if (step === "region") bindRegion();
    else if (step === "auth") { bindAuthCards(); bindAuthPanel(); }
    else if (step === "options") bindOptions();
    else if (step === "install") bindInstall();
    else if (step === "done") bindDone();
  }

  function bindRegion() {
    var sel = document.getElementById("siteSel");
    var sub = document.getElementById("subdomain");
    if (sel) sel.addEventListener("change", function () {
      state.site = sel.value; renderFooter();
    });
    if (sub) sub.addEventListener("input", function () {
      state.appSubdomain = sub.value;
    });
  }

  function bindAuthCards() {
    Array.prototype.forEach.call(stageEl.querySelectorAll(".card"), function (c) {
      c.addEventListener("click", function () {
        var m = c.getAttribute("data-method");
        if (state.authMethod === m) return;
        state.authMethod = m;
        // lazy-load lastpass entries the first time we reach the picker
        refreshAuthPanel();
      });
    });
  }

  function bindAuthPanel() {
    if (state.authMethod === "keys") bindKeys();
    else if (state.authMethod === "oauth") bindOauth();
    else if (state.authMethod === "lastpass") bindLastpass();
  }

  function bindKeys() {
    var api_ = document.getElementById("apiKey");
    var app_ = document.getElementById("appKey");
    var btn = document.getElementById("validateKeys");
    if (api_) api_.addEventListener("input", function () {
      state.apiKey = api_.value; state.keysValidated = false; state.keysError = "";
      renderFooter();
    });
    if (app_) app_.addEventListener("input", function () {
      state.appKey = app_.value; state.keysValidated = false; state.keysError = "";
      renderFooter();
    });
    if (btn) btn.addEventListener("click", function () {
      if (!state.apiKey || !state.appKey) {
        state.keysError = "Enter both keys first."; refreshAuthPanel(); return;
      }
      state.keysChecking = true; state.keysError = ""; state.keysValidated = false;
      refreshAuthPanel();
      call("validate_datadog_keys", {
        site: state.site,
        app_subdomain: state.appSubdomain,
        api_key: state.apiKey,
        app_key: state.appKey
      }).then(function (r) {
        state.keysChecking = false;
        if (r && r.ok) { state.keysValidated = true; state.keysError = ""; }
        else { state.keysValidated = false; state.keysError = (r && r.error) || "Validation failed."; }
        refreshAuthPanel();
      }).catch(function (e) {
        state.keysChecking = false; state.keysValidated = false;
        state.keysError = "Couldn't reach the validator: " + e.message;
        refreshAuthPanel();
      });
    });
  }

  function bindOauth() {
    var id = document.getElementById("oauthId");
    var docs = document.getElementById("oauthDocs");
    if (id) id.addEventListener("input", function () {
      state.oauthClientId = id.value; renderFooter();
    });
    if (docs) docs.addEventListener("click", function () {
      call("open_external", { url: "https://docs.datadoghq.com/developers/authorization/oauth2_in_datadog/" });
    });
  }

  function bindLastpass() {
    var lp = state.lp;

    var inst = document.getElementById("lpInstall");
    if (inst) inst.addEventListener("click", function () {
      lp.installing = true; lp.installError = ""; refreshAuthPanel();
      call("lastpass_ensure_cli").then(function (r) {
        lp.installing = false;
        if (r && r.installed) { lp.cliInstalled = true; lp.installError = ""; }
        else { lp.installError = (r && r.error) || "Could not install the LastPass CLI."; }
        refreshAuthPanel();
      }).catch(function (e) {
        lp.installing = false; lp.installError = "Install failed: " + e.message; refreshAuthPanel();
      });
    });

    var email = document.getElementById("lpEmail");
    var pass = document.getElementById("lpPass");
    var otp = document.getElementById("lpOtp");
    var login = document.getElementById("lpLogin");
    if (email) email.addEventListener("input", function () { lp.email = email.value; });
    if (pass) pass.addEventListener("input", function () { lp.password = pass.value; });
    if (otp) otp.addEventListener("input", function () { lp.otp = otp.value; });
    if (login) login.addEventListener("click", doLastpassLogin);

    var sel = document.getElementById("lpEntrySel");
    var txt = document.getElementById("lpEntryText");
    if (sel) sel.addEventListener("change", function () {
      lp.entry = sel.value; lp.tested = false; lp.testError = "";
      if (txt) txt.value = sel.value;
      renderFooter();
    });
    if (txt) txt.addEventListener("input", function () {
      lp.entry = txt.value; lp.tested = false; lp.testError = "";
      renderFooter();
    });

    var apiF = document.getElementById("lpApiField");
    var appF = document.getElementById("lpAppField");
    if (apiF) apiF.addEventListener("input", function () { lp.apiField = apiF.value; lp.tested = false; });
    if (appF) appF.addEventListener("input", function () { lp.appField = appF.value; lp.tested = false; });

    var test = document.getElementById("lpTest");
    if (test) test.addEventListener("click", function () {
      if (!lp.entry.trim()) { lp.testError = "Choose a vault entry first."; refreshAuthPanel(); return; }
      lp.testing = true; lp.tested = false; lp.testError = ""; refreshAuthPanel();
      call("lastpass_validate_entry", {
        entry: lp.entry, api_key_field: lp.apiField, app_key_field: lp.appField
      }).then(function (r) {
        lp.testing = false;
        if (r && r.ok) { lp.tested = true; lp.testError = ""; }
        else { lp.tested = false; lp.testError = (r && r.error) || "That entry didn't work."; }
        refreshAuthPanel();
      }).catch(function (e) {
        lp.testing = false; lp.testError = "Test failed: " + e.message; refreshAuthPanel();
      });
    });

    var toggle = document.getElementById("lpNeverExpire");
    if (toggle) toggle.addEventListener("click", function () {
      lp.neverExpire = !lp.neverExpire;
      toggle.setAttribute("aria-checked", lp.neverExpire ? "true" : "false");
    });

    // lazily load entries once logged in
    if (lp.loggedIn && lp.entries === null && !lp.loadingEntries) {
      lp.loadingEntries = true;
      call("lastpass_list_entries").then(function (r) {
        lp.loadingEntries = false;
        lp.entries = (r && r.entries) || [];
        refreshAuthPanel();
      }).catch(function () {
        lp.loadingEntries = false; lp.entries = []; refreshAuthPanel();
      });
    }
  }

  function doLastpassLogin() {
    var lp = state.lp;
    if (!lp.email || !lp.password) {
      lp.loginError = "Enter your email and master password."; refreshAuthPanel(); return;
    }
    lp.loggingIn = true; lp.loginError = ""; refreshAuthPanel();
    var args = { email: lp.email, password: lp.password };
    if (lp.mfaRequired && lp.otp) args.otp = lp.otp;
    call("lastpass_login", args).then(function (r) {
      lp.loggingIn = false;
      if (r && r.ok) {
        lp.loggedIn = true; lp.loginError = ""; lp.mfaRequired = false;
      } else if (r && r.mfa_required) {
        lp.mfaRequired = true;
        lp.loginError = r.error || "";
      } else {
        lp.loginError = (r && r.error) || "Sign-in failed.";
      }
      refreshAuthPanel();
    }).catch(function (e) {
      lp.loggingIn = false; lp.loginError = "Sign-in failed: " + e.message; refreshAuthPanel();
    });
  }

  function bindOptions() {
    var tf = document.getElementById("tagFilter");
    if (tf) tf.addEventListener("input", function () { state.tagFilter = tf.value; });
  }

  function bindInstall() {
    var retry = document.getElementById("retryInstall");
    if (retry) retry.addEventListener("click", function () { startInstall(); });
  }

  function bindDone() {
    var fin = document.getElementById("finishBtn");
    if (fin) fin.addEventListener("click", function () { call("finish"); });
  }

  /* ------------------------------------------------------------ navigation */
  function goTo(index) {
    if (index < 0 || index >= STEPS.length) return;
    state.stepIndex = index;
    renderStep(true);
    if (STEPS[index] === "install") startInstall();
  }

  function next() {
    var step = currentStep();
    if (!stepValid(step)) return;
    goTo(state.stepIndex + 1);
  }
  function back() {
    if (state.installing) return;
    goTo(state.stepIndex - 1);
  }

  /* --------------------------------------------------------------- install */
  function buildConfig() {
    var cfg = {
      site: state.site,
      app_subdomain: state.appSubdomain || "app",
      tag_filter: state.tagFilter || "",
      auth: state.authMethod
    };
    if (state.authMethod === "keys") {
      cfg.api_key = state.apiKey;
      cfg.app_key = state.appKey;
    } else if (state.authMethod === "oauth") {
      cfg.oauth_client_id = state.oauthClientId;
    } else if (state.authMethod === "lastpass") {
      cfg.lastpass = {
        entry: state.lp.entry,
        api_key_field: state.lp.apiField,
        app_key_field: state.lp.appField,
        never_expire: state.lp.neverExpire
      };
    }
    return cfg;
  }

  function startInstall() {
    state.installing = true;
    state.installDone = false;
    state.installError = "";
    state.progress = 0;
    state.progressMsg = "Starting…";
    state.logLines = [];
    renderStep(false);
    renderStepper();

    call("begin_install", buildConfig()).catch(function (e) {
      if (window.ddOnDone) window.ddOnDone(false, "Could not start install: " + e.message);
    });
  }

  // --- live progress patching (no full re-render to keep log scroll smooth)
  function patchProgress() {
    var fill = document.getElementById("progFill");
    var msg = document.getElementById("progMsg");
    var pctEl = document.getElementById("progPct");
    var pct = Math.round(state.progress * 100);
    if (fill) fill.style.width = pct + "%";
    if (msg) msg.textContent = state.progressMsg || "";
    if (pctEl) pctEl.textContent = pct + "%";
  }
  function appendLog(line) {
    var box = document.getElementById("logBox");
    if (!box) return;
    var div = document.createElement("div");
    div.className = "log-line";
    div.textContent = line;
    box.appendChild(div);
    box.scrollTop = box.scrollHeight;
  }

  /* -------------------------------------------- global progress callbacks */
  window.ddOnProgress = function (frac, message) {
    if (currentStep() !== "install") return;
    state.progress = Math.max(0, Math.min(1, Number(frac) || 0));
    if (message != null) state.progressMsg = String(message);
    patchProgress();
  };
  window.ddOnLog = function (line) {
    state.logLines.push(String(line));
    if (currentStep() === "install") appendLog(String(line));
  };
  window.ddOnDone = function (ok, error) {
    state.installing = false;
    if (ok) {
      state.installDone = true;
      state.progress = 1;
      patchProgress();
      // small beat, then advance to Done
      setTimeout(function () {
        if (currentStep() === "install") goTo(STEPS.indexOf("done"));
      }, 550);
    } else {
      state.installError = error || "Installation failed.";
      renderStep(false);
    }
  };

  /* ----------------------------------------------------------- keyboard */
  function onKeydown(e) {
    if (e.key !== "Enter") return;
    var t = e.target;
    // Don't hijack Enter inside multiline or buttons/links.
    if (t && (t.tagName === "TEXTAREA")) return;
    if (t && t.classList && (t.classList.contains("card") ||
        t.classList.contains("btn") || t.classList.contains("linkbtn") ||
        t.classList.contains("toggle"))) {
      return; // let the element's own activation handle it
    }
    var step = currentStep();
    if (step === "install") return;
    if (step === "welcome") { e.preventDefault(); next(); return; }
    if (step === "done") {
      e.preventDefault(); call("finish"); return;
    }
    // For form steps, advance only if valid.
    if (stepValid(step)) { e.preventDefault(); next(); }
  }

  /* ------------------------------------------------------------- startup */
  function loadInit() {
    call("get_init").then(function (r) {
      state.init = r || {};
      state.loadingInit = false;
      var d = (r && r.defaults) || {};
      if (d.site) state.site = d.site;
      else if (r && r.sites && r.sites[0]) state.site = r.sites[0].value;
      if (d.app_subdomain) state.appSubdomain = d.app_subdomain;
      if (d.tag_filter) state.tagFilter = d.tag_filter;
      // pre-seed lastpass env
      var env = (r && r.env) || {};
      if (env.has_lpass) state.lp.cliInstalled = true;
      if (env.lpass_logged_in) state.lp.loggedIn = true;
      if (appVersionEl) appVersionEl.textContent = "v" + ((r && r.app_version) || "");
      // refresh current view (welcome button enabling, etc.)
      renderFooter();
      if (currentStep() === "region") renderStep(false);
    }).catch(function () {
      state.loadingInit = false;
      state.init = { sites: [], defaults: {}, env: {} };
      renderFooter();
    });
  }

  function init() {
    stageEl = document.getElementById("stage");
    stepperEl = document.getElementById("stepper");
    footbarEl = document.getElementById("footbar");
    backBtn = document.getElementById("backBtn");
    nextBtn = document.getElementById("nextBtn");
    appVersionEl = document.getElementById("appVersion");

    backBtn.addEventListener("click", back);
    nextBtn.addEventListener("click", next);
    document.addEventListener("keydown", onKeydown);

    renderStep(false);
    loadInit();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

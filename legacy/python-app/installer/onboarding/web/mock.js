/* mock.js — stand-in for the Python pywebview bridge.
 * Lets the page run fully in a plain browser for design preview.
 * app.js falls back to window.MockApi whenever window.pywebview is undefined.
 */
(function () {
  "use strict";

  function delay(ms, value) {
    return new Promise(function (resolve) {
      setTimeout(function () { resolve(value); }, ms);
    });
  }

  // Track lastpass login attempts so the first call asks for MFA.
  var loginAttempts = 0;

  var MockApi = {
    get_init: function () {
      return delay(420, {
        sites: [
          { label: "US1 (datadoghq.com)", value: "datadoghq.com" },
          { label: "US3 (us3.datadoghq.com)", value: "us3.datadoghq.com" },
          { label: "US5 (us5.datadoghq.com)", value: "us5.datadoghq.com" },
          { label: "EU1 (datadoghq.eu)", value: "datadoghq.eu" },
          { label: "US1-FED (ddog-gov.com)", value: "ddog-gov.com" },
          { label: "AP1 (ap1.datadoghq.com)", value: "ap1.datadoghq.com" }
        ],
        defaults: { site: "datadoghq.com", app_subdomain: "app", tag_filter: "" },
        env: { has_homebrew: true, has_lpass: false, lpass_logged_in: false },
        app_version: "1.4.0"
      });
    },

    validate_datadog_keys: function (args) {
      args = args || {};
      if (!args.api_key || !args.app_key) {
        return delay(500, { ok: false, error: "Both API and App keys are required." });
      }
      if (String(args.api_key).length < 8) {
        return delay(500, { ok: false, error: "That API key doesn't look right (403 from Datadog)." });
      }
      return delay(650, { ok: true });
    },

    lastpass_ensure_cli: function () {
      // Simulate a slow brew install.
      return delay(1400, { installed: true });
    },

    lastpass_login: function (args) {
      args = args || {};
      loginAttempts += 1;
      if (!args.email || !args.password) {
        return delay(500, { ok: false, error: "Enter your LastPass email and master password." });
      }
      // First attempt without an OTP asks for MFA.
      if (!args.otp) {
        return delay(800, { ok: false, mfa_required: true });
      }
      if (String(args.otp).replace(/\D/g, "").length !== 6) {
        return delay(600, { ok: false, mfa_required: true, error: "Enter the 6-digit code from your authenticator." });
      }
      return delay(700, { ok: true });
    },

    lastpass_list_entries: function () {
      return delay(550, {
        entries: [
          "Shared-Engineering/Datadog API Keys",
          "Shared-SRE/Datadog Production",
          "Personal/Datadog Sandbox",
          "Ops/Datadog Read-Only"
        ]
      });
    },

    lastpass_validate_entry: function (args) {
      args = args || {};
      if (!args.entry) {
        return delay(500, { ok: false, error: "Choose a vault entry first." });
      }
      return delay(750, { ok: true });
    },

    begin_install: function (config) {
      // Drive the global progress callbacks 0 -> 1 over ~3s.
      var steps = [
        [0.08, "Preparing installer…"],
        [0.22, "Writing config to ~/Library/Application Support/DatadogAssistant"],
        [0.40, "Installing menu-bar app bundle"],
        [0.58, "Registering login item"],
        [0.74, "Verifying Datadog connectivity (" + (config && config.site) + ")"],
        [0.90, "Priming monitor cache"],
        [1.00, "Finishing up"]
      ];
      var i = 0;
      function tick() {
        if (i >= steps.length) {
          if (typeof window.ddOnDone === "function") window.ddOnDone(true);
          return;
        }
        var frac = steps[i][0];
        var msg = steps[i][1];
        if (typeof window.ddOnProgress === "function") window.ddOnProgress(frac, msg);
        if (typeof window.ddOnLog === "function") window.ddOnLog("• " + msg);
        i += 1;
        setTimeout(tick, 430);
      }
      setTimeout(tick, 350);
      return delay(50, { ok: true });
    },

    open_external: function (args) {
      try {
        if (args && args.url) window.open(args.url, "_blank", "noopener");
      } catch (e) { /* ignore in preview */ }
      return delay(50, { ok: true });
    },

    finish: function () {
      // No real app to launch in preview.
      // eslint-disable-next-line no-alert
      try { alert("✅ Setup complete!\n\nIn the real app, the onboarding window closes and 🐶 appears in your menu bar."); } catch (e) {}
      return delay(50, { ok: true });
    }
  };

  window.MockApi = MockApi;
})();

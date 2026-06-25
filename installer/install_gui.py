#!/usr/bin/env python3
"""
🐶 Datadog Assistant — graphical installer (macOS).

A small Tkinter wizard so non-technical users never touch Terminal: pick a
region, sign in, and it sets up the venv + rumps, stores keys in the Keychain,
writes the config, installs the LaunchAgent, and launches the menu bar app.

It does exactly what install.sh does, just with a window. Build it into a
double-clickable .app with installer/build.sh (PyInstaller).
"""
import os
import sys
import json
import queue
import shutil
import threading
import subprocess
try:
    import tkinter as tk
    from tkinter import ttk
except ImportError:
    sys.stderr.write(
        "\nThis single-window installer needs a Python with Tk, which your "
        "python3 doesn't have.\n\nEasiest fix , use the native installer "
        "(no Python/Tk needed):\n"
        "    osascript installer/install.applescript\n"
        "    # or build it:  ./installer/build_app.sh\n\n"
        "Or install Tk and re-run this:  brew install python-tk\n\n")
    sys.exit(1)

APP_DIR = os.path.expanduser("~/.datadog-assistant")
CONFIG_DIR = os.path.expanduser("~/.config/datadog-assistant")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")
PLIST_PATH = os.path.expanduser(
    "~/Library/LaunchAgents/com.nour.datadog-assistant.plist")
LABEL = "com.nour.datadog-assistant"
OAUTH_PORT = 8918

SITES = [
    ("US1  ·  datadoghq.com", "datadoghq.com"),
    ("EU  ·  datadoghq.eu", "datadoghq.eu"),
    ("US3  ·  us3.datadoghq.com", "us3.datadoghq.com"),
    ("US5  ·  us5.datadoghq.com", "us5.datadoghq.com"),
    ("AP1  ·  ap1.datadoghq.com", "ap1.datadoghq.com"),
    ("GOV  ·  ddog-gov.com", "ddog-gov.com"),
]


def bundled_app_source():
    """Locate datadog_assistant.py whether frozen (PyInstaller) or in dev."""
    here = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    for cand in (os.path.join(here, "datadog_assistant.py"),
                 os.path.join(here, "..", "datadog_assistant.py")):
        if os.path.exists(cand):
            return os.path.abspath(cand)
    return None


def find_python3():
    """A real (non-frozen) python3 to build the venv with."""
    for cand in ("python3", "/usr/bin/python3", "/usr/local/bin/python3",
                 "/opt/homebrew/bin/python3"):
        path = shutil.which(cand) if "/" not in cand else (
            cand if os.path.exists(cand) else None)
        if path:
            return path
    return None


# --------------------------------------------------------------------------
# install steps (run off the UI thread; progress posted to a queue)
# --------------------------------------------------------------------------
class Installer(threading.Thread):
    def __init__(self, state, q):
        super().__init__(daemon=True)
        self.state, self.q = state, q

    def log(self, msg):
        self.q.put(("log", msg))

    def step(self, frac, msg):
        self.q.put(("progress", frac, msg))

    def run(self):
        try:
            self._install()
            self.q.put(("done", None))
        except Exception as e:  # surface a readable failure on the Done screen
            self.q.put(("error", str(e)))

    def _sh(self, args, **kw):
        self.log("$ " + " ".join(args))
        p = subprocess.run(args, capture_output=True, text=True, **kw)
        if p.stdout.strip():
            self.log(p.stdout.strip())
        if p.returncode != 0:
            raise RuntimeError(p.stderr.strip() or f"command failed: {args[0]}")
        return p

    def _install(self):
        s = self.state
        src = bundled_app_source()
        if not src:
            raise RuntimeError("Couldn't find datadog_assistant.py to install.")
        py = find_python3()
        if not py:
            raise RuntimeError(
                "python3 isn't installed. Open Terminal and run\n"
                "    xcode-select --install\nthen run this installer again.")

        self.step(0.10, "Creating folders…")
        os.makedirs(APP_DIR, exist_ok=True)
        os.makedirs(CONFIG_DIR, exist_ok=True)
        os.makedirs(os.path.dirname(PLIST_PATH), exist_ok=True)

        self.step(0.20, "Copying the app…")
        shutil.copy2(src, os.path.join(APP_DIR, "datadog_assistant.py"))

        venv = os.path.join(APP_DIR, "venv")
        if not os.path.exists(venv):
            self.step(0.35, "Creating a Python environment…")
            self._sh([py, "-m", "venv", venv])
        self.step(0.55, "Installing dependencies (rumps)…")
        pip = os.path.join(venv, "bin", "pip")
        self._sh([pip, "install", "--quiet", "--upgrade", "pip"])
        # Pinned to match requirements.txt — keep in sync when bumping.
        self._sh([pip, "install", "--quiet", "rumps>=0.4.0,<0.5"])

        self.step(0.70, "Writing your settings…")
        cfg = {}
        if os.path.exists(CONFIG_PATH):
            try:
                cfg = json.load(open(CONFIG_PATH))
            except Exception:
                cfg = {}
        cfg["site"] = s["site"]
        cfg["app_subdomain"] = s.get("subdomain") or "app"
        cfg["tag_filter"] = s.get("tag_filter", "")
        if s["auth"] == "oauth":
            cfg["auth"] = "oauth"
            cfg["oauth_client_id"] = s.get("oauth_client_id", "")
        else:
            cfg["auth"] = "keys"
            cfg["use_keychain"] = True
        json.dump(cfg, open(CONFIG_PATH, "w"), indent=2)

        if s["auth"] == "keys":
            self.step(0.80, "Storing your keys in the Keychain…")
            for svc, val in (("datadog-assistant-api-key", s.get("api_key", "")),
                             ("datadog-assistant-app-key", s.get("app_key", ""))):
                if val:
                    self._sh(["security", "add-generic-password", "-U",
                              "-s", svc, "-a", os.environ.get("USER", "user"),
                              "-w", val])

        self.step(0.90, "Installing the login item…")
        plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{venv}/bin/python3</string>
    <string>{APP_DIR}/datadog_assistant.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>{APP_DIR}/stderr.log</string>
  <key>StandardOutPath</key><string>{APP_DIR}/stdout.log</string>
</dict>
</plist>
"""
        open(PLIST_PATH, "w").write(plist)
        subprocess.run(["launchctl", "unload", PLIST_PATH],
                       capture_output=True, text=True)
        self._sh(["launchctl", "load", PLIST_PATH])
        self.step(1.0, "Done!")


# --------------------------------------------------------------------------
# the wizard window
# --------------------------------------------------------------------------
class Wizard(tk.Tk):
    STEPS = ["Welcome", "Region", "Sign in", "Options", "Install"]

    def __init__(self):
        super().__init__()
        self.title("Datadog Assistant Installer")
        self.configure(bg="#ffffff")
        self.resizable(False, False)
        try:
            self.geometry("560x440")
        except Exception:
            pass
        self.state = {"site": SITES[0][1], "auth": "keys", "api_key": "",
                      "app_key": "", "oauth_client_id": "", "tag_filter": "",
                      "subdomain": ""}
        self.idx = 0
        self.q = queue.Queue()

        # header
        head = tk.Frame(self, bg="#ffffff")
        head.pack(fill="x", padx=24, pady=(20, 6))
        tk.Label(head, text="🐶  Datadog Assistant", bg="#ffffff",
                 font=("Helvetica", 17, "bold")).pack(side="left")
        self.step_lbl = tk.Label(head, text="", bg="#ffffff", fg="#8a8a8a",
                                 font=("Helvetica", 12))
        self.step_lbl.pack(side="right")
        ttk.Separator(self, orient="horizontal").pack(fill="x", padx=24)

        # body (swapped per step)
        self.body = tk.Frame(self, bg="#ffffff")
        self.body.pack(fill="both", expand=True, padx=24, pady=18)

        # footer
        foot = tk.Frame(self, bg="#ffffff")
        foot.pack(fill="x", padx=24, pady=(0, 18))
        self.back_btn = ttk.Button(foot, text="Back", command=self.back)
        self.back_btn.pack(side="left")
        self.next_btn = ttk.Button(foot, text="Continue", command=self.next)
        self.next_btn.pack(side="right")

        self.render()

    # ---- step rendering ----
    def clear(self):
        for w in self.body.winfo_children():
            w.destroy()

    def render(self):
        self.clear()
        self.step_lbl.config(text=f"Step {self.idx + 1} of {len(self.STEPS)}")
        self.back_btn.state(["!disabled"] if self.idx else ["disabled"])
        getattr(self, f"_step_{self.idx}")()

    def _title(self, text, sub=""):
        tk.Label(self.body, text=text, bg="#ffffff",
                 font=("Helvetica", 20, "bold")).pack(anchor="w")
        if sub:
            tk.Label(self.body, text=sub, bg="#ffffff", fg="#6b6b6b",
                     justify="left", wraplength=500,
                     font=("Helvetica", 13)).pack(anchor="w", pady=(6, 16))

    def _step_0(self):  # Welcome
        self.next_btn.config(text="Continue")
        tk.Label(self.body, text="🐶", bg="#ffffff",
                 font=("Helvetica", 56)).pack(pady=(14, 8))
        self._title("Welcome",
                    "This sets up Datadog Assistant in your menu bar. It takes "
                    "about a minute, and you never need Terminal.")

    def _step_1(self):  # Region
        self._title("Choose your Datadog site",
                    "Pick the region your org is on. Check your browser, e.g. "
                    "app.datadoghq.eu.")
        self.region_var = tk.StringVar(value=self._site_label(self.state["site"]))
        box = ttk.Combobox(self.body, textvariable=self.region_var, state="readonly",
                           values=[lbl for lbl, _ in SITES], width=34)
        box.pack(anchor="w")

    def _step_2(self):  # Sign in
        self._title("Sign in to Datadog",
                    "Your credentials are stored in the macOS Keychain on this "
                    "Mac. Nothing is sent to any server.")
        self.auth_var = tk.StringVar(value=self.state["auth"])
        ttk.Radiobutton(self.body, text="API + App keys (quickest)",
                        variable=self.auth_var, value="keys",
                        command=self._auth_fields).pack(anchor="w")
        ttk.Radiobutton(self.body, text="OAuth (log in via browser)",
                        variable=self.auth_var, value="oauth",
                        command=self._auth_fields).pack(anchor="w", pady=(2, 10))
        self.auth_box = tk.Frame(self.body, bg="#ffffff")
        self.auth_box.pack(fill="x", anchor="w")
        self._auth_fields()

    def _auth_fields(self):
        for w in self.auth_box.winfo_children():
            w.destroy()
        if self.auth_var.get() == "keys":
            self.api_var = tk.StringVar(value=self.state["api_key"])
            self.app_var = tk.StringVar(value=self.state["app_key"])
            self._field(self.auth_box, "Datadog API key", self.api_var, secret=True)
            self._field(self.auth_box, "Datadog Application key", self.app_var,
                        secret=True)
        else:
            self.cid_var = tk.StringVar(value=self.state["oauth_client_id"])
            tk.Label(self.auth_box, bg="#ffffff", fg="#6b6b6b", justify="left",
                     wraplength=500, font=("Helvetica", 12),
                     text=("Create an OAuth client in Datadog (redirect URI "
                           f"http://localhost:{OAUTH_PORT}/callback). Paste its "
                           "Client ID below; you'll finish the browser login "
                           "from the menu after install.")
                     ).pack(anchor="w", pady=(0, 8))
            self._field(self.auth_box, "OAuth Client ID", self.cid_var)

    def _step_3(self):  # Options
        self.next_btn.config(text="Install")
        self._title("Options (optional)",
                    "Both are optional. Leave blank to skip.")
        self.tag_var = tk.StringVar(value=self.state["tag_filter"])
        self.sub_var = tk.StringVar(value=self.state["subdomain"])
        self._field(self.body, "Only show monitors with tags (space separated)",
                    self.tag_var)
        self._field(self.body, "Company subdomain (if you browse company.datadoghq.com)",
                    self.sub_var)

    def _step_4(self):  # Install / progress
        self.next_btn.state(["disabled"])
        self.back_btn.state(["disabled"])
        self._title("Installing…")
        self.bar = ttk.Progressbar(self.body, mode="determinate",
                                   length=500, maximum=1.0)
        self.bar.pack(anchor="w", pady=(4, 6))
        self.status = tk.Label(self.body, text="Starting…", bg="#ffffff",
                               fg="#444", font=("Helvetica", 12))
        self.status.pack(anchor="w")
        self.logbox = tk.Text(self.body, height=8, width=62, bg="#f4f4f6",
                              relief="flat", font=("Menlo", 10), fg="#555")
        self.logbox.pack(anchor="w", pady=(12, 0))
        Installer(self.state, self.q).start()
        self.after(120, self._poll)

    def _step_done(self, error=None):
        self.clear()
        self.back_btn.pack_forget()
        if error:
            tk.Label(self.body, text="⚠️", bg="#ffffff",
                     font=("Helvetica", 48)).pack(pady=(20, 6))
            self._title("Something went wrong", error)
            self.next_btn.state(["!disabled"])
            self.next_btn.config(text="Close", command=self.destroy)
        else:
            tk.Label(self.body, text="✅", bg="#ffffff",
                     font=("Helvetica", 52)).pack(pady=(24, 8))
            self._title("All set!",
                        "Look for the 🐶 in your menu bar. Open it to see your "
                        "monitors. You can change anything later under "
                        "Preferences.")
            self.next_btn.state(["!disabled"])
            self.next_btn.config(text="Done", command=self.destroy)

    # ---- helpers ----
    def _field(self, parent, label, var, secret=False):
        tk.Label(parent, text=label, bg="#ffffff", fg="#444",
                 font=("Helvetica", 12)).pack(anchor="w", pady=(8, 2))
        ttk.Entry(parent, textvariable=var, width=46,
                  show="•" if secret else "").pack(anchor="w")

    def _site_label(self, value):
        return next((lbl for lbl, v in SITES if v == value), SITES[0][0])

    def _site_value(self, label):
        return next((v for lbl, v in SITES if lbl == label), SITES[0][1])

    # ---- navigation ----
    def _save_current(self):
        if self.idx == 1:
            self.state["site"] = self._site_value(self.region_var.get())
        elif self.idx == 2:
            self.state["auth"] = self.auth_var.get()
            if self.state["auth"] == "keys":
                self.state["api_key"] = self.api_var.get().strip()
                self.state["app_key"] = self.app_var.get().strip()
            else:
                self.state["oauth_client_id"] = self.cid_var.get().strip()
        elif self.idx == 3:
            self.state["tag_filter"] = self.tag_var.get().strip()
            self.state["subdomain"] = self.sub_var.get().strip()

    def back(self):
        if self.idx:
            self.idx -= 1
            self.render()

    def next(self):
        self._save_current()
        if self.idx < len(self.STEPS) - 1:
            self.idx += 1
            self.render()

    def _poll(self):
        try:
            while True:
                kind, *rest = self.q.get_nowait()
                if kind == "log":
                    self.logbox.insert("end", rest[0] + "\n")
                    self.logbox.see("end")
                elif kind == "progress":
                    self.bar["value"] = rest[0]
                    self.status.config(text=rest[1])
                elif kind == "done":
                    return self._step_done()
                elif kind == "error":
                    return self._step_done(error=rest[0])
        except queue.Empty:
            pass
        self.after(120, self._poll)


if __name__ == "__main__":
    Wizard().mainloop()

"""Render the Swift-app design mockups from swift/docs/mockup.html.

Usage:  python3 swift/docs/shoot.py
Output: swift/docs/images/<scene>.png  (Retina @2x)
"""
from playwright.sync_api import sync_playwright
import os

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "images")
os.makedirs(out, exist_ok=True)

scenes = ["scene-hero", "scene-alerting", "scene-expanded", "scene-changes",
          "scene-list", "scene-clear", "scene-notify"]

with sync_playwright() as p:
    # CI/agent environments pre-install Chromium outside playwright's registry;
    # PW_CHROMIUM lets them point at it without a "playwright install" download.
    exe = os.environ.get("PW_CHROMIUM")
    browser = p.chromium.launch(headless=True, executable_path=exe)
    page = browser.new_page(viewport={"width": 1400, "height": 1400},
                            device_scale_factor=2)
    page.goto("file://" + os.path.join(here, "mockup.html"))
    page.wait_for_load_state("networkidle")
    page.wait_for_timeout(800)  # let the webfont settle
    for s in scenes:
        page.locator(f"#{s}").screenshot(path=os.path.join(out, f"{s}.png"))
        print("shot", s)
    browser.close()

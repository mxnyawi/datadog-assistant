"""Render the README screenshots from docs/mockup.html.

Usage:  python3 docs/shoot.py
Output: docs/images/<scene>.png  (Retina @2x)
"""
from playwright.sync_api import sync_playwright
import os

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "images")
os.makedirs(out, exist_ok=True)

scenes = ["scene-menu", "scene-notify", "scene-modal", "scene-prefs"]

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1380, "height": 900},
                            device_scale_factor=2)
    page.goto("file://" + os.path.join(here, "mockup.html"))
    page.wait_for_load_state("networkidle")
    page.wait_for_timeout(800)  # let the webfont settle
    for s in scenes:
        page.locator(f"#{s}").screenshot(path=os.path.join(out, f"{s}.png"))
        print("shot", s)
    browser.close()

"""Render installer wizard mockups for the website install tutorial.

Usage:  python3 docs/installer/shoot.py
Output: docs/installer/images/<scene>.png  (Retina @2x)
"""
from playwright.sync_api import sync_playwright
import os

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "images")
os.makedirs(out, exist_ok=True)

scenes = ["s-welcome", "s-region", "s-signin", "s-install", "s-done"]

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 720, "height": 620},
                            device_scale_factor=2)
    page.goto("file://" + os.path.join(here, "mockup.html"))
    page.wait_for_load_state("networkidle")
    page.wait_for_timeout(500)
    for s in scenes:
        page.locator(f"#{s}").screenshot(path=os.path.join(out, f"{s}.png"))
        print("shot", s)
    browser.close()

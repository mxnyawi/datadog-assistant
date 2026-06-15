"""Render the Product Hunt launch gallery from gallery.html.

Usage:  python3 docs/launch/shoot_launch.py
Output: docs/launch/images/<id>.png  (Retina @2x)
        ph-01..ph-05 are 1270x760 gallery slides; ph-thumb is the square icon.
"""
from playwright.sync_api import sync_playwright
import os

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "images")
os.makedirs(out, exist_ok=True)

# (element id, output filename)
shots = [
    ("s1", "ph-01-hero"),
    ("s2", "ph-02-unmissable"),
    ("s3", "ph-03-one-click"),
    ("s4", "ph-04-features"),
    ("s5", "ph-05-preferences"),
    ("thumb", "ph-thumb"),
]

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1400, "height": 900},
                            device_scale_factor=2)
    page.goto("file://" + os.path.join(here, "gallery.html"))
    page.wait_for_load_state("networkidle")
    page.wait_for_timeout(800)  # let the webfont settle
    for el, name in shots:
        page.locator(f"#{el}").screenshot(path=os.path.join(out, f"{name}.png"))
        print("shot", name)
    browser.close()

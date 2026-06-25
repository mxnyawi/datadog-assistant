#!/bin/bash
# One-command release , RUN ON A MAC.
# Builds the Datadog Assistant.app (self-onboarding GUI + menu-bar app), zips
# it, tags the repo, and publishes a GitHub Release with the app attached. The
# website Download button then resolves.
#
#   ./installer/release.sh v0.3.0
#
# Needs: macOS (py2app) + the GitHub CLI `gh` (authenticated).
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

TAG="${1:-}"
if [ -z "$TAG" ]; then
  echo "Usage: ./installer/release.sh vX.Y.Z   (e.g. v0.3.0)" >&2
  exit 1
fi

echo "🐶 Building Datadog Assistant.app for $TAG ..."
bash installer/build_menubar_app.sh   # → dist/Datadog Assistant.app

echo "📦 Zipping ..."
# Keep the historical asset name so the website/README download links resolve;
# the zip now contains the self-onboarding app itself.
ditto -c -k --keepParent \
    "dist/Datadog Assistant.app" "installer/Datadog-Assistant-Installer.zip"

echo "🔐 Generating SHA-256 checksum ..."
# Lets users verify the download wasn't tampered with (the .app is unsigned).
# Written with just the bare filename so `shasum -a 256 -c` works from the
# directory the zip is downloaded into.
( cd installer && shasum -a 256 "Datadog-Assistant-Installer.zip" \
    > "Datadog-Assistant-Installer.zip.sha256" )
echo "   $(cd installer && cat Datadog-Assistant-Installer.zip.sha256)"

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "🏷  Tagging $TAG ..."
  git tag "$TAG"
  git push origin "$TAG"
fi

echo "🚀 Publishing the release ..."
if gh release create "$TAG" \
    "installer/Datadog-Assistant-Installer.zip" \
    "installer/Datadog-Assistant-Installer.zip.sha256" \
    --title "Datadog Assistant $TAG" \
    --notes-file installer/RELEASE_NOTES.md \
    --latest; then
  :
else
  echo "Release exists , updating the assets ..."
  gh release upload "$TAG" \
    "installer/Datadog-Assistant-Installer.zip" \
    "installer/Datadog-Assistant-Installer.zip.sha256" --clobber
fi

echo ""
echo "✅ Released $TAG"
echo "   Download: https://github.com/mxnyawi/datadog-assistant/releases/latest/download/Datadog-Assistant-Installer.zip"
echo "   Verify:   shasum -a 256 -c Datadog-Assistant-Installer.zip.sha256"

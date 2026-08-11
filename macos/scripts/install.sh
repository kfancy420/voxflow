#!/bin/bash
# One-command install: builds VoxFlow.app and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift toolchain not found."
  echo "Install the Xcode Command Line Tools first:  xcode-select --install"
  echo "...then re-run this script."
  exit 1
fi

bash scripts/make_app.sh

echo "==> Installing to /Applications..."
# Quit any previously-installed copy so its bundle can be replaced.
pkill -x VoxFlow >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/VoxFlow.app
cp -R build/VoxFlow.app /Applications/VoxFlow.app

echo "==> Launching VoxFlow..."
open /Applications/VoxFlow.app

cat <<'EOF'

------------------------------------------------------------
VoxFlow is installed. Two one-time permissions to grant:

1. MICROPHONE - macOS will ask the first time you hold the
   hotkey. Click "Allow".

2. ACCESSIBILITY - needed for the global hotkey and for
   inserting text. macOS should prompt on first launch; if
   not: System Settings > Privacy & Security > Accessibility
   > enable VoxFlow. (If the hotkey still does nothing, also
   check Privacy & Security > Input Monitoring.)

After granting Accessibility, VoxFlow picks it up
automatically within a few seconds - no restart needed.

USAGE: hold RIGHT CMD, speak, release. Cleaned text is typed
into whatever app has focus. Configure via the menu-bar mic.

First run downloads the Whisper "small.en" model (~500 MB);
watch progress in the menu-bar dropdown.
------------------------------------------------------------
EOF

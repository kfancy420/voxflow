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
#
# The app keeps itself alive through a launchd agent (label com.voxflow.app)
# that relaunches it after a crash — so it must be unloaded before it is
# killed, or launchd will simply bring it back mid-copy. Two generations:
# the bundled agent the app registers itself, and a hand-written
# ~/Library/LaunchAgents plist earlier installs used (same label; retired).
AGENT_LABEL="com.voxflow.app"
LEGACY_PLIST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
INSTALLED_BIN="/Applications/VoxFlow.app/Contents/MacOS/VoxFlow"
# Background Task Management caches the agent plist as registered, so the
# previous build must unregister before the bundle is replaced; the new one
# re-registers on launch.
AGENT_WAS="first-install"
# Only builds that ship the agent understand --unregister-agent; an older
# binary would treat it as a normal launch.
if [[ -x "${INSTALLED_BIN}" && -f "/Applications/VoxFlow.app/Contents/Library/LaunchAgents/${AGENT_LABEL}.plist" ]]; then
  AGENT_WAS="$("${INSTALLED_BIN}" --unregister-agent 2>/dev/null || echo "unknown")"
fi
launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" >/dev/null 2>&1 || true
if [[ -f "${LEGACY_PLIST}" ]]; then
  echo "    retiring legacy LaunchAgent ${LEGACY_PLIST}"
  rm -f "${LEGACY_PLIST}"
fi
pkill -x VoxFlow >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/VoxFlow.app
cp -R build/VoxFlow.app /Applications/VoxFlow.app

echo "==> Launching VoxFlow..."
# Re-arm the launch agent (launch at login + relaunch after crash) unless the
# user had deliberately turned it off. Registering starts the managed copy
# straight away; on a first install the app enables it itself on first run.
# The `open` below is the fallback for when the agent needs approval in
# System Settings — a second copy simply yields to the managed one.
if [[ "${AGENT_WAS}" == "was-enabled" ]]; then
  echo "    re-registering launch agent"
  "${INSTALLED_BIN}" --register-agent || true
  sleep 1
fi
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

VoxFlow registers itself to launch at login and to relaunch
after a crash (System Settings > General > Login Items lists
it under "Allow in the Background"). Turn it off from the
menu bar if you'd rather launch it by hand.

First run downloads the Whisper "small.en" model (~500 MB);
watch progress in the menu-bar dropdown. If something goes
wrong, "Open Log..." in the menu shows what happened.
------------------------------------------------------------
EOF

#!/bin/bash
# Builds VoxFlow.app from the SwiftPM package. Run from the project root.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building VoxFlow (release)..."
swift build -c release 1>&2

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="${BIN_DIR}/VoxFlow"
if [[ ! -f "${BIN}" ]]; then
  echo "Build product not found at ${BIN}" >&2
  exit 1
fi

APP="build/VoxFlow.app"
echo "==> Assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/VoxFlow"
cp Resources/Info.plist "${APP}/Contents/Info.plist"

# SwiftPM emits dependency resource bundles (e.g. WhisperKit's) next to the
# executable; Bundle.module looks for them in Contents/Resources at runtime.
shopt -s nullglob
for bundle in "${BIN_DIR}"/*.bundle; do
  echo "==> Bundling $(basename "$bundle")..."
  cp -R "$bundle" "${APP}/Contents/Resources/"
done
shopt -u nullglob

echo "==> Code signing..."
# Prefer a stable identity (TCC permission grants survive rebuilds);
# fall back to ad-hoc if none is available.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')"
if [[ -n "${IDENTITY}" ]]; then
  echo "    signing as: ${IDENTITY}"
  codesign --force --sign "${IDENTITY}" "${APP}"
else
  echo "    no stable identity found; ad-hoc signing"
  codesign --force --sign - "${APP}"
fi

echo "==> Done: ${APP}"

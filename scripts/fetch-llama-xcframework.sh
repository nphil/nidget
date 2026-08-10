#!/usr/bin/env bash
#
# Fetch the prebuilt llama.xcframework into Frameworks/.
#
# The framework is built by the "Build llama.xcframework" GitHub workflow
# (.github/workflows/build-llama-xcframework.yml) from llama.cpp pinned in
# scripts/build-llama-xcframework.sh, and published as a prerelease asset tagged
# llama-<pin7> with the file llama.xcframework.zip. This script downloads and
# unpacks that asset. Run it once before opening Xcode; CI runs it on every
# build (a cache hit makes it a no-op).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_SCRIPT="${REPO_ROOT}/scripts/build-llama-xcframework.sh"

# Read the pin the same way the build workflow does.
LLAMA_PIN=$(grep -m1 'LLAMA_PIN=' "${BUILD_SCRIPT}" | cut -d'"' -f2 || true)
if [ -z "${LLAMA_PIN}" ]; then
    echo "error: could not read LLAMA_PIN from ${BUILD_SCRIPT}" >&2
    exit 1
fi

TAG="llama-${LLAMA_PIN:0:7}"
URL="https://github.com/nphil/nidget/releases/download/${TAG}/llama.xcframework.zip"

FRAMEWORKS_DIR="${REPO_ROOT}/Frameworks"
FRAMEWORK_DIR="${FRAMEWORKS_DIR}/llama.xcframework"
# The marker lives INSIDE the xcframework container so the CI cache (which caches
# Frameworks/llama.xcframework) round-trips it. Xcode ignores extra dotfiles there.
MARKER="${FRAMEWORK_DIR}/.llama-pin"

if [ -f "${FRAMEWORK_DIR}/Info.plist" ] && [ -f "${MARKER}" ] \
    && [ "$(cat "${MARKER}")" = "${LLAMA_PIN}" ]; then
    echo "llama.xcframework already present for pin ${LLAMA_PIN:0:7} — nothing to do."
    exit 0
fi

echo "Fetching llama.xcframework (${TAG})..."
mkdir -p "${FRAMEWORKS_DIR}"
ZIP_PATH="${FRAMEWORKS_DIR}/llama.xcframework.zip"
rm -f "${ZIP_PATH}"

if ! curl -fL --retry 3 -o "${ZIP_PATH}" "${URL}"; then
    echo "::error::Could not download ${URL} — the ${TAG} release asset does not exist (or is unreachable)." >&2
    echo "::error::Run the \"Build llama.xcframework\" GitHub workflow first (Actions → Build llama.xcframework → Run workflow), then retry." >&2
    rm -f "${ZIP_PATH}"
    exit 1
fi

rm -rf "${FRAMEWORK_DIR}"
# ditto preserves symlinks/permissions on macOS; unzip is the portable fallback.
if command -v ditto > /dev/null 2>&1; then
    ditto -x -k "${ZIP_PATH}" "${FRAMEWORKS_DIR}"
else
    unzip -q "${ZIP_PATH}" -d "${FRAMEWORKS_DIR}"
fi
rm -f "${ZIP_PATH}"

if [ ! -f "${FRAMEWORK_DIR}/Info.plist" ]; then
    echo "error: unpack did not produce ${FRAMEWORK_DIR}/Info.plist — bad release asset?" >&2
    exit 1
fi

printf '%s' "${LLAMA_PIN}" > "${MARKER}"
echo "Unpacked ${FRAMEWORK_DIR} (pin ${LLAMA_PIN:0:7})."

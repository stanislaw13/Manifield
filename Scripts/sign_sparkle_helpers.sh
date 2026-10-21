#!/bin/bash
#
# Re-sign Sparkle's nested helpers with the app's own identity.
#
# Sparkle ships Autoupdate, Updater.app and its two XPC services ad-hoc signed
# (`Signature=adhoc`, `TeamIdentifier=not set`) — upstream leaves them for the embedding
# app to sign. Xcode's "embed and sign" only signs the top-level Sparkle.framework and
# seals the helpers *by reference*, so without this they stay ad-hoc: the notary service
# rejects code that is not Developer ID signed, and the hardened runtime is entitled to
# refuse to launch a helper from a different team.
#
# Runs as a post-build phase, which is BEFORE the build system's final signing of the
# .app — so signing the helpers and the framework here leaves the app's own seal to Xcode
# and everything ends up sealed inside out, without `codesign --deep` anywhere.
set -euo pipefail

# CI builds with CODE_SIGNING_ALLOWED=NO, and there is nothing to re-sign with.
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
    echo "note: code signing disabled, leaving Sparkle helpers alone"
    exit 0
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
    echo "note: no signing identity resolved, leaving Sparkle helpers alone"
    exit 0
fi

FRAMEWORK="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"
if [ ! -d "$FRAMEWORK" ]; then
    echo "note: Sparkle.framework not embedded, nothing to sign"
    exit 0
fi

# A secure timestamp is required for notarization but needs the network on every build.
# Development builds are never notarized, so only pay for it on Developer ID.
case "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" in
    "Developer ID"*) TIMESTAMP="--timestamp" ;;
    *)               TIMESTAMP="--timestamp=none" ;;
esac

# Inside out: each helper first, then the framework version whose seal covers them.
# `Versions/*` rather than a hardcoded `Versions/B` so a future Sparkle that bumps its
# version letter does not silently skip everything here.
for version in "$FRAMEWORK"/Versions/*; do
    [ -d "$version" ] || continue
    [ "$(basename "$version")" = "Current" ] && continue

    for helper in \
        "XPCServices/Downloader.xpc" \
        "XPCServices/Installer.xpc" \
        "Updater.app" \
        "Autoupdate"
    do
        [ -e "$version/$helper" ] || continue
        codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$version/$helper"
    done

    codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$version"
done

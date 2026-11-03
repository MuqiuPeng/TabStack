#!/bin/bash
# Builds TabStack.app into ./build. Accessibility permission is tied to the app's
# code signature, so set SIGN_IDENTITY to a stable certificate to avoid re-granting
# the permission after every rebuild (ad-hoc signing "-" is the default).
set -euo pipefail
cd "$(dirname "$0")"

# Prefer the stable local certificate from scripts/make-signing-cert.sh when present.
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "TabStack Local Signing"; then
    SIGN_IDENTITY="TabStack Local Signing"
fi

swift build -c release

APP=build/TabStack.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TabStack "$APP/Contents/MacOS/TabStack"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

echo "Built $APP"

# Restart so the new build is what's running. Pass --no-run to skip.
if [[ "${1:-}" != "--no-run" ]]; then
    osascript -e 'tell application id "com.guanshunpeng.TabStack" to quit' 2>/dev/null || true
    for _ in {1..20}; do pgrep -f "TabStack.app/Contents/MacOS/TabStack" >/dev/null || break; sleep 0.1; done
    pkill -f "TabStack.app/Contents/MacOS/TabStack" 2>/dev/null || true
    open "$APP"
    echo "Restarted TabStack"
fi

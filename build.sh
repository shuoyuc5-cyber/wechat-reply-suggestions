#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/../微信回复建议.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/.build-cache"
/usr/bin/xcrun swiftc -O "$ROOT/Main.swift" "$ROOT/ReplyStyle.swift" "$ROOT/OneShotOCR.swift" "$ROOT/CurrentConversation.swift" "$ROOT/FloatingWindow.swift" "$ROOT/WindowAccess.swift" "$ROOT/LocalSelectionAI.swift" "$ROOT/Profiles.swift" "$ROOT/ScreenReader.swift" "$ROOT/OCRDiagnostics.swift" "$ROOT/CropState.swift" "$ROOT/CloudProvider.swift" -o "$APP/Contents/MacOS/LocalReply" -framework Cocoa -framework WebKit -framework ApplicationServices -framework Carbon -framework ScreenCaptureKit -framework Vision -framework Security -swift-version 5 -module-cache-path "$ROOT/.build-cache" -target arm64-apple-macos14.0
/bin/cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$ROOT/float.html" "$APP/Contents/Resources/float.html"
/bin/cp "$ROOT/index.html" "$APP/Contents/Resources/index.html"
if [[ -f "$ROOT/AppIcon.icns" ]]; then /bin/cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi
/bin/cp "$ROOT/BrandIcon.png" "$APP/Contents/Resources/BrandIcon.png"
/usr/bin/codesign --force --sign - "$APP"
echo "已构建：$APP"

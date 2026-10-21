#!/bin/zsh
# Builds "Clear Dock.app" into ./build. Pass "install" to also copy it to /Applications.
set -euo pipefail
cd "${0:A:h}"

swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)"

app="build/Clear Dock.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/ClearDock" "$app/Contents/MacOS/ClearDock"
cp Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# A stable signature lets macOS remember permissions (like Accessibility) across rebuilds.
identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${identity:--}" "$app"
echo "Built $app"

if [[ "${1:-}" == "install" ]]; then
  rm -rf "/Applications/Clear Dock.app"
  cp -R "$app" /Applications/
  echo "Installed /Applications/Clear Dock.app"
fi

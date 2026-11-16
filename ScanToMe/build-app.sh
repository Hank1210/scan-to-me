#!/bin/zsh
# Baut „Scan to me.app“ (ad hoc signiert) nach ScanToMe/build/.
# build ist ein Verweis auf build.noindex: Spotlight indiziert ihn nicht, sonst erscheint jeder Build in der App-Übersicht.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build.noindex
[[ -L build ]] || ln -s build.noindex build

swift build -c release --product ScanToMeApp

APP="build/Scan to me.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Leere Sprachordner: macOS zeigt Menüs und Dialoge dann in der in der App gewählten Sprache (nach Neustart).
mkdir -p "$APP/Contents/Resources/de.lproj" "$APP/Contents/Resources/en.lproj"
cp "$(swift build -c release --show-bin-path)/ScanToMeApp" "$APP/Contents/MacOS/ScanToMeApp"
cp Support/ScanToMe-Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "Fertig: $PWD/$APP"

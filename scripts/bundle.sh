#!/bin/zsh
# Builds OmniCast.app. libobs and the OBS plugins are used in place from OBS.app
# through the Frameworks and PlugIns links, so OBS.app must stay installed.
set -euo pipefail
cd "${0:A:h}/.."

config=${1:-release}
swift build -c "$config" --arch arm64

app=build/OmniCast.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c "$config" --arch arm64 --show-bin-path)/OmniCast" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
ln -s /Applications/OBS.app/Contents/Frameworks "$app/Contents/Frameworks"
ln -s /Applications/OBS.app/Contents/PlugIns "$app/Contents/PlugIns"

# macOS ties Screen Recording / Camera / Mic permission to the signature. An
# ad-hoc signature changes on every build, so each rebuild would ask again.
# Signing with a fixed local certificate keeps the grants across rebuilds.
identity=${OMNICAST_SIGN_IDENTITY:-OmniCast Local}
if security find-identity -p codesigning | grep -q "\"$identity\""; then
	codesign --force --sign "$identity" --identifier com.jaiden56.omnicast "$app/Contents/MacOS/OmniCast"
	echo "Signed with \"$identity\""
else
	codesign --force --sign - --identifier com.jaiden56.omnicast "$app/Contents/MacOS/OmniCast"
	echo "warning: no \"$identity\" certificate, signed ad hoc: macOS will ask for permissions again after every build" >&2
fi
echo "Built $app"

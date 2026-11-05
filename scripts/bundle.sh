#!/bin/zsh
# Builds OmniCast.app with libobs, the libraries it links and the OBS plugins
# OmniCast loads copied inside it, so the app runs without OBS.app installed.
# They come from vendor/obs-runtime, which scripts/obs-runtime.sh fills from
# OBS.app the first time.
set -euo pipefail
cd "${0:A:h}/.."

config=${1:-release}
./scripts/obs-runtime.sh
swift build -c "$config" --arch arm64

app=build/OmniCast.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c "$config" --arch arm64 --show-bin-path)/OmniCast" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
ditto vendor/obs-runtime/Frameworks "$app/Contents/Frameworks"
ditto vendor/obs-runtime/PlugIns "$app/Contents/PlugIns"

# macOS ties Screen Recording / Camera / Mic permission to the signature. An
# ad-hoc signature changes on every build, so each rebuild would ask again.
# Signing with a fixed local certificate keeps the grants across rebuilds.
identity=${OMNICAST_SIGN_IDENTITY:-OmniCast Local}
if security find-identity -p codesigning | grep -q "\"$identity\""; then
	sign=$identity
else
	sign=-
	echo "warning: no \"$identity\" certificate, signed ad hoc: macOS will ask for permissions again after every build" >&2
fi

# Nested code first (it replaces OBS's signatures), then the app, which seals it all.
for f in "$app"/Contents/Frameworks/*.dylib "$app"/Contents/Frameworks/*.framework/Versions/A \
	"$app"/Contents/PlugIns/*.plugin; do
	codesign --force --sign "$sign" "$f"
done
codesign --force --sign "$sign" --identifier com.jaiden56.omnicast "$app"
codesign --verify --strict "$app"
[[ $sign == - ]] || echo "Signed with \"$identity\""
echo "Built $app"

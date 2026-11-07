#!/bin/zsh
# Copies libobs, the libraries it links and the OBS plugins OmniCast loads out of
# OBS.app into vendor/obs-runtime. The build links against that copy and
# bundle.sh puts it inside OmniCast.app. OBS.app is used if it's installed;
# otherwise the official OBS release disk image is downloaded (checksum-pinned)
# and read without installing anything. This runs once (or with --refresh).
#
#   OBS_APP=/path/to/OBS.app ./scripts/obs-runtime.sh [--refresh]
set -euo pipefail
cd "${0:A:h}/.."

OBS_APP=${OBS_APP:-/Applications/OBS.app}
cache=vendor/obs-runtime

# The plugins that provide every source, encoder, output and service OmniCast
# creates (see the obs_*_create calls in Sources/OmniEngine):
#   mac-capture        screen_capture, sck_audio_capture, coreaudio_input_capture
#   mac-avcapture      macos-avcapture (camera, capture card)
#   mac-videotoolbox   hardware H.264 / HEVC encoders
#   obs-x264           obs_x264, used if VideoToolbox has no H.264 encoder
#   coreaudio-encoder  CoreAudio_AAC
#   obs-outputs        rtmp_output, mp4_output
#   rtmp-services      rtmp_custom
#   image-source       image_source (overlays, call members)
#   obs-filters        color_filter, color_filter_v2
plugins=(mac-capture mac-avcapture mac-videotoolbox obs-x264 coreaudio-encoder obs-outputs rtmp-services
	image-source obs-filters)
# Loaded by path rather than linked: the graphics modules.
roots=(libobs.framework libobs-metal.dylib libobs-opengl.dylib)

stamp="plugins: ${plugins[*]}"
if [[ ${1:-} != --refresh && -f $cache/STAMP && "$(tail -n +2 $cache/STAMP)" == "$stamp" ]]; then
	exit 0
fi

if [[ ! -d $OBS_APP ]]; then
	if [[ -d $cache/Frameworks && ${1:-} != --refresh ]]; then
		echo "warning: $OBS_APP not found, keeping the cached copy in $cache as it is" >&2
		exit 0
	fi
	# No OBS installed: take OBS.app from the official release disk image, checked
	# against its published SHA-256, without installing it.
	dmg_version=32.0.4
	dmg_name=OBS-Studio-$dmg_version-macOS-Apple.dmg
	dmg_sha256=7c056644636a794cb18281af98d54b5795ad8b0985e950d93b8c510b645b6298
	dmg=vendor/downloads/$dmg_name
	mkdir -p vendor/downloads
	if [[ ! -f $dmg ]] || [[ "$(shasum -a 256 "$dmg" | cut -d' ' -f1)" != $dmg_sha256 ]]; then
		echo "Downloading OBS $dmg_version from GitHub (about 190 MB, once)..."
		curl -fL --progress-bar -o "$dmg.part" \
			"https://github.com/obsproject/obs-studio/releases/download/$dmg_version/$dmg_name"
		mv "$dmg.part" "$dmg"
	fi
	if [[ "$(shasum -a 256 "$dmg" | cut -d' ' -f1)" != $dmg_sha256 ]]; then
		echo "error: $dmg doesn't match the published SHA-256; delete it and try again" >&2
		exit 1
	fi
	mnt=$(mktemp -d /tmp/omnicast-obs.XXXXXX)
	hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$dmg"
	trap 'hdiutil detach -quiet "$mnt" 2>/dev/null; rmdir "$mnt" 2>/dev/null' EXIT
	OBS_APP=$mnt/OBS.app
fi

version=$(defaults read "$OBS_APP/Contents/Info.plist" CFBundleShortVersionString)
src=$OBS_APP/Contents
tmp=$cache.tmp
rm -rf "$tmp"
mkdir -p "$tmp/Frameworks" "$tmp/PlugIns"

# Every library is linked as @rpath/<name>, and every binary's rpath is
# @executable_path/../Frameworks, so copying them into Contents/Frameworks is
# all it takes. Follow the @rpath references until nothing new turns up.
typeset -A have
queue=()
need() {
	local name=$1
	[[ -n ${have[$name]:-} ]] && return
	have[$name]=1
	[[ -e $src/Frameworks/$name ]] || { echo "error: $name not in $src/Frameworks" >&2; exit 1; }
	ditto "$src/Frameworks/$name" "$tmp/Frameworks/$name"
	if [[ $name == *.framework ]]; then
		queue+=("$tmp/Frameworks/$name/Versions/A/${name%.framework}")
	else
		queue+=("$tmp/Frameworks/$name")
	fi
}

for r in $roots; do need $r; done
for p in $plugins; do
	ditto "$src/PlugIns/$p.plugin" "$tmp/PlugIns/$p.plugin"
	queue+=("$tmp/PlugIns/$p.plugin/Contents/MacOS/$p")
done

while (( ${#queue} )); do
	bin=${queue[1]}
	queue=("${(@)queue[2,-1]}")
	for dep in ${(f)"$(otool -L "$bin" | awk 'NR > 1 && $1 ~ /^@rpath\// {print $1}')"}; do
		name=${${dep#@rpath/}%%/*}
		need $name
	done
done

{ echo "OBS $version"; echo "$stamp"; } > "$tmp/STAMP"
rm -rf "$cache"
mv "$tmp" "$cache"
echo "Copied libobs $version and ${#plugins} plugins from $OBS_APP into $cache ($(du -sh "$cache" | cut -f1))"

#!/bin/zsh
# Copies libobs, the libraries it links and the OBS plugins OmniCast loads out of
# OBS.app into vendor/obs-runtime. The build links against that copy and
# bundle.sh puts it inside OmniCast.app, so OBS.app is only needed the first
# time (or with --refresh after updating OBS.app and the headers).
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
	if [[ -d $cache/Frameworks ]]; then
		echo "warning: $OBS_APP not found, keeping the cached copy in $cache as it is" >&2
		exit 0
	fi
	echo "error: $OBS_APP not found and there is no cached copy in $cache." >&2
	echo "Install OBS.app (any copy will do: OBS_APP=/path/to/OBS.app) to fill the cache once." >&2
	exit 1
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

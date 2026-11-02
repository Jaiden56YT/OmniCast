#!/bin/zsh
# Fetches the libobs headers matching the installed OBS.app and the simde headers they need.
set -euo pipefail
cd "${0:A:h}/.."

OBS_APP=/Applications/OBS.app
version=$(defaults read "$OBS_APP/Contents/Info.plist" CFBundleShortVersionString)
echo "OBS.app is $version"

if [[ ! -d vendor/obs-studio ]]; then
	git clone --depth 1 --branch "$version" --filter=blob:none --sparse \
		https://github.com/obsproject/obs-studio.git vendor/obs-studio
	git -C vendor/obs-studio sparse-checkout set libobs
fi

if [[ ! -d vendor/include/simde ]]; then
	brew list simde >/dev/null 2>&1 || brew install simde
	cp -R "$(brew --prefix simde)/include/simde" vendor/include/simde
fi

#!/bin/zsh
# Copies libobs and the OBS plugins OmniCast uses out of OBS.app into
# vendor/obs-runtime (once), then fetches the libobs headers of the same version
# and the simde headers they need. After the first run OBS.app can be deleted.
set -euo pipefail
cd "${0:A:h}/.."

./scripts/obs-runtime.sh "$@"
version=$(head -1 vendor/obs-runtime/STAMP | sed 's/^OBS //')
echo "libobs is $version"

if [[ ! -d vendor/obs-studio ]]; then
	git clone --depth 1 --branch "$version" --filter=blob:none --sparse \
		https://github.com/obsproject/obs-studio.git vendor/obs-studio
	git -C vendor/obs-studio sparse-checkout set libobs
fi

if [[ ! -d vendor/include/simde ]]; then
	brew list simde >/dev/null 2>&1 || brew install simde
	cp -R "$(brew --prefix simde)/include/simde" vendor/include/simde
fi

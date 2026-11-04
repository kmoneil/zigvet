#!/usr/bin/env bash
# Puts gnarl (github.com/kmoneil/gnarl) on a GitHub Actions runner's PATH,
# for the complexity check `zig build test` runs. One release, pinned with
# the checksum of each binary a runner here uses, so a new gnarl release
# cannot fail an unchanged commit: moving to one means changing the version
# and the sums here, and complexity.baseline if its counting changed.
# build.zig reads the version line too, and fails the complexity step when
# the gnarl on the PATH is another release. Locally, install gnarl from its
# release or `brew install kmoneil/tap/gnarl`.
#
#   scripts/install-gnarl.sh
#
# Reads RUNNER_OS, RUNNER_ARCH, RUNNER_TEMP and GITHUB_PATH, which every
# runner sets. Exit status: 0 when gnarl is installed and runs, 1 when the
# download does not match its checksum or does not run, 2 on a runner with
# no binary pinned here.
set -euo pipefail

version=v0.6.0

case "${RUNNER_OS}-${RUNNER_ARCH}" in
Linux-X64)
	asset=gnarl-linux-amd64
	sum=d8cde27f1230843e5c65d9d1bade415609de3fa6bbc8d00acfb9e75617d00900
	;;
macOS-ARM64)
	asset=gnarl-darwin-arm64
	sum=16cb0f54f0db4ed4577fb9462c463de24ca03ef1350589f4e60c45f7573d74ee
	;;
Windows-X64)
	asset=gnarl-windows-amd64.exe
	sum=8b701a912f529e10e56e317392e7ab38e27b90cef0413582e1b5a57160feac57
	;;
*)
	echo "install-gnarl: no gnarl binary pinned for ${RUNNER_OS}-${RUNNER_ARCH}" >&2
	exit 2
	;;
esac

# Its own directory, so nothing else in RUNNER_TEMP lands on the PATH.
dir="${RUNNER_TEMP}/gnarl"
mkdir -p "$dir"
bin="$dir/gnarl"
if [ "$RUNNER_OS" = Windows ]; then bin="$bin.exe"; fi

curl -fsSL -o "$bin" "https://github.com/kmoneil/gnarl/releases/download/${version}/${asset}"
# Hashed from stdin: given a path with a backslash in it, as RUNNER_TEMP is
# on Windows, sha256sum escapes the name and starts its line with a `\`.
if command -v sha256sum >/dev/null; then
	got=$(sha256sum <"$bin")
else
	got=$(shasum -a 256 <"$bin")
fi
got=${got%% *}
if [ "$got" != "$sum" ]; then
	echo "install-gnarl: $asset $version has checksum $got, not $sum" >&2
	exit 1
fi
chmod +x "$bin"
"$bin" --version
echo "$dir" >>"$GITHUB_PATH"

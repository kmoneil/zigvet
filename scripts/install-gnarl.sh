#!/usr/bin/env bash
# Puts gnarl (github.com/kmoneil/gnarl) on a GitHub Actions runner's PATH,
# for the complexity check `zig build test` runs. One release, pinned with
# the checksum of each binary a runner here uses, so a new gnarl release
# cannot fail an unchanged commit: moving to one means changing the version
# and the sums here, and complexity.baseline if its counting changed.
# Locally, install gnarl from its release or `brew install kmoneil/tap/gnarl`.
#
#   scripts/install-gnarl.sh
#
# Reads RUNNER_OS, RUNNER_ARCH, RUNNER_TEMP and GITHUB_PATH, which every
# runner sets. Exit status: 0 when gnarl is installed and runs, 1 when the
# download does not match its checksum or does not run, 2 on a runner with
# no binary pinned here.
set -euo pipefail

version=v0.3.1

case "${RUNNER_OS}-${RUNNER_ARCH}" in
Linux-X64)
	asset=gnarl-linux-amd64
	sum=7e47113d7506176fa83bc544139654b8f900050b1c37483d5043de07ffe74db6
	;;
macOS-ARM64)
	asset=gnarl-darwin-arm64
	sum=a32ca2882e25154d18b3a5ffc7168beb5364d364294339ca63ff56bea784e162
	;;
Windows-X64)
	asset=gnarl-windows-amd64.exe
	sum=61bd62b17562a3f956abc0516492e08d976ec0d7e5ce3d5db3cc9068b86ed3b9
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

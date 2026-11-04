#!/usr/bin/env bash
# Builds zigvet the way a project that depends on it does: the tree packed
# as `zig fetch` packs it, build.zig.zon's .paths and nothing else, saved
# into an empty project whose build.zig installs the zigvet artifact. A
# file zigvet's build.zig reads that .paths leaves out fails it here; from
# v0.23.0 to v0.25.0 that was scripts/install-gnarl.sh (#174).
#
#   scripts/dependency-build.sh
#
# Packs the working tree's tracked files, changes not yet committed
# included. Exit status: 0 when the dependency builds and its zigvet prints
# build.zig.zon's version, 1 when it does not.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The working tree as a commit, or HEAD when nothing tracked has changed.
tree=$(git -C "$root" stash create)
git -C "$root" archive --format=tar.gz --prefix=zigvet/ "${tree:-HEAD}" >"$tmp/zigvet.tar.gz"

mkdir "$tmp/consumer"
cd "$tmp/consumer"
cat >build.zig <<'EOF'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const zigvet = b.dependency("zigvet", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
    b.installArtifact(zigvet.artifact("zigvet"));
}
EOF
# The fingerprint is the one Zig gives a package named consumer.
cat >build.zig.zon <<'EOF'
.{
    .name = .consumer,
    .version = "0.0.0",
    .fingerprint = 0x705b372782049a91,
    .dependencies = .{},
    .paths = .{""},
}
EOF

zig fetch --save=zigvet "$tmp/zigvet.tar.gz"
if ! zig build; then
	echo "dependency-build: zigvet does not build as a dependency" >&2
	exit 1
fi
want="zigvet $(sed -n 's/^    \.version = "\(.*\)",$/\1/p' "$root/build.zig.zon")"
got=$(zig-out/bin/zigvet --version)
if [ "$got" != "$want" ]; then
	echo "dependency-build: the dependency's zigvet prints '$got', not '$want'" >&2
	exit 1
fi
echo "dependency-build: $got builds as a dependency"

#!/usr/bin/env bash
# Runs two builds of zigvet over the same code and prints only the reports
# that differ, with how long each took (the fastest of three runs), so a
# rule change shows what it adds and what it drops without reading every
# report by hand.
#
#   scripts/corpus-diff.sh [--base <ref|binary>] [--head <ref|binary>] [<dir>...]
#
# --base is a git ref, built here, or a zigvet binary; it defaults to the
# latest tag. --head is the same, and defaults to the working tree, changes
# not yet committed included. Both are built with -Doptimize=ReleaseSafe; a
# ref's build is kept in .zig-cache/corpus-diff, keyed by commit and Zig
# version, so the next run reuses it.
#
# The directories are the arguments, or else the lines of corpus.txt in the
# repository root, which is gitignored because it names paths on this
# machine: one directory per line, `#` starting a comment line, `~/` for the
# home directory. Each is vetted from inside it (`zigvet .`), so reports
# print relative to it.
#
# Exit status: 0 when every directory gives the same reports, 1 when any
# differs or either zigvet exits with something other than 0 or 1, 2 on
# a usage error or a zigvet that does not build.
set -euo pipefail

usage() {
	echo "usage: scripts/corpus-diff.sh [--base <ref|binary>] [--head <ref|binary>] [<dir>...]" >&2
	exit 2
}

fail() {
	echo "corpus-diff: $*" >&2
	exit 2
}

root=$(git rev-parse --show-toplevel)
base_arg=
head_arg=
dirs=()
while [ $# -gt 0 ]; do
	case $1 in
	--base | --head)
		[ $# -ge 2 ] || usage
		if [ "$1" = --base ]; then base_arg=$2; else head_arg=$2; fi
		shift 2
		;;
	-h | --help) usage ;;
	-*) echo "corpus-diff: unknown option $1" >&2 && usage ;;
	*)
		dirs+=("$1")
		shift
		;;
	esac
done

if [ ${#dirs[@]} -eq 0 ]; then
	list=$root/corpus.txt
	[ -f "$list" ] || fail "no directories given, and no $list to read them from"
	while IFS= read -r line || [ -n "$line" ]; do
		# Trim the line's ends; skip blanks and comments.
		line=${line#"${line%%[![:space:]]*}"}
		line=${line%"${line##*[![:space:]]}"}
		case $line in "" | "#"*) continue ;; "~/"*) line=$HOME/${line#"~/"} ;; esac
		dirs+=("$line")
	done <"$list"
	[ ${#dirs[@]} -gt 0 ] || fail "$list names no directory"
fi
for i in "${!dirs[@]}"; do
	[ -d "${dirs[$i]}" ] || fail "${dirs[$i]} is not a directory"
	dirs[$i]=$(cd "${dirs[$i]}" && pwd)
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
zig_version=$(zig version)

# Sets `bin` to a zigvet for $1 (a binary, a git ref, or empty for the
# working tree) and `name` to how the summary calls it.
resolve() {
	local arg=$1 side=$2 sha src
	if [ -z "$arg" ]; then
		(cd "$root" && zig build -Doptimize=ReleaseSafe --prefix "$tmp/$side") >&2 ||
			fail "the working tree does not build"
		bin=$tmp/$side/bin/zigvet
		name="working tree"
	elif [ -f "$arg" ] && [ -x "$arg" ]; then
		bin=$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")
		name=$arg
	else
		sha=$(git -C "$root" rev-parse --verify --quiet "$arg^{commit}") ||
			fail "$arg is neither a git ref nor a zigvet binary"
		bin=$root/.zig-cache/corpus-diff/$sha-$zig_version/bin/zigvet
		if [ ! -x "$bin" ]; then
			src=$tmp/$side-src
			mkdir -p "$src"
			git -C "$root" archive "$sha" | tar -x -C "$src"
			(cd "$src" && zig build -Doptimize=ReleaseSafe --prefix "${bin%/bin/zigvet}") >&2 ||
				fail "$arg does not build with Zig $zig_version"
		fi
		name="$arg ($(git -C "$root" rev-parse --short "$sha"))"
	fi
	"$bin" --version >/dev/null || fail "$bin does not run"
}

if [ -z "$base_arg" ]; then
	base_arg=$(git -C "$root" describe --tags --abbrev=0) || fail "no tag to compare with; give --base"
fi
resolve "$base_arg" base
base_bin=$bin base_name=$name
resolve "$head_arg" head
head_bin=$bin head_name=$name

# Runs zigvet $1 over directory $2 three times and leaves its reports in $3,
# one line each with the hint joined on, sorted. The fastest run's time goes
# in $3.time, so a cold file cache does not count against whichever build
# reads a directory first; the exit status in $3.status; stderr in $3.err.
vet() {
	local bin=$1 dir=$2 out=$3 status best= i TIMEFORMAT=%R
	for i in 1 2 3; do
		status=0
		{ time (cd "$dir" && "$bin" . >"$out.raw" 2>"$out.err"); } 2>"$out.t" || status=$?
		best=$(awk -v a="$best" -v b="$(cat "$out.t")" 'BEGIN { print (a == "" || b + 0 < a + 0) ? b : a }')
	done
	echo "$best" >"$out.time"
	echo "$status" >"$out.status"
	awk '
		/^    hint: / { prev = prev "  (" substr($0, 5) ")"; next }
		{ if (have) print prev; prev = $0; have = 1 }
		END { if (have) print prev }
	' "$out.raw" | LC_ALL=C sort >"$out"
}

# `plural 3 report reports` prints "3 reports".
plural() { if [ "$1" = 1 ]; then echo "1 $2"; else echo "$1 $3"; fi; }

echo "base: $base_name"
echo "head: $head_name"
echo
differ=0
failed=0
n=0
for dir in "${dirs[@]}"; do
	n=$((n + 1))
	vet "$base_bin" "$dir" "$tmp/$n.base"
	vet "$head_bin" "$dir" "$tmp/$n.head"
	gone=$(LC_ALL=C comm -23 "$tmp/$n.base" "$tmp/$n.head")
	added=$(LC_ALL=C comm -13 "$tmp/$n.base" "$tmp/$n.head")
	base_count=$(wc -l <"$tmp/$n.base" | tr -d ' ')
	head_count=$(wc -l <"$tmp/$n.head" | tr -d ' ')

	case $dir in "$HOME"/*) shown="~/${dir#"$HOME"/}" ;; *) shown=$dir ;; esac
	if [ "$base_count" = "$head_count" ]; then
		counts=$(plural "$base_count" report reports)
	else
		counts="$base_count -> $(plural "$head_count" report reports)"
	fi
	verdict=same
	[ -z "$gone$added" ] || verdict=DIFFERS
	for side in base head; do
		[ "$(cat "$tmp/$n.$side.status")" -le 1 ] || verdict=FAILED
	done
	case $verdict in DIFFERS) differ=1 ;; FAILED) failed=1 ;; esac
	printf '%s: %s, %ss -> %ss, %s\n' "$shown" "$counts" "$(cat "$tmp/$n.base.time")" "$(cat "$tmp/$n.head.time")" "$verdict"
	for side in base head; do
		status=$(cat "$tmp/$n.$side.status")
		if [ "$status" -gt 1 ]; then
			echo "  $side exited $status:"
			tail -n 5 "$tmp/$n.$side.err" | sed 's/^/    /'
		fi
	done
	[ -z "$gone" ] || printf '%s\n' "$gone" | sed 's/^/  - /'
	[ -z "$added" ] || printf '%s\n' "$added" | sed 's/^/  + /'
done

total() { cat "$tmp"/*."$1".time | awk '{ s += $1 } END { printf "%.2f", s }'; }
verdict="no report differs"
[ "$differ" = 0 ] || verdict="reports differ"
[ "$failed" = 0 ] || verdict="a run failed"
printf '\ntotal: %ss -> %ss over %s, %s\n' "$(total base)" "$(total head)" "$(plural "$n" directory directories)" "$verdict"
exit $((differ | failed))

#!/usr/bin/env bash
# Disables each of a rule's guards in turn and runs the tests, so a rule
# change shows that every guard it has is one a test holds to: with the
# guard gone, a test must fail. One that no test notices is a guard the
# tests say nothing about, and the rule may drop it unseen.
#
#   scripts/guardcheck.sh <guards>...
#
# A guards file lists the guards of one rule, each a label and the edit
# that disables it, as exact lines of the source, `-` for what is there
# and `+` for what replaces it:
#
#   # leak's guards.
#   file src/leak.zig
#
#   == an arena on the release side
#   -        if (intoArena(tree, call)) return false;
#   +        if (false and intoArena(tree, call)) return false;
#
# A `file` line names the file the edits after it change, from the
# repository root; `#` starts a comment line, and blank lines are skipped.
# What the `-` lines say must be in the file exactly once. Each edit is
# undone before the next, and on any exit, so the files are left as they
# were found.
#
# For each guard it prints the tests that fail without it and, for a rule
# test's expected findings, the lines that change: `+` for a finding the
# guard held back, `-` for one that went missing.
#
# Exit status: 0 when every guard makes a test fail, 1 when one makes
# none fail, does not apply, or leaves the code not building, 2 on a
# usage error.
set -euo pipefail

usage() {
	echo "usage: scripts/guardcheck.sh <guards>..." >&2
	exit 2
}

fail() {
	echo "guardcheck: $*" >&2
	exit 2
}

[ $# -gt 0 ] || usage
case $1 in -h | --help) usage ;; -*) echo "guardcheck: unknown option $1" >&2 && usage ;; esac
for list in "$@"; do
	[ -f "$list" ] || fail "$list is not a file"
done
root=$(git rev-parse --show-toplevel)

tmp=$(mktemp -d)
saved=
# Puts back the file an edit is applied to, if one is.
restore() {
	if [ -n "$saved" ]; then
		cp "$tmp/saved" "$root/$saved"
		saved=
	fi
}
trap 'restore; rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM

# Prints each test that fails in the test output $1, and under it, when
# its expected findings are not what it found, `+` lines for what it found
# that was not expected and `-` lines for the other way round.
failures() {
	awk '
		function flush(   i, seen) {
			if (!have) return
			split("", seen)
			for (i = 1; i <= ne; i++) seen[e[i]]++
			for (i = 1; i <= nf; i++) if (seen[f[i]]-- <= 0) print "    + " f[i]
			split("", seen)
			for (i = 1; i <= nf; i++) seen[f[i]]++
			for (i = 1; i <= ne; i++) if (seen[e[i]]-- <= 0) print "    - " e[i]
			have = 0
		}
		/^error: .* failed/ {
			flush()
			name = $0
			sub(/^error: \047/, "", name)
			sub(/\047 failed.*/, "", name)
			print "  " name
		}
		/====== expected this output: =+$/ { mode = "e"; ne = 0; nf = 0; next }
		/======== instead found this: =+$/ { mode = "f"; next }
		mode != "" {
			line = $0
			sub(/^       /, "", line)
			done = sub(/␃$/, "", line)
			if (!(done && line == "")) {
				if (mode == "e") e[++ne] = line
				else f[++nf] = line
			}
			if (done) {
				if (mode == "f") have = 1
				mode = ""
				if (have) flush()
			}
		}
		END { flush() }
	' "$1"
}

# Applies the guard edit in $tmp/old and $tmp/new to $file, runs the
# tests, puts the file back, and reports. Counts into covered and
# uncovered.
check() {
	local label=$1 text old new rest status=0 nl=$'\n'
	[ -n "$file" ] || fail "$list: '$label' comes before any \`file\` line"
	[ -f "$root/$file" ] || fail "$list: $file is not a file"
	# Read whole, the last newline kept (`$(...)` drops it), each after a
	# newline so that the lines match whole, from the start of one.
	old=$(
		cat "$tmp/old"
		printf x
	)
	old=$nl${old%x}
	new=$(
		cat "$tmp/new"
		printf x
	)
	new=$nl${new%x}
	text=$(
		cat "$root/$file"
		printf x
	)
	text=$nl${text%x}
	rest=${text#*"$old"}
	if [ "$old" = "$nl" ] || [ "$rest" = "$text" ]; then
		echo "$label: does not apply, its \`-\` lines are not in $file"
		uncovered=$((uncovered + 1))
		return
	fi
	case $rest in *"$old"*)
		echo "$label: does not apply, its \`-\` lines are in $file more than once"
		uncovered=$((uncovered + 1))
		return
		;;
	esac
	cp "$root/$file" "$tmp/saved"
	saved=$file
	text=${text%%"$old"*}$new$rest
	printf '%s' "${text#"$nl"}" >"$root/$file"
	(cd "$root" && zig build test) >"$tmp/out" 2>&1 || status=$?
	restore
	if [ "$status" = 0 ]; then
		echo "$label: no test fails"
		uncovered=$((uncovered + 1))
		return
	fi
	local failed
	failed=$(grep -c "^error: '.*' failed" "$tmp/out" || true)
	if [ "$failed" = 0 ]; then
		echo "$label: does not build, or fails some other way:"
		grep -m 3 'error' "$tmp/out" | sed 's/^/    /' || true
		uncovered=$((uncovered + 1))
		return
	fi
	if [ "$failed" = 1 ]; then echo "$label: 1 test fails"; else echo "$label: $failed tests fail"; fi
	failures "$tmp/out"
	covered=$((covered + 1))
}

covered=0
uncovered=0
for list in "$@"; do
	echo "$list"
	file=
	label=
	: >"$tmp/old"
	: >"$tmp/new"
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in
		"#"* | "") continue ;;
		"file "*)
			[ -z "$label" ] || check "$label"
			label=
			file=${line#file }
			;;
		"== "*)
			[ -z "$label" ] || check "$label"
			label=${line#== }
			: >"$tmp/old"
			: >"$tmp/new"
			;;
		-*) printf '%s\n' "${line#-}" >>"$tmp/old" ;;
		+*) printf '%s\n' "${line#+}" >>"$tmp/new" ;;
		*) fail "$list: a line that is not a comment, \`file\`, \`==\`, \`-\` or \`+\`: $line" ;;
		esac
	done <"$list"
	[ -z "$label" ] || check "$label"
	echo
done

total=$((covered + uncovered))
if [ "$uncovered" = 0 ]; then
	echo "$total guards, every one held to by a test"
else
	echo "$total guards, $uncovered not held to by any test"
fi
[ "$uncovered" = 0 ]

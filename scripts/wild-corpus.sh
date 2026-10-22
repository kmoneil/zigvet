#!/usr/bin/env bash
# Shallow clones of well-known public Zig projects, for measuring a rule
# on code nobody here wrote, and prints their directories, one per line,
# for scripts/corpus-diff.sh:
#
#   scripts/corpus-diff.sh --base main $(scripts/wild-corpus.sh)
#
# A report there counts only if the project's own authors would call it a
# bug, so read each one. The clones live in .wild/ at the repository
# root, which git ignores and zigvet's walk skips, as it skips every
# hidden directory, so a run over the repository itself never reaches
# them. Nothing in them is built or run; zigvet only parses them.
#
# A clone already there is used as it is, so runs compare the same code.
# --update fetches each project's latest commit first.
#
# Exit status: 0 when every project is there, 1 when one could not be
# cloned or updated (named on stderr; a clone that could not be made is
# left out of the list), 2 on a usage error.
set -euo pipefail

projects=(
	ghostty-org/ghostty
	tigerbeetle/tigerbeetle
	zigtools/zls
	roc-lang/roc
	lightpanda-io/browser
	neurocyte/flow
	hexops/mach
	rockorager/libvaxis
	mitchellh/libxev
	kristoff-it/superhtml
	kristoff-it/zine
	karlseguin/http.zig
	zigzap/zap
	Vexu/arocc
)

update=false
case $# in
0) ;;
1) [ "$1" = --update ] && update=true || {
	echo "usage: scripts/wild-corpus.sh [--update]" >&2
	exit 2
} ;;
*)
	echo "usage: scripts/wild-corpus.sh [--update]" >&2
	exit 2
	;;
esac

wild=$(git rev-parse --show-toplevel)/.wild
mkdir -p "$wild"
status=0
for project in "${projects[@]}"; do
	dir=$wild/${project//\//_}
	if [ ! -d "$dir/.git" ]; then
		if ! git clone -q --depth 1 "https://github.com/$project" "$dir" >&2; then
			echo "wild-corpus: could not clone $project" >&2
			status=1
			continue
		fi
	elif $update; then
		if ! { git -C "$dir" fetch -q --depth 1 origin HEAD && git -C "$dir" reset -q --hard FETCH_HEAD; } >&2; then
			echo "wild-corpus: could not update $project; using it as it was" >&2
			status=1
		fi
	fi
	echo "$dir"
done
exit $status

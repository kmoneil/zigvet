# Contributing

zigvet builds with Zig 0.17.0 and has no dependencies. `zig build` leaves
the binary in `zig-out/bin/`, `zig build test` runs every test, and
`zig build lint` runs zigvet over its own `src/`.

## What a rule has to be

The admission test: the code compiles clean in every build mode and is still
wrong. If the compiler, `zig fmt` or an existing linter already catches it, it
is not a zigvet rule. Code that is right but larger or slower than it could
be is out of scope as well: what it costs depends on the build mode and on
how many times it is instantiated, which the syntax does not show and a
profiler of the built program does
([#30](https://github.com/kmoneil/zigvet/issues/30)). Each rule is one
lowercase word for what it catches.

A rule lives in three places: its code and unit tests in `src/<rule>.zig`,
its cases in `test/cases/<rule>/`, and its page in `docs/rules/<rule>.md`,
which the table in the README links to.

## Tests

`zig build test` runs the unit tests and the case corpus in `test/cases/`.
The cases use the form of the Zig compiler's own `test/cases/`: source,
then `// error` and the expected `// :line:col: error: ...` lines, or
`// compile` for code that must not be reported. The run also compiles
every case with the Zig compiler and fails if it rejects one, so each case
is checked to be code Zig accepts. If a later Zig release starts catching a
shape, its case fails and the rule should drop it.

### When findings move

When a change moves where findings point, or rewords them,
`zig build test -Dupdate` rewrites each expectation that no longer
matches, in the rule tests and in the cases, to what the rules report, and
prints each one it rewrote with its file and line. Read the diff before it
is committed: an expectation is only as right as its reading. A test that
expected nothing and now finds something, or the other way round, still
fails, as that is a rule gaining or losing a finding, not one moving.

### Measuring a rule on real code

`scripts/corpus-diff.sh` runs two builds of zigvet over the same
directories, by default the latest tag and the working tree, and prints
only the reports that differ, with each build's time. Run it before a rule
change lands: over code that holds no new bug, the change should add
nothing but the reports it was written for. List the directories in
`corpus.txt` at the repository root (gitignored, one per line) or give them
as arguments; `--base` and `--head` each take a git ref or a zigvet binary.

`scripts/wild-corpus.sh` keeps shallow clones of fourteen well-known public
Zig projects (Ghostty, TigerBeetle, ZLS, Roc and others) in `.wild/`, which
git ignores and the walk skips, and prints their directories, so a rule is
also measured on code nobody here wrote:
`scripts/corpus-diff.sh --base main $(scripts/wild-corpus.sh)`. A clone
already there is used as it is; `--update` fetches each project's latest
commit.

### Checking a rule's guards

`scripts/guardcheck.sh test/guards/leak.txt` takes away each of a rule's
guards in turn, what keeps a report out, and runs `zig build test`, so a
rule change shows that a test holds to every guard it has: with the guard
gone, a test must fail. It prints the tests that fail and the findings
that change, and exits 1 for a guard no test notices, an edit that does
not apply, or one that does not build. A guards file in `test/guards/`
lists a rule's guards, each a label and the edit that removes it as exact
lines, `-` for what is there and `+` for what replaces it, so when a guard
is rewritten its edit fails to apply rather than passing unchecked.

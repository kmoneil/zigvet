# Contributing

zigvet builds with Zig 0.17.0 and has no dependencies. `zig build` leaves
the binary in `zig-out/bin/`, `zig build test` runs every test,
`zig build lint` runs zigvet over its own `src/`, and
`zig build complexity` runs [gnarl](https://github.com/kmoneil/gnarl)'s
complexity check. `zig build test` runs the last two as well, so it needs
`gnarl` on the PATH: a binary from its releases, or
`brew install kmoneil/tap/gnarl`.

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
with `title` and `parent: Rules` front matter at its top. A new rule also
gets a row in the tables in the README and in `docs/rules/index.md`, and a
link in the list on the site's home page, `docs/index.md`.

## The site

GitHub Pages builds <https://kmoneil.github.io/zigvet/> from `docs/` on
`main`, with the just-the-docs theme (`docs/_config.yml`); there is no
workflow for it in this repository. The rule pages are the same files the
repository shows, so a rule's page is written once. The site's own pages,
`docs/index.md` and `docs/usage.md`, repeat parts of the README, and a
change to one is a change to the other.

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

### Complexity

`gnarl --check .`, run by `zig build test`, fails a function over a
critical complexity limit unless `complexity.baseline` holds it at that
number or above: the debt already there is held, not let grow.
`complexity.zon` says which files are held to the tightest limits (what
every file checked goes through) and which to the loosest (the build and
the test machinery). Run `gnarl --diff HEAD` before a commit to see what it
changed. A new function over a critical limit is split rather than added to
the baseline (`gnarl --explain path:line` lists ranges worth lifting out);
a commit that improves, renames or moves a baselined function runs
`gnarl --update-baseline .` too. CI installs the gnarl release
`scripts/install-gnarl.sh` pins.

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

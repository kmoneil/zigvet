# zigvet

[![ci](https://github.com/kmoneil/zigvet/actions/workflows/ci.yml/badge.svg)](https://github.com/kmoneil/zigvet/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/kmoneil/zigvet)](https://github.com/kmoneil/zigvet/releases/latest)
[![zig](https://img.shields.io/badge/zig-0.17.0-f7a41d)](https://ziglang.org/download/)
[![docs](https://img.shields.io/badge/docs-kmoneil.github.io%2Fzigvet-blue)](https://kmoneil.github.io/zigvet/)
[![license](https://img.shields.io/github/license/kmoneil/zigvet)](LICENSE)

**Things Zig compiles that are wrong.**

zigvet reads your `.zig` files with `std.zig.Ast`, the compiler's own
parser, and reports code the compiler accepts in every build mode that is
almost certainly a bug: a slice of a dead stack frame handed back to the
caller, a double free on an error path, a lock still held after a failure,
a buffered writer never flushed, tests that never run. `go vet` is the
closest analog: not style, which `zig fmt` and the existing linters cover,
but silent wrongness.

- **Twenty rules.** Sixteen have found real bugs: in Zig's own standard
  library and compiler, in well-known open-source Zig projects, and in
  application code.
- **Syntax only.** No build, no configuration. It reads Zig's standard
  library and compiler, 650,000 lines, in under a second.
- **Quiet when there is nothing to say,** as `zig fmt --check` is, and
  fails the build when there is.

## A quick look

```zig
pub fn scopesFor(scope: Scope, asked: []const []const u8) []const []const u8 {
    return if (scope == .monitoring) &.{Scope.monitoring.url()} else asked;
}
```

```console
$ zigvet src
src/auth.zig:14:38: escape: anonymous array made here leaves scopesFor through return
    hint: make it comptime-known (`comptime` on the runtime elements) or a container-level const
```

`Scope.monitoring.url()` is a call, so the array is built at run time, in
`scopesFor`'s own frame, and the slice it returns points into memory the
next call writes over. Zig 0.17.0 compiles this without a diagnostic in
every mode. This exact code shipped, passed its tests for two days, and
failed only when an unrelated `std.debug.print` happened to overwrite the
stack slot. The fix is one word: `&.{comptime Scope.monitoring.url()}`.

## Install

| Where | How |
|---|---|
| macOS, Linux | `brew install kmoneil/tap/zigvet` |
| Windows | `scoop bucket add kmoneil https://github.com/kmoneil/scoop-bucket` then `scoop install kmoneil/zigvet` |
| Anywhere | a binary from the [latest release](https://github.com/kmoneil/zigvet/releases/latest) |
| From source | `zig build -Doptimize=ReleaseSafe` with Zig 0.17.0, which leaves it in `zig-out/bin/` |

Homebrew and Scoop move to each release by themselves, after checking every
file's build provenance. Each release carries a binary for Linux, macOS and
Windows on x86-64 and arm64, named
`zigvet-<linux|darwin|windows>-<amd64|arm64>` (`.exe` on Windows), with
`SHA256SUMS` and a build-provenance attestation for every file.

<details>
<summary>Verify a download, or rebuild a release yourself</summary>

On an Apple-silicon Mac, for example:

```sh
curl -fLO https://github.com/kmoneil/zigvet/releases/latest/download/zigvet-darwin-arm64
curl -fLO https://github.com/kmoneil/zigvet/releases/latest/download/SHA256SUMS
shasum -a 256 --check --ignore-missing SHA256SUMS
gh attestation verify zigvet-darwin-arm64 --repo kmoneil/zigvet
chmod +x zigvet-darwin-arm64 && mv zigvet-darwin-arm64 /usr/local/bin/zigvet
```

A binary downloaded with a browser on macOS is quarantined; clear it with
`xattr -d com.apple.quarantine zigvet`. `curl` does not set the flag.

From v0.2.1 on, releases are also reproducible: a tag built with Zig 0.17.0
from ziglang.org gives the same bytes wherever it is built, so a release
can be checked without trusting the workflow that made it. CI builds every
change on Linux and on macOS and compares them. To check one yourself:

```sh
git clone --depth 1 --branch <tag> https://github.com/kmoneil/zigvet && cd zigvet
zig build release && cd zig-out/release
curl -fLO https://github.com/kmoneil/zigvet/releases/download/<tag>/SHA256SUMS
shasum -a 256 --check SHA256SUMS
```

It takes Zig as ziglang.org ships it: a Zig built against another LLVM,
such as Homebrew's, writes its linker's name into the Linux binaries, so
those two differ while the macOS and Windows ones still match. The release
binaries carry no debug info, since it holds the paths of the machine that
built them, so a panic prints its message but not a symbolized stack trace.

</details>

## Usage

```sh
zigvet .                          # every .zig file under here
zigvet src build.zig              # some directories and files
zigvet --summary src              # and say what was checked
zigvet --format github src        # annotate a pull request in CI
```

```
zigvet [--exclude <path>]... [--format <text|github|json>] [--summary] <path>...
zigvet --version
```

A file is checked whatever its extension. A directory is walked for `.zig`
files, skipping hidden files and directories, `zig-out` and `zig-pkg`.
Paths print cleaned (`./src/a.zig` as `src/a.zig`), and a file reached
more than one way is checked once. A file that does not parse is reported
with the error `zig ast-check` gives for it.

| Option | Does |
|---|---|
| `--exclude <path>` | Skips a file or directory; may be given more than once. It is matched against paths as zigvet prints them, so name it relative to the current directory: `zigvet . --exclude _tmp` leaves out a scratch directory, or a second worktree checked out inside it. |
| `--format text` | The default: `path:line:col: rule: message`, then the hint on its own line. |
| `--format github` | GitHub Actions workflow commands, so each report lands on the pull request's diff. |
| `--format json` | One JSON array, an object per report, for other tools. |
| `--summary` | Ends the run with one line on stderr, in every format, saying how many files were checked and what each rule reported. |

`--summary` is off by default, so a clean run prints nothing and a lint
step stays quiet. Turn it on where a zero has to be trusted, such as CI
after an upgrade: it tells a run over 354 files from a run over 3.

```
zigvet: checked 354 files, no findings
zigvet: checked 41 files, 3 findings (escape 1, refill 2)
```

**Exit status:** 0 if nothing was reported, 1 if a finding or parse error
was, 2 on a usage error or a path that could not be read or holds no
`.zig` file to check. So a lint step aimed at a directory whose Zig has
moved fails rather than passing with nothing checked.

<details>
<summary>What the github and json formats look like</summary>

```
::error file=src/kms/fake_kms.zig,line=1297,col=54,title=zigvet escape::result of a call made here leaves rawOf through return. hint: return the value itself, have the caller pass in the memory, or allocate it
```

```json
[
{"path":"src/a.zig","line":2,"column":12,"rule":"escape","message":"anonymous array made here leaves f through return","hint":"make it comptime-known (`comptime` on the runtime elements) or a container-level const"}
]
```

`rule` is the rule's name, `allow` for an allow comment that suppresses
nothing, or `error` for a parse error, which has no hint (`null`). The
reports, their order and the exit status are the same in every format.
Findings go to stdout, in path order and then source order; a message
about the run itself, such as a path that could not be read, goes to
stderr as text.

</details>

## The rules

Each rule is one word for what it catches. Its page shows the bug, why it
goes wrong, exactly what the rule reports and leaves alone, and what it
found in real code.

### Dangling pointers

| Rule | Catches | What goes wrong |
|---|---|---|
| [escape](docs/rules/escape.md) | A pointer or slice into stack memory that leaves the function that made it | The caller reads memory the next call writes over |
| [freed](docs/rules/freed.md) | A function that returns what its own `defer` frees | The caller reads freed memory |
| [grow](docs/rules/grow.md) | A pointer into a list's items, kept across a call that can move them | The pointer reads freed memory once the list grows |
| [copy](docs/rules/copy.md) | A `std.Io.Writer` or `Reader` interface copied out of the struct it belongs to | The first flush reads whatever sits next to the copy as its parent, and crashes |

### Error paths: double frees, leaks, held locks

These all go wrong only when something fails part way, the path tests
seldom take.

| Rule | Catches | What goes wrong |
|---|---|---|
| [refill](docs/rules/refill.md) | A place freed, then given new memory by something that can fail first | The place still holds the freed memory, and `deinit` frees it again |
| [owner](docs/rules/owner.md) | One allocation freed by two errdefers: the caller's, and the one in the function it hands it to | Freed twice |
| [kept](docs/rules/kept.md) | An `errdefer` that frees what the function has already stored where its caller keeps it | The caller's `deinit` frees it again |
| [torn](docs/rules/torn.md) | An optional or union built in place by an initializer that can fail | It is left set over what was never made, and `deinit` frees that |
| [twice](docs/rules/twice.md) | An errdefer's free also written out by hand on a path that then fails | Freed twice |
| [sweep](docs/rules/sweep.md) | A loop that frees what a list holds, can fail part way, and empties the list only after it | The list still holds what was freed |
| [unlock](docs/rules/unlock.md) | A lock taken, then something that can fail before the unlock, with no `defer` | The lock stays held, and the next `lock` waits for good |
| [leak](docs/rules/leak.md) | A local released by hand later in its block, with something that can fail between | The release never runs |

### Errors swallowed

| Rule | Catches | What goes wrong |
|---|---|---|
| [cancel](docs/rules/cancel.md) | In a task's loop, an `Io` call whose error is dropped with `catch {}` or `catch continue` | `error.Canceled` comes once, so the loop runs on and the cancel waits for good |
| [fit](docs/rules/fit.md) | A number printed into a buffer too small for it, under `catch unreachable` | A panic in Debug and ReleaseSafe, undefined behavior in ReleaseFast |

### Silently wrong results

| Rule | Catches | What goes wrong |
|---|---|---|
| [alias](docs/rules/alias.md) | An anonymous initializer assigned to a place one of its own later elements reads | `ext = .{ ext[1], ext[0] }` gives `{ ext[1], ext[1] }` |
| [flush](docs/rules/flush.md) | A buffered file or stream writer, written to and never flushed | What is left in the buffer never arrives |
| [wipe](docs/rules/wipe.md) | A local wiped with `@memset` as the last thing done with it | Release builds drop the store, and the secret stays in memory |

### Builds and tests

| Rule | Catches | What goes wrong |
|---|---|---|
| [cached](docs/rules/cached.md) | A build script that lists a directory to decide what to build, and never tells Zig's configure cache | A file added there is not built until something else changes the build |
| [unrun](docs/rules/unrun.md) | A file whose tests never run, because nothing the test build analyses refers to it | `zig build test` passes without them |
| [hoard](docs/rules/hoard.md) | A fuzz target that keeps memory past one input, from an allocator the test runner does not check | It grows with every input until the run runs out of memory, and the leak check passes |

## Allowing a report

For a report zigvet gets wrong, say so in the comment lines directly above
the reported line, naming the rule and giving a reason:

```zig
// zigvet: allow escape only called at comptime, from the build script
return &.{Scope.monitoring.url()};
```

The reason is required; an allow comment without one suppresses nothing.

Every allow comment has to suppress something. One that does not is
reported itself, with why: nothing on the line below breaks its rule any
more, it names no rule zigvet has, it gives no reason, or it sits at the end
of the line it means instead of above it. It counts toward the exit status
like a finding, so an allow cannot outlive the code it excused and then
excuse whatever is written there next.

## Use it in a build

Add zigvet to `build.zig.zon`, pinned to a release tag, with `zig fetch
--save git+https://github.com/kmoneil/zigvet#v0.19.0`, then give `build.zig`
a lint step, the way `zig fmt --check` is used:

```zig
const zigvet = b.dependency("zigvet", .{
    .target = b.graph.host,
    .optimize = .ReleaseSafe,
});
const vet = b.addRunArtifact(zigvet.artifact("zigvet"));
vet.setCwd(b.path("."));
vet.addArgs(&.{"src"});
b.step("lint", "Report code that compiles but is wrong").dependOn(&vet.step);
```

`zig build lint` then fails when zigvet reports anything. zigvet's own
`zig build lint` is the same step run over its `src/`.

## Clobber the stack in tests

A function that returns a slice of its own frame passes a test that reads
the slice straight away, because nothing has written over that memory yet.
That is how the bug at the top passed its test for two days.
`clobberStack()` writes over the stack the returned frame used, so the same
test fails at once:

```zig
const zigvet = @import("zigvet");

test "scopesFor asks for read-only Monitoring" {
    const got = Auth.scopesFor(.monitoring, &asked);
    zigvet.clobberStack();
    try std.testing.expectEqualStrings(monitoring_read_url, got[0]);
}
```

Give the test module the import in `build.zig`, from the same dependency as
the lint step:

```zig
tests.root_module.addImport("zigvet", zigvet.module("zigvet"));
```

Since v0.2.0. It finds the bug only in a function a test calls, and is
dependable only in a Debug build (the default for `zig build test`): an
optimized build may turn a read of a dead frame into anything. The escape
rule finds the shapes it knows in any function, so the two are worth
having together.

## What a rule has to be

The code compiles clean in every build mode and is still wrong. If the
compiler, `zig fmt` or an existing linter already catches it, it is not a
zigvet rule, and nor is code that is right but larger or slower than it
could be. [CONTRIBUTING.md](CONTRIBUTING.md) has the rest: the tests, the
case corpus, and how a rule is measured on real code before it lands.

## License

Apache-2.0; see [LICENSE](LICENSE).

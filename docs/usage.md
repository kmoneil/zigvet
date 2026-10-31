---
title: Usage
nav_order: 3
---

# Usage

```sh
zigvet .                          # every .zig file under here
zigvet src build.zig              # some directories and files
zigvet --summary src              # and say what was checked
zigvet --format github src        # annotate a pull request in CI
```

```
zigvet [--exclude <path>]... [--format <text|github|json>] [--summary] <path>...
zigvet skill [--install <dir>]
zigvet --version | --help
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

## The github and json formats

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

Add zigvet to `build.zig.zon`, pinned to a release tag (the latest is on the
[releases page](https://github.com/kmoneil/zigvet/releases/latest)), with `zig fetch
--save git+https://github.com/kmoneil/zigvet#<tag>`, then give `build.zig`
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
That is how [the bug on the front page](index.md#a-quick-look) passed its
test for two days.
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

## For AI agents

`zigvet skill` prints what an AI agent needs to work with zigvet: the
loop, each rule with the smallest code that trips it and the fix, how to
add it to a build, and what to do with a finding that looks wrong. It is
built into the binary, and zigvet's tests run every example in it.

```sh
zigvet skill                       # print it
zigvet skill --install ~/.skills   # write it to ~/.skills/zigvet/SKILL.md
```

To check a directory named `skill`, name it `./skill`.

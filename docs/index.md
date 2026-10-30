---
title: Home
nav_order: 1
permalink: /
---

# zigvet

**Things Zig compiles that are wrong.**
{: .fs-6 .fw-300 }

zigvet reads your `.zig` files with `std.zig.Ast`, the compiler's own
parser, and reports code the compiler accepts in every build mode that is
almost certainly a bug: a slice of a dead stack frame handed back to the
caller, a double free on an error path, a lock still held after a failure,
a buffered writer never flushed, tests that never run. `go vet` is the
closest analog: not style, which `zig fmt` and the existing linters cover,
but silent wrongness.

[Install](#install){: .btn .btn-primary .mr-2 }
[The rules](rules/index.md){: .btn .mr-2 }
[GitHub](https://github.com/kmoneil/zigvet){: .btn }

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
[More on escape](rules/escape.md).

## Install

| Where | How |
|---|---|
| macOS, Linux | `brew install kmoneil/tap/zigvet` |
| Windows | `scoop bucket add kmoneil https://github.com/kmoneil/scoop-bucket` then `scoop install kmoneil/zigvet` |
| Anywhere | a binary from the [latest release](https://github.com/kmoneil/zigvet/releases/latest), for Linux, macOS and Windows on x86-64 and arm64 |
| From source | `zig build -Doptimize=ReleaseSafe` with Zig 0.17.0, which leaves it in `zig-out/bin/` |

Every release file comes with `SHA256SUMS` and a build-provenance
attestation, and releases build reproducibly; the
[README](https://github.com/kmoneil/zigvet#install) shows how to check
both.

## Run it

```sh
zigvet .                          # every .zig file under here
zigvet --summary src              # and say what was checked
zigvet --format github src        # annotate a pull request in CI
```

It exits 0 when it reports nothing, 1 when it reports something, and 2 on
a usage error. [Usage](usage.md) has the options, the output formats,
allowing a report, and a lint step for `build.zig`.

## The rules

Each rule is one word for what it catches. [The rules](rules/index.md)
page shows them all with what goes wrong.

- **Dangling pointers:** [escape](rules/escape.md), [freed](rules/freed.md),
  [grow](rules/grow.md), [copy](rules/copy.md)
- **Error paths, double frees, leaks, held locks:**
  [refill](rules/refill.md), [owner](rules/owner.md), [kept](rules/kept.md),
  [torn](rules/torn.md), [twice](rules/twice.md), [sweep](rules/sweep.md),
  [unlock](rules/unlock.md), [leak](rules/leak.md)
- **Errors swallowed:** [cancel](rules/cancel.md), [fit](rules/fit.md)
- **Silently wrong results:** [alias](rules/alias.md),
  [flush](rules/flush.md), [wipe](rules/wipe.md)
- **Builds and tests:** [cached](rules/cached.md), [unrun](rules/unrun.md),
  [hoard](rules/hoard.md)

# zigvet

Things Zig compiles that are wrong.

`zigvet [paths...]` parses every `.zig` file with `std.zig.Ast`, the
compiler's own parser, and reports code the compiler accepts in every build
mode that is almost certainly a bug. `go vet` is the closest analog: not
style, which the existing linters cover, but silent wrongness.

Status: the command runs, walks paths and reports parse errors. No rule is
implemented yet; escape, below, is the first.

## Rule one: escape

A pointer or slice into stack memory that leaves the function that made it.

```zig
fn scopesFor(scope: Scope, asked: []const []const u8) []const []const u8 {
    return if (scope == .monitoring) &.{Scope.monitoring.url()} else asked;
}
```

`Scope.monitoring.url()` is a call, so the anonymous array is built at run
time, in this function's own frame. `&` takes its address, the slice is
returned, and once the function returns that memory belongs to whatever is
called next. Zig 0.17.0 compiles this without a diagnostic in every mode: the
compiler's one error in this family ("returning address of expired local
variable") anchors on `var` locals and cannot see this shape. This exact code
shipped, passed its tests for two days, and failed only when an unrelated
`std.debug.print` happened to overwrite the stack slot.

The fix is one of:

```zig
return &.{comptime Scope.monitoring.url()};
```

or a container-level constant, which is evaluated at compile time and static:

```zig
const monitoring_read = [_][]const u8{Scope.monitoring.url()};
```

## Usage

```
zigvet <path>...
```

A file is checked whatever its extension. A directory is walked for `.zig`
files, skipping hidden directories, `zig-out` and `zig-pkg`. Paths print
cleaned (`./src/a.zig` as `src/a.zig`), and a file reached more than one
way is checked once. A file that does not parse is reported with the error
`zig ast-check` gives for it.

Exit status: 0 if nothing was reported, 1 if a finding or parse error was,
2 on a usage error or a path that could not be read.

## Output

```
path:line:col: escape: <what> made here leaves <function> through <return | field | global | out param>
    hint: <one line on how to fix it>
```

Findings go to stdout, in path order and then source order.

## Allowing a report

For a report zigvet gets wrong, say so in the comment lines directly above
the reported line, naming the rule and giving a reason:

```zig
// zigvet: allow escape only called at comptime, from the build script
return &.{Scope.monitoring.url()};
```

The reason is required; an allow comment without one suppresses nothing.

## Use it in a build

Add zigvet to `build.zig.zon` with `zig fetch --save
git+https://github.com/kmoneil/zigvet`, then give `build.zig` a lint step,
the way `zig fmt --check` is used:

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

## What a rule has to be

The admission test: the code compiles clean in every build mode and is still
wrong. If the compiler, `zig fmt` or an existing linter already catches it, it
is not a zigvet rule. Each rule is one lowercase word for what it catches;
`escape` is the first.

# zigvet

Things Zig compiles that are wrong.

`zigvet [paths...]` parses every `.zig` file with `std.zig.Ast`, the
compiler's own parser, and reports code the compiler accepts in every build
mode that is almost certainly a bug. `go vet` is the closest analog: not
style, which the existing linters cover, but silent wrongness.

Status: design stage. Nothing is implemented yet.

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

## Output

```
path:line:col: escape: <what> made here leaves <function> through <return | field | global | out param>
```

followed by a one-line fix hint. Exit 1 when anything is reported. Suppress a
report it gets wrong with `// zigvet: allow escape <reason>` on the line
before.

Intended use: a `zig build lint` step, the way `zig fmt --check` is used.

## What a rule has to be

The admission test: the code compiles clean in every build mode and is still
wrong. If the compiler, `zig fmt` or an existing linter already catches it, it
is not a zigvet rule. Each rule is one lowercase word for what it catches;
`escape` is the first.

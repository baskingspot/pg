# pg: PostgreSQL wire protocol in Zig: frontend and backend message codecs, with no IO and no allocator. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests")]
[group("test")]
test:
    zig build test --summary all

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src bench build.zig
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md .github
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src bench build.zig
    nix fmt
    oxfmt README.md AGENTS.md .github
    just --fmt

[doc("Run the fuzzer with an iteration budget, for example `just fuzz 50M`. Built-in test runner, ReleaseSafe for throughput")]
[group("test")]
fuzz LIMIT="10M":
    zig build fuzz -Doptimize=ReleaseSafe --fuzz={{ LIMIT }}

[doc("Run benchmarks (ReleaseFast by default); args pass to the binary: just bench -- --benchtime=250ms --filter=Frame")]
[group("bench")]
bench *ARGS:
    zig build bench -- {{ ARGS }}

[doc("Run every benchmark once: proves the suite builds and runs, without measuring")]
[group("bench")]
bench-smoke:
    zig build bench -- --benchtime=8x --count=1 --no-env

[doc("Everything CI runs")]
[group("ci")]
ci: test lint bench-smoke

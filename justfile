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
    oxfmt --check README.md AGENTS.md docs/content docs/config.toml wrangler.jsonc .github
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src bench build.zig
    nix fmt
    oxfmt README.md AGENTS.md docs/content docs/config.toml wrangler.jsonc .github
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

[doc("Build the site into zig-out/site/: the guide (Zola, from docs/) and the API reference (docgen JSON, rendered by the theme) under api/. The router in baskingspot/site serves /pg/... from it")]
[group("docs")]
doc: api
    baskingspot-docs build pg

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve pg

[doc("Deploy the rendered docs to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN, plus CLOUDFLARE_ACCOUNT_ID if the token sees more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    docgen --root src/root.zig --title pg --repo-url https://github.com/baskingspot/pg --rev main --format json --out docs/data

[doc("Everything CI runs: the tests, the lint, a benchmark smoke run, and the site build")]
[group("ci")]
ci: test lint bench-smoke doc

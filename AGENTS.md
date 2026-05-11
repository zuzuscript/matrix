# ZuzuScript Implementation Matrix

This repository runs shared ZuzuScript tests across the main runtimes and
publishes the implementation matrix as JSON and Markdown.

Use Oxford English in documentation: mostly standard British English, with
`-ize` word endings.

## Relationship To Other Projects

The matrix consumes runtime submodules under `implementations/`:

- `implementations/zuzu-perl`
- `implementations/zuzu-rust`
- `implementations/zuzu-js`

Those implementations bring their own `stdlib`, `languagetests`,
`userguide`, and `examples` submodules. Do not edit implementation
submodules from this repository unless the task explicitly asks for that
runtime work. Runtime fixes belong in the runtime repository.

The website consumes this repository as a submodule for published status
data.

## Project Shape

- `run-tests.pl` discovers ztests, runs them across Perl, Rust, JS/Node,
  JS/Electron, and optionally JS/Browser, and writes matrix JSON.
- `make-markdown.pl` converts matrix JSON into the Markdown table in
  `README.md`.
- `implementation-matrix.json` and `browser-implementation-matrix.json` are
  generated status artefacts.

## Running The Matrix

Initialize submodules before a full run:

```bash
git submodule update --init --recursive
```

Common commands:

```bash
./run-tests.pl --no-browser
./run-tests.pl --only 'languagetests/basic'
./run-tests.pl --jobs 4
./make-markdown.pl --output README.md
```

`run-tests.pl` can build the default Rust binary when needed and can rebuild
the JS browser bundle for browser runs. Browser and Electron checks require
the JS implementation dependencies to be installed.

## Test Semantics

Ztests emit TAP. The matrix should treat valid TAP with a plan, no `not ok`
lines, and exit status zero as passing. Capability skips should remain soft
failures, not hard regressions.

Pull requests that cause regressions in the matrix are unlikely to be
accepted. When a regression appears, fix the relevant runtime or shared
module rather than weakening matrix interpretation.

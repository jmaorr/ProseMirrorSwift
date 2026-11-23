# Contributing

Thanks for helping. Bug reports with a small document and the steps that break it are the
most useful thing you can send; a failing scenario (below) is even better.

## Running the tests

```bash
swift test                          # macOS: parity, TextKitTests, ExampleSetupTests
PM_FUZZ_SCALE=10 swift test         # more random cases
xcodebuild -scheme ProseMirrorSwift-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:IOSTextKitTests
```

The live collaboration tests are skipped unless a relay is running:

```bash
cd devserver && npm install && npm start
PM_DEVSERVER=ws://localhost:1234 swift test --filter YSync
```

## The parity oracle

Most tests compare Swift with the real JavaScript ProseMirror. `oracle/` pins the JS packages
(see `oracle/package.json`) and bundles them with a JSON harness into `oracle/dist/oracle.js`,
which is committed so the tests run from a clone. After editing `oracle/src/`, rebuild it:

```bash
cd oracle && npm ci && npm run build
```

When porting a change from upstream ProseMirror, bump the version in `oracle/package.json`,
rebuild the oracle, and let the tests show what moved.

## Scenarios

`fixtures/scenarios/*.json` hold hand-written editing scenarios: a document, a selection,
then keys, typing, commands and undo. Each runs through both JavaScript and Swift and must
match after every step. The format is in [fixtures/scenarios/README.md](fixtures/scenarios/README.md).

## The Yrs binary

`YSync` links yrs through its C API (yffi). The static library is prebuilt for macOS, iOS
and the iOS Simulator. To rebuild it (needs `rustup` with the Apple targets listed in the
script):

```bash
yrs-ffi/build.sh
```

The package normally downloads the released XCFramework (`Package.swift` names its URL and
checksum). To build against your rebuild, point the `Yrs` binary target at
`yrs-ffi/Yrs.xcframework` with `path:` instead.

## Style

- Follow the upstream JavaScript closely in the ported modules: same names, same structure,
  same edge cases. Deviations need a comment saying why.
- Public symbols get doc comments.
- Keep app-specific behaviour out of the library: anything one app wants belongs in its
  `DocStyle`, plugins or schema.

# Releasing

## A version

1. Update `CHANGELOG.md`.
2. Zip the Yrs binary and compute its checksum:
   ```bash
   cd yrs-ffi && ditto -c -k --keepParent Yrs.xcframework Yrs.xcframework.zip
   swift package compute-checksum Yrs.xcframework.zip
   ```
3. In `Package.swift`, point the `Yrs` binary target at the release asset:
   ```swift
   .binaryTarget(name: "Yrs",
                 url: "https://github.com/<owner>/ProseMirrorSwift/releases/download/<version>/Yrs.xcframework.zip",
                 checksum: "<checksum>"),
   ```
4. Commit, tag `<version>`, push the tag, and create the GitHub release with
   `Yrs.xcframework.zip` attached.
5. Check a clean install: a new package that depends on the tag, `swift build`.

The binary only changes when the yffi version does; otherwise reuse the previous release's
URL and checksum.

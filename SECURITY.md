# Security

## Reporting a vulnerability

Please don't open a public issue. Report it privately through GitHub's
[security advisories](../../security/advisories/new) for this repository. Include what an
attacker controls (a pasted document, a collaborator's edits, a sync server's messages) and
the smallest input that shows the problem.

You'll get an answer within a week. Fixes are released as a patch version, and the
advisory is published once a fixed version is out.

## What counts

The library treats these as untrusted: documents and slices from the pasteboard or a drop,
Yjs updates from collaborators or a sync server, and JSON passed to `fromJSON`. A crash,
hang, unbounded memory use, or reading files the user didn't choose, caused by such input,
is a vulnerability. So is anything that sends data somewhere the app didn't ask for.

The `devserver/` relay is a local development tool with no authentication; don't expose it
to a network you don't trust.

## The prebuilt yrs library

`Yrs.xcframework` is built from yffi 0.28.0 by `yrs-ffi/build.sh` and attached to each
release; `Package.swift` pins its SHA-256 checksum, so SwiftPM refuses a file that doesn't
match. Release notes list the checksum, and you can rebuild it from source to compare.

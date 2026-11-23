// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ProseMirrorSwift",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PMModel", targets: ["PMModel"]),
        .library(name: "PMTransform", targets: ["PMTransform"]),
        .library(name: "PMState", targets: ["PMState"]),
        .library(name: "PMCommands", targets: ["PMCommands"]),
        .library(name: "PMKeymap", targets: ["PMKeymap"]),
        .library(name: "PMInputRules", targets: ["PMInputRules"]),
        .library(name: "PMHistory", targets: ["PMHistory"]),
        .library(name: "PMMarkdown", targets: ["PMMarkdown"]),
        .library(name: "PMTextKit", targets: ["PMTextKit"]),
        .library(name: "PMTables", targets: ["PMTables"]),
        .library(name: "PMTableView", targets: ["PMTableView"]),
        .library(name: "YSync", targets: ["YSync"]),
        .library(name: "PMExampleSetup", targets: ["PMExampleSetup"]),
        .executable(name: "ExampleEditor", targets: ["ExampleEditor"]),
    ],
    targets: [
        .target(name: "PMModel"),
        .target(name: "PMTransform", dependencies: ["PMModel"]),
        .target(name: "PMState", dependencies: ["PMModel", "PMTransform"]),
        .target(name: "PMCommands", dependencies: ["PMModel", "PMTransform", "PMState"]),
        .target(name: "PMKeymap", dependencies: ["PMState"]),
        .target(name: "PMInputRules", dependencies: ["PMModel", "PMTransform", "PMState"]),
        .target(name: "PMHistory", dependencies: ["PMModel", "PMTransform", "PMState"]),
        // Port of prosemirror-tables: table map, cell selection, fixes, commands, paste.
        .target(name: "PMTables", dependencies: ["PMModel", "PMTransform", "PMState", "PMKeymap"]),
        // prosemirror-markdown's serializer (MarkdownSerializer, MarkdownSerializerState).
        .target(name: "PMMarkdown", dependencies: ["PMModel"]),
        // TextKit 2 view over an EditorState: NSTextView on macOS, UITextView on iOS, one shared renderer.
        .target(name: "PMTextKit", dependencies: ["PMModel", "PMTransform", "PMState", "PMCommands"]),
        // Native table view: grid, cell editor, handles (macOS and iOS).
        .target(name: "PMTableView", dependencies: ["PMModel", "PMTransform", "PMState", "PMTextKit", "PMTables"]),
        // yffi's C API (yrs, the Rust Yjs port): the header here, the static library prebuilt
        // by yrs-ffi/build.sh into an XCFramework, attached to the GitHub release (RELEASING.md).
        // To use a local rebuild instead: .binaryTarget(name: "Yrs", path: "yrs-ffi/Yrs.xcframework").
        .binaryTarget(name: "Yrs",
                      url: "https://github.com/jmaorr/ProseMirrorSwift/releases/download/0.1.0/Yrs.xcframework.zip",
                      checksum: "6f7214c4e576251a73e1fa8863bf56e293520a820fbef94eb0e96a52e347d953"),
        .target(name: "CYrs", dependencies: ["Yrs"]),
        // Yjs binding equivalent to y-prosemirror's sync plugin.
        .target(name: "YSync", dependencies: ["CYrs", "PMModel", "PMTransform", "PMState"]),
        // A starting point, like prosemirror-example-setup: BasicSchema, exampleSetup(schema:)
        // (input rules, keymaps, history, tables) and BasicStyle for PMTextKit.
        .target(name: "PMExampleSetup", dependencies: ["PMModel", "PMTransform", "PMState", "PMCommands", "PMKeymap",
                                                      "PMInputRules", "PMHistory", "PMTextKit", "PMTables", "PMTableView"]),
        // A small macOS editor built on PMExampleSetup, with optional YSync collaboration
        // (`swift run ExampleEditor`). The iOS example is in Examples/iOS.
        .executableTarget(name: "ExampleEditor", dependencies: ["PMExampleSetup", "PMModel", "PMState", "PMCommands",
                                                                "PMHistory", "PMTextKit", "YSync"]),
        // Test-only: loads the bundled JS ProseMirror oracle into JavaScriptCore.
        .target(name: "PMOracle", dependencies: ["PMModel"]),
        .testTarget(name: "ParityTests", dependencies: ["PMModel", "PMTransform", "PMState", "PMCommands", "PMKeymap",
                                                        "PMInputRules", "PMHistory", "PMOracle", "YSync", "PMMarkdown",
                                                        "PMTables", "PMTableView"]),
        .testTarget(name: "ExampleSetupTests", dependencies: ["PMExampleSetup", "PMModel", "PMState", "PMCommands", "PMKeymap",
                                                              "PMHistory", "PMTextKit", "PMTables", "YSync"]),
        // PMTextKit, PMTableView and PMTables in a real text view (macOS), on PMExampleSetup's
        // BasicSchema and BasicStyle, plus test-only styles for chrome, controls and menus.
        .testTarget(name: "TextKitTests", dependencies: ["PMExampleSetup", "PMModel", "PMTransform", "PMState", "PMCommands",
                                                         "PMKeymap", "PMInputRules", "PMHistory", "PMTextKit", "PMTables",
                                                         "PMTableView", "PMMarkdown", "YSync"]),
        // The same on iOS (PMTextKit's UIKit half) on the iOS Simulator; empty on macOS.
        // xcodebuild test -scheme ProseMirrorSwift-Package -destination 'platform=iOS Simulator,...' -only-testing:IOSTextKitTests
        .testTarget(name: "IOSTextKitTests", dependencies: ["PMExampleSetup", "PMModel", "PMTransform", "PMState", "PMCommands",
                                                            "PMKeymap", "PMInputRules", "PMHistory", "PMTextKit", "PMTables",
                                                            "PMTableView", "YSync"]),
    ],
    swiftLanguageModes: [.v5]
)

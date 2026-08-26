// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NetPulse",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NetPulse",
            path: "Sources/NetPulse",
            // Not SPM resources: Info.plist is embedded via the linker flags
            // below and both files are copied into the .app by
            // scripts/build-app.sh. Listing them here just silences SPM's
            // "unhandled files" warning.
            exclude: [
                "Resources/Info.plist",
                "Resources/NetPulse.entitlements",
            ],
            linkerSettings: [
                // Embeds Info.plist into the __TEXT,__info_plist section so the SPM
                // executable behaves like a real .app bundle at runtime (SwiftUI's
                // App lifecycle, LSUIElement, LSApplicationCategoryType, etc. all
                // read this section). Standard trick for menu-bar SwiftUI apps built
                // without an .xcodeproj. Path is relative to the package root, which
                // is the working directory `swift build` runs from.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/NetPulse/Resources/Info.plist",
                ])
            ]
        )
    ]
)

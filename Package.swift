// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MorningBrief",
    platforms: [.macOS(.v13)],
    targets: [
        // Resources live in ./Resources and are copied into the .app by scripts/build-app.sh.
        // During `swift run`, Res.swift falls back to the repo's Resources folder.
        .executableTarget(
            name: "MorningBrief",
            path: "Sources/MorningBrief"
        )
    ]
)

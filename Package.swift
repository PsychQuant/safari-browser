// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "safari-browser",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "safari-browser", targets: ["SafariBrowser"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "SafariBrowser",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            // A CLI has no bundle, so TCC has nothing to attribute a grant to
            // and no usage string to show — unless the Info.plist is linked
            // into the binary itself. Excluded from resources because it is
            // consumed by the linker, not copied. (#98)
            exclude: ["Info.plist", "Entitlements.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SafariBrowser/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "SafariBrowserTests",
            dependencies: ["SafariBrowser"]
        ),
    ]
)

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
            ]
        ),
        .testTarget(
            name: "SafariBrowserTests",
            dependencies: ["SafariBrowser"]
        ),
    ]
)

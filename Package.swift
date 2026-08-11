// swift-tools-version: 6.3

import PackageDescription

let occtXCFrameworkRoot = "Vendor/OpenCascadeStatic/OpenCascadeStairs.xcframework"
let occtMacOSRoot = "\(occtXCFrameworkRoot)/macos-arm64"
let occtMacOSLibrary = "\(occtMacOSRoot)/libOpenCascadeStairs-macos-arm64.a"

let package = Package(
    name: "HorizontalNative",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "HorizontalProjectIO", targets: ["HorizontalProjectIO"]),
        // Library products for the Xcode app/extension targets, which can
        // only depend on package products (not bare targets).
        .library(name: "HorizontalStepImporter", targets: ["HorizontalStepImporter"]),
        .library(name: "HorizontalPlaneClipper", targets: ["HorizontalPlaneClipper"]),
        .executable(name: "HorizontalProjectRoundTrip", targets: ["HorizontalProjectRoundTrip"])
        // No `HorizontalNative` executable product: the app is built by
        // Horizontal.xcodeproj, which compiles Sources/HorizontalNative directly
        // and links only the library products above. Exposing it here let
        // `swift run` produce a second, differently-assembled app binary. The
        // TARGET stays — it is where the app's sources live and what
        // HorizontalNativeTests imports.
    ],
    targets: [
        .target(
            name: "HorizontalProjectIO",
            path: "Sources/HorizontalProjectIO",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "HorizontalProjectRoundTrip",
            dependencies: ["HorizontalProjectIO"],
            path: "Sources/HorizontalProjectRoundTrip",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // OpenCascade as a binary target (instead of unsafeFlags linker
        // arguments) so Xcode app targets can depend on package products.
        // Packages whose targets use unsafeFlags cannot be consumed by Xcode.
        .binaryTarget(
            name: "OpenCascadeStairs",
            path: occtXCFrameworkRoot
        ),
        .target(
            name: "HorizontalStepImporter",
            dependencies: ["OpenCascadeStairs"],
            path: "Sources/HorizontalStepImporter",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../\(occtMacOSRoot)/Headers")
            ],
            linkerSettings: [
                .linkedLibrary("objc", .when(platforms: [.macOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "HorizontalPlaneClipper",
            path: "Sources/HorizontalPlaneClipper",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "HorizontalNative",
            dependencies: [
                "HorizontalProjectIO",
                "HorizontalStepImporter",
                "HorizontalPlaneClipper"
            ],
            path: "Sources/HorizontalNative",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "HorizontalProjectIOTests",
            dependencies: ["HorizontalProjectIO"],
            path: "Tests/HorizontalProjectIOTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "HorizontalPlaneClipperTests",
            dependencies: ["HorizontalPlaneClipper"],
            path: "Tests/HorizontalPlaneClipperTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "HorizontalNativeTests",
            dependencies: ["HorizontalNative"],
            path: "Tests/HorizontalNativeTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)

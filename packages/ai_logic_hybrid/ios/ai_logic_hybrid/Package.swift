// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Must equal the firebase-ios-sdk version that firebase_core pins in its own
// SPM manifest (firebase_core 5.1.0: exactly 13.1.1), so SPM resolves one
// graph. Bump both together.
let firebaseSdkVersion: Version = "13.1.1"

let package = Package(
    name: "ai_logic_hybrid",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "ai-logic-hybrid", targets: ["ai_logic_hybrid"])
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: firebaseSdkVersion),
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "ai_logic_hybrid",
            dependencies: [
                .product(name: "FirebaseAILogic", package: "firebase-ios-sdk"),
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            resources: [
                // The plugin uses no required-reason APIs; enable this if it ever does.
                // .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)

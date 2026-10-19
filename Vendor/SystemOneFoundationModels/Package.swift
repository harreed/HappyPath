// swift-tools-version: 6.1

import PackageDescription

// Sources from peterfriese/system-one-foundation-models at
// c3068589139643cab045c984dd485168103cfbb7. This local package contains
// only the backends used by the two provider trials.
let package = Package(
    name: "SystemOneFoundationModels",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SystemOneCore", targets: ["SystemOneCore"]),
        .library(name: "LayaFoundationModels", targets: ["LayaFoundationModels"]),
        .library(name: "ClefFoundationModels", targets: ["ClefFoundationModels"]),
    ],
    targets: [
        .target(name: "SystemOneCore", swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]),
        .target(name: "LayaFoundationModels", dependencies: ["SystemOneCore"], swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]),
        .target(name: "ClefFoundationModels", dependencies: ["SystemOneCore"], swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]),
    ]
)

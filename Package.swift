// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AgenticUITestingSpike",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "HappyPath", targets: ["AppShell"]),
        .executable(name: "phase1-acceptance", targets: ["Phase1Acceptance"]),
        .library(name: "ProjectDomain", targets: ["ProjectDomain"]),
        .executable(name: "companion-experiment", targets: ["CompanionExperiment"]),
        .executable(name: "phase0-harness", targets: ["Phase0Harness"]),
        .executable(name: "goal-acceptance", targets: ["GoalAcceptance"]),
        .executable(name: "provider-trials", targets: ["ProviderTrials"]),
        .library(name: "RunnerCore", targets: ["RunnerCore"]),
        .library(name: "ArtifactStore", targets: ["ArtifactStore"]),
        .library(name: "ModelProviders", targets: ["ModelProviders"]),
        .library(name: "SimulatorControl", targets: ["SimulatorControl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/anthropics/ClaudeForFoundationModels.git", exact: "0.2.3"),
        .package(path: "Vendor/SystemOneFoundationModels"),
    ],
    targets: [
        .executableTarget(name: "AppShell", dependencies: ["ProjectDomain", "SimulatorControl", "RunnerCore", "ArtifactStore", "ModelProviders", "PerceptionCore"]),
        .executableTarget(name: "Phase1Acceptance", dependencies: ["ProjectDomain", "RunnerCore", "SimulatorControl", "ArtifactStore"]),
        .executableTarget(name: "GoalAcceptance", dependencies: ["ProjectDomain", "RunnerCore", "SimulatorControl", "ArtifactStore", "ModelProviders"]),
        .executableTarget(name: "ProviderTrials", dependencies: ["ProjectDomain", "RunnerCore", "ModelProviders"]),
        .executableTarget(name: "CompanionExperiment", dependencies: ["RunnerCore", "SimulatorControl"]),
        .target(name: "ProjectDomain"),
        .executableTarget(name: "OCRBenchmark", dependencies: ["PerceptionCore", "RunnerCore"]),
        .target(name: "PerceptionCore", dependencies: ["RunnerCore"]),
        .executableTarget(name: "ProviderAcceptance", dependencies: ["RunnerCore", "ProjectDomain", "SimulatorControl", "ModelProviders", "ArtifactStore"]),
        .executableTarget(name: "RecoveryAcceptance", dependencies: ["PerceptionCore", "RunnerCore", "ProjectDomain", "SimulatorControl", "ArtifactStore"]),
        .executableTarget(name: "PerceptionAcceptance", dependencies: ["PerceptionCore", "RunnerCore"]),
        .target(name: "RunnerCore", dependencies: ["ProjectDomain"]),
        .target(name: "ArtifactStore", dependencies: ["RunnerCore", "ProjectDomain"]),
        .target(name: "ModelProviders", dependencies: ["RunnerCore", "ProjectDomain", .product(name: "ClaudeForFoundationModels", package: "ClaudeForFoundationModels"), .product(name: "SystemOneCore", package: "SystemOneFoundationModels"), .product(name: "LayaFoundationModels", package: "SystemOneFoundationModels"), .product(name: "ClefFoundationModels", package: "SystemOneFoundationModels")]),
        .target(name: "SimulatorControl", dependencies: ["RunnerCore", "PerceptionCore"]),
        .executableTarget(
            name: "Phase0Harness",
            dependencies: ["RunnerCore", "ArtifactStore", "SimulatorControl"]
        ),
        .testTarget(
            name: "AgenticUITestingSpikeTests",
            dependencies: ["ProjectDomain", "RunnerCore", "ArtifactStore", "ModelProviders", "SimulatorControl", "PerceptionCore"],
            resources: [.process("Fixtures/LegacyProject.json")]
        ),
    ]
)

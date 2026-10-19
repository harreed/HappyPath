# HappyPath

HappyPath is a macOS app for creating and running UI tests against iOS apps in Simulator. Tests can follow a written goal or replay reviewed steps. The app keeps run results, screenshots, recordings, and explanations in a project that you can inspect and export.

## Requirements

- macOS 27 and Xcode 27, with an iOS Simulator runtime installed
- Swift 5.10 or newer through the selected Xcode installation
- Network access for Swift Package Manager to fetch the external package on the first build

The app runs on the Mac and controls an iOS Simulator. It does not install on an iPhone.

## Build and run

```sh
sh Scripts/build_mac_app.sh
open .build/HappyPath.app
```

The build script packages the generic XCTest companion and the DM Sans font into the app. It uses an ad-hoc signature by default. For stable Keychain access across rebuilds, put the SHA-1 fingerprint of an Apple Development signing identity in a local `.build-signing-identity` file at the repository root, or set `HAPPYPATH_SIGNING_IDENTITY` for one build. The file is ignored by Git.

Run the automated Swift tests with:

```sh
swift test
```

The controlled iOS fixture is documented in [Fixtures/OnboardingFixture/README.md](Fixtures/OnboardingFixture/README.md). Simulator CI setup is documented in [CI-SMOKE.md](CI-SMOKE.md).

## Using HappyPath

Create or open a `.uitestproject`, choose its Xcode scheme and an installed iOS Simulator, then add a test. A goal test describes the result to reach and, optionally, visible evidence of success. A replay test uses explicit actions and assertions. Run results include a timeline and preserved evidence for review. [App/README.md](App/README.md) describes the current workflow and settings in more detail.

Projects and exported runs can contain screenshots, recordings, logs, accessibility text, and other content from the app under test. Review these files before sharing them. Credentials configured in HappyPath are stored in the local macOS Keychain and are not exported with a project. Remote image assessment requires separate credentials, explicit approval for that run, network access, and may incur provider charges.

## License

Copyright 2026 Haros Labs Ltd. HappyPath's original code and documentation are licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE). Personal and other noncommercial uses permitted by that license are allowed; commercial use is not licensed. This is source-available software, not an open-source license under the Open Source Definition.

Third-party components keep their own licenses. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the vendored Swift package, the external Swift dependency, and the bundled font.

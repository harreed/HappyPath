# Controlled onboarding fixture

This independent SwiftUI app contains a semantic name field and Continue button, an injected optional alert, a custom-drawn Finish setup control deliberately hidden from accessibility, and final semantic completion/name assertions.

The checked-in Xcode project requires no external packages. `generate_project.rb` regenerates it using the `xcodeproj` Ruby gem. The UI test compiles the shared RunnerCore Domain.swift source so alert/OCR actions exercise the same capture gate as the portable unit tests.

Run the complete lifecycle and scripted test with video:

```sh
swift run phase0-harness \
  --container-kind project \
  --container "$PWD/Fixtures/OnboardingFixture/OnboardingFixture.xcodeproj" \
  --scheme OnboardingFixture \
  --udid YOUR-SIMULATOR-UDID \
  --product-name OnboardingFixture.app \
  --bundle-id dev.agentic.OnboardingFixture \
  --artifacts "$PWD/fixture-runs" \
  --scripted-onboarding
```

The run folder retains video.mp4, lifecycle events.jsonl, onboarding.log, and onboarding.xcresult. Open the xcresult in Xcode to inspect retained screenshots and structured JSON event attachments for every step. OCR's attachment binds the exact image to its CaptureID and records source pixel size, Vision bounds, confidence, and converted screen point. The final completion and entered name are checked through XCTest, independent of OCR.

This is a deterministic integration experiment, not a reusable out-of-process accessibility bridge. Runtime success, a ten-run trial, and a playable video must be verified on the target Mac before marking Phase 0 complete.

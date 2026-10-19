#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build --product HappyPath
APP="${HAPPYPATH_APP_PATH:-${TEST_WORKBENCH_APP_PATH:-.build/HappyPath.app}}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Companion/Fixtures/OnboardingFixture" "$APP/Contents/Resources/Companion/Sources/RunnerCore"
cp .build/debug/HappyPath "$APP/Contents/MacOS/HappyPath"
cp -R Fixtures/OnboardingFixture/. "$APP/Contents/Resources/Companion/Fixtures/OnboardingFixture/"
cp Sources/RunnerCore/CandidateProviderEvidence.swift Sources/RunnerCore/Domain.swift Sources/RunnerCore/RunnerProtocols.swift Sources/RunnerCore/CompanionProtocol.swift Sources/RunnerCore/SecureInputCrypto.swift "$APP/Contents/Resources/Companion/Sources/RunnerCore/"
cp App/Info.plist "$APP/Contents/Info.plist"
rm -f "$APP/Contents/Resources/Sora-Bold.ttf" "$APP/Contents/Resources/Sora-OFL.txt"
cp App/DMSans-Variable.ttf App/DMSans-OFL.txt "$APP/Contents/Resources/"
SIGNING_IDENTITY="${HAPPYPATH_SIGNING_IDENTITY:-${TEST_WORKBENCH_SIGNING_IDENTITY:-}}"
if [ -z "$SIGNING_IDENTITY" ] && [ -f .build-signing-identity ]; then
    SIGNING_IDENTITY=$(cat .build-signing-identity)
fi
if [ -n "$SIGNING_IDENTITY" ]; then
    case "$SIGNING_IDENTITY" in
        *[!0-9A-Fa-f]*) echo "Signing identity must be a certificate SHA-1 fingerprint." >&2; exit 1 ;;
    esac
    if [ "${#SIGNING_IDENTITY}" -ne 40 ]; then
        echo "Signing identity must be a 40-character certificate SHA-1 fingerprint." >&2
        exit 1
    fi
    codesign --force --sign "$SIGNING_IDENTITY" --identifier dev.agentic.HappyPath "$APP"
else
    echo "No signing identity configured; using an ad-hoc signature (Keychain may ask again after rebuilds)." >&2
    codesign --force --sign - --identifier dev.agentic.HappyPath "$APP"
fi
printf '%s\n' "$PWD/$APP"

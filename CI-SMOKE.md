# Simulator CI smoke run

The workflow in `.github/workflows/ios-simulator-smoke.yml` runs the Swift unit suite and one deterministic onboarding test on a real iPhone Simulator. It uploads the run evidence directory, including `run.json`, `events.jsonl`, captures, logs and `junit.xml`. The app's ordinary completed run exports also include `junit.xml`.

The workflow runs on pushes by repository collaborators and can be started manually by someone with workflow access. It does not run for pull requests: a public contributor's proposed code must not execute on the self-hosted Mac. Review outside contributions before merging; the resulting push will run the smoke job. The job grants its GitHub token read-only repository access and does not leave checkout credentials in the worktree.

Register a dedicated self-hosted GitHub Actions runner with labels `macOS`, `ios-simulator` and `xcode-27`. It needs macOS 27, Xcode 27 selected with `xcode-select`, Xcode's first-launch components and an available iPhone Simulator runtime. Keep the runner dedicated to this repository: the smoke job builds and runs the checked-out fixture code. No model API key is required. The workflow is not configured for GitHub-hosted macOS because the package requires macOS 27 and Xcode 27.

To run the same smoke path locally, use `bash Scripts/ci_simulator_smoke.sh /path/to/new-output-directory`. The script generates a fresh fixture project under that output directory, selects an available iPhone Simulator, updates only the generated project, and runs the first fixture test. The archive remains available after a failed run. Nonpassing and incomplete tests are failures in JUnit; the XML contains test names and generic status only, never event diagnostics or captured content.

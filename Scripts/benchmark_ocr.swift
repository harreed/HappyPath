import Foundation
// Phase 0 CLI remains compatible; production recognition is shared with PerceptionCore.
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", "run", "OCRBenchmark"] + Array(CommandLine.arguments.dropFirst())
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)

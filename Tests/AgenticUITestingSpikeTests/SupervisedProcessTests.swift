import XCTest
import SimulatorControl
#if os(macOS)
import Darwin

final class SupervisedProcessTests: XCTestCase {
    func testRetainedOutputSurvivesTimeoutAndCancellation() async throws {
        for cancelled in [false, true] {
            let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: log) }
            let task = Task { try await executor.run(shell("printf partial-build; printf compiler-progress >&2; sleep 20"), timeout: cancelled ? 20 : 0.15, retainingOutputAt: log) }
            if cancelled { try await Task.sleep(for: .milliseconds(150)); task.cancel() }
            do { _ = try await task.value; XCTFail("Expected interrupted build") }
            catch is CancellationError { XCTAssertTrue(cancelled) }
            catch SupervisedProcessError.timedOut { XCTAssertFalse(cancelled) }
            let output = try String(contentsOf: log)
            XCTAssertTrue(output.contains("partial-build")); XCTAssertTrue(output.contains("compiler-progress"))
            XCTAssertTrue(output.contains(cancelled ? "CancellationError" : "timedOut"))
        }
    }
    private let executor = SupervisedProcessExecutor()
    private func shell(_ script: String, arguments: [String] = []) -> ProcessInvocation {
        ProcessInvocation(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "fixture"] + arguments)
    }
    func testLiveOutputRetainsSplitMarkerAcrossConcurrentReads() async throws {
        let handle = try executor.start(shell("printf 'Recording ' >&2; sleep 0.2; printf 'started\\n' >&2; sleep 1"))
        let deadline = Date().addingTimeInterval(3)
        var partialObserved = false
        var marker: ProcessOutputSnapshot?
        while Date() < deadline {
            let snapshot = try handle.currentOutput()
            if snapshot.standardError == "Recording " { partialObserved = true }
            if snapshot.standardError.contains("Recording started") { marker = snapshot; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(partialObserved)
        XCTAssertNotNil(marker)
        XCTAssertTrue(handle.isRunning, "Marker must be observable before termination")
        let copies = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try handle.currentOutput().standardError } }
            var values: [String] = []; for try await value in group { values.append(value) }; return values
        }
        XCTAssertTrue(copies.allSatisfy { $0.contains("Recording started") })
        let result = try await handle.wait(timeout: 3)
        XCTAssertEqual(result.standardError, "Recording started\n")
    }
    func testLiveOutputSnapshotIsBounded() async throws {
        let handle = try executor.start(shell("/bin/dd if=/dev/zero bs=1048576 count=17 2>/dev/null; printf '\\nREADY\\n'; sleep 1"))
        let deadline = Date().addingTimeInterval(4)
        var output = ""
        while Date() < deadline {
            output = try handle.currentOutput().standardOutput
            if output.hasSuffix("\nREADY\n") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(output.hasPrefix("[Output truncated to final 16 MiB]\n"))
        XCTAssertTrue(output.hasSuffix("\nREADY\n"))
        XCTAssertLessThanOrEqual(output.utf8.count, 16 * 1024 * 1024 + 100)
        _ = try await handle.wait(timeout: 3)
    }
    func testArgumentsRemainLiteralAndNonzeroRetainsStderr() async throws {
        let literal = "$(touch SHOULD_NOT_EXIST); $HOME `id`"
        let result = try await executor.run(ProcessInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                                                              arguments: ["%s", literal]), timeout: 3)
        XCTAssertEqual(result.standardOutput, literal)
        do {
            _ = try await executor.run(shell("printf failure >&2; exit 7"), timeout: 3)
            XCTFail("Nonzero exit accepted")
        } catch let error as ProcessExecutionError {
            XCTAssertEqual(error.result.exitCode, 7)
            XCTAssertEqual(error.result.standardError, "failure")
        }
    }
    func testEnvironmentAndWorkingDirectoryAreExplicit() async throws {
        let directory = FileManager.default.temporaryDirectory
        let invocation = ProcessInvocation(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '%s\\n' \"$TEST_VALUE\"; pwd"],
                                           environment: ["TEST_VALUE": "literal value"], currentDirectoryURL: directory)
        let result = try await executor.run(invocation, timeout: 3)
        XCTAssertTrue(result.standardOutput.hasPrefix("literal value\n"))
        XCTAssertEqual(URL(fileURLWithPath: result.standardOutput.split(separator: "\n").last.map(String.init)!).resolvingSymlinksInPath(),
                       directory.resolvingSymlinksInPath())
    }
    func testTimeoutKillsSignalIgnoringLeaderAndDescendant() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let handle = try executor.start(shell("trap '' TERM; (sleep 1; printf escaped > \"$1\") & wait", arguments: [marker.path]))
        let start = Date()
        do {
            _ = try await handle.wait(timeout: 0.1)
            XCTFail("Expected timeout")
        } catch SupervisedProcessError.timedOut { }
        XCTAssertFalse(handle.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Descendant escaped group cleanup")
    }
    func testCancellationKillsGroupBeforeReturning() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let handle = try executor.start(shell("(sleep 1; printf escaped > \"$1\") & wait", arguments: [marker.path]))
        let task = Task { try await handle.wait(timeout: 10) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertFalse(handle.isRunning)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testNaturalLeaderExitStillCleansOwnedBackgroundChild() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let result = try await executor.run(shell("(sleep 1; printf escaped > \"$1\") & exit 0", arguments: [marker.path]), timeout: 3)
        XCTAssertEqual(result.exitCode, 0)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testDroppingHandleStopsOwnedGroup() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        var handle: SupervisedProcessHandle? = try executor.start(shell("sleep 1; printf escaped > \"$1\"", arguments: [marker.path]))
        XCTAssertTrue(handle!.isRunning)
        handle = nil
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testStoppingOneGroupDoesNotStopAnother() async throws {
        let stopped = try executor.start(shell("sleep 10"))
        let survivor = try executor.start(shell("sleep 0.2; printf survived"))
        await stopped.stop(grace: 0.05)
        let result = try await survivor.wait(timeout: 3)
        XCTAssertEqual(result.standardOutput, "survived")
        XCTAssertFalse(stopped.isRunning)
    }
    func testRejectsInvalidTimeoutAndNulArgumentsBeforeSpawn() async throws {
        do { _ = try await executor.run(shell("exit 0"), timeout: .nan); XCTFail("Invalid timeout accepted") }
        catch SupervisedProcessError.invalidTimeout { }
        do {
            _ = try executor.start(ProcessInvocation(executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["a\0b"]))
            XCTFail("NUL accepted")
        } catch SupervisedProcessError.invalidInvocation { }
    }
}
#endif

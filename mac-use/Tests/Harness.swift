import AppKit
import Foundation

struct TestCase {
    let suite: String
    let name: String
    let skipReason: String?
    let body: () throws -> Void
}

enum Harness {
    static var cases: [TestCase] = []
    static var currentSuite = ""
    static var failures: [String] = []

    static func record(_ message: String, file: StaticString, line: UInt) {
        failures.append("\(file):\(line): \(message)")
    }

    static var exitCode: Int32 {
        let filter = ProcessInfo.processInfo.environment["TEST_FILTER"]?.lowercased()
        var passed = 0, failed = 0, skipped = 0
        var failedNames: [String] = []
        for c in cases {
            let full = "\(c.suite) / \(c.name)"
            if let filter, !full.lowercased().contains(filter) { continue }
            if let reason = c.skipReason {
                skipped += 1
                print("SKIP  \(full) (\(reason))")
                continue
            }
            Env.reset()
            failures = []
            do { try c.body() } catch { failures.append("unexpected error: \(error)") }
            if failures.isEmpty {
                passed += 1
                if ProcessInfo.processInfo.environment["TEST_VERBOSE"] != nil { print("PASS  \(full)") }
            } else {
                failed += 1
                failedNames.append(full)
                print("FAIL  \(full)")
                for f in failures { print("      \(f)") }
            }
        }
        print("")
        print("mac-use tests: \(passed + failed + skipped) total, \(passed) passed, \(failed) failed, \(skipped) skipped")
        if !failedNames.isEmpty { print("Failed: " + failedNames.joined(separator: "; ")) }
        return failed == 0 && passed > 0 ? 0 : 1
    }
}

func suite(_ name: String, _ body: () -> Void) {
    Harness.currentSuite = name
    body()
}

func test(_ name: String, _ body: @escaping () throws -> Void) {
    Harness.cases.append(TestCase(suite: Harness.currentSuite, name: name, skipReason: nil, body: body))
}

func skip(_ name: String, _ reason: String) {
    Harness.cases.append(TestCase(suite: Harness.currentSuite, name: name, skipReason: reason, body: {}))
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "expectation failed",
            file: StaticString = #fileID, line: UInt = #line) {
    do {
        if try !condition() { Harness.record(message(), file: file, line: line) }
    } catch {
        Harness.record("\(message()): threw \(error)", file: file, line: line)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                               file: StaticString = #fileID, line: UInt = #line) {
    if actual != expected {
        Harness.record("expected \(expected), got \(actual) \(message)", file: file, line: line)
    }
}

func expectContains(_ text: String, _ part: String, file: StaticString = #fileID, line: UInt = #line) {
    if !text.contains(part) { Harness.record("expected \"\(text)\" to contain \"\(part)\"", file: file, line: line) }
}

func expectNotContains(_ text: String, _ part: String, file: StaticString = #fileID, line: UInt = #line) {
    if text.contains(part) { Harness.record("expected \"\(text)\" not to contain \"\(part)\"", file: file, line: line) }
}

/// Runs `body` and expects it to throw an error whose description is exactly `message`.
func expectError(_ message: String, file: StaticString = #fileID, line: UInt = #line, _ body: () throws -> Any?) {
    do {
        _ = try body()
        Harness.record("expected error \"\(message)\" but nothing was thrown", file: file, line: line)
    } catch {
        if "\(error)" != message {
            Harness.record("expected error \"\(message)\", got \"\(error)\"", file: file, line: line)
        }
    }
}

/// Runs `body` and expects it to throw an error whose description contains `part`.
func expectErrorContaining(_ part: String, file: StaticString = #fileID, line: UInt = #line, _ body: () throws -> Any?) {
    do {
        _ = try body()
        Harness.record("expected an error containing \"\(part)\" but nothing was thrown", file: file, line: line)
    } catch {
        if !"\(error)".contains(part) {
            Harness.record("expected an error containing \"\(part)\", got \"\(error)\"", file: file, line: line)
        }
    }
}

/// Parses a JSON object the way the MCP layer and `mac-use call` do, so numbers and booleans bridge like real input.
func json(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

func jsonObject(_ text: String) -> Any? {
    try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

/// The isolated state directory every test runs against. Nothing here is the real home directory.
enum Env {
    static let root: URL = {
        guard let raw = ProcessInfo.processInfo.environment["MAC_USE_HOME"], !raw.isEmpty else {
            fputs("MAC_USE_HOME must point to a scratch directory. Run mac-use/test.sh.\n", stderr)
            exit(3)
        }
        let url = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        guard url.lastPathComponent.hasPrefix("mac-use-tests.") else {
            fputs("MAC_USE_HOME must be a scratch directory named mac-use-tests.*. Run mac-use/test.sh.\n", stderr)
            exit(3)
        }
        return url
    }()

    static func assertIsolated() {
        let home = Paths.home.resolvingSymlinksInPath().path
        let real = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard home == root.path, home != real, Paths.support.path.hasPrefix(Paths.home.path),
              Paths.logs.path.hasPrefix(Paths.home.path), Paths.caches.path.hasPrefix(Paths.home.path) else {
            fputs("Paths are not redirected to \(root.path) (got \(home)). Refusing to run.\n", stderr)
            exit(3)
        }
    }

    static func reset() {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            try? fm.removeItem(atPath: root.appendingPathComponent(item).path)
        }
        Safety.mouseLocation = { CGPoint(x: 500, y: 500) }
        Safety.frontName = { "TestApp" }
        Tools.isTrusted = { true }
        State.snapshot = nil
        State.geometry = nil
    }

    static func writeConfig(_ text: String) {
        Paths.ensure()
        try? text.write(to: Paths.config, atomically: true, encoding: .utf8)
    }

    static func logEntries() -> [[String: Any]] {
        guard let text = try? String(contentsOf: Paths.actionLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { json(String($0)) }
    }

    static func logText() -> String {
        (try? String(contentsOf: Paths.actionLog, encoding: .utf8)) ?? ""
    }
}

/// A snapshot element that carries no real accessibility reference, so tests never query another app.
func fakeElement(_ rawRole: String = "AXButton", label: String = "", value: String? = nil,
                 frame: CGRect? = CGRect(x: 100, y: 200, width: 40, height: 20),
                 enabled: Bool = true, focused: Bool = false, sub: String? = nil) -> UIElement {
    UIElement(ref: AXUIElementCreateSystemWide(), rawRole: rawRole,
              role: SnapshotBuilder.displayRole(rawRole, sub), label: label,
              value: SnapshotBuilder.displayValue(rawRole, sub, value),
              frame: frame, enabled: enabled, focused: focused, searchText: label.lowercased())
}

func installFakeSnapshot(count: Int) {
    State.snapshot = Snapshot(pid: -1, elements: (0..<count).map { fakeElement(label: "item \($0 + 1)") }, more: false)
}

func installFakeGeometry(width: CGFloat = 800, height: CGFloat = 600) {
    State.geometry = Geometry(rect: CGRect(x: 0, y: 0, width: width, height: height),
                              pixelSize: CGSize(width: width, height: height), pid: nil)
}

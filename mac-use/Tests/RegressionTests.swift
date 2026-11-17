import Foundation

func registerRegressionTests() {
    suite("Regressions") {
        test("int survives numbers outside the Int range") {
            let r = runSelfChild(["int-out-of-range"])
            expectEqual(r.status, 0, "child output: \(r.output)")
            expectContains(r.output, "huge=nil")
            expectContains(r.output, "nan=nil")
            expectContains(r.output, "inf=nil")
            expectContains(r.output, "fine=7")
        }

        test("a blank key sequence is rejected instead of pressing nothing") {
            expectError("'keys' is required.") { try Input.parseSequence("") }
            expectError("'keys' is required.") { try Input.parseSequence("   \t\n ") }
        }
    }
}

func runSelfChild(_ args: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--child"] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let status = process.terminationReason == .exit ? process.terminationStatus : -process.terminationStatus
    return (status, String(decoding: data, as: UTF8.self))
}

/// Runs in a separate process so a crash in the code under test fails one test instead of the whole run.
func runChild(_ args: [String]) -> Never {
    switch args.first {
    case "int-out-of-range":
        let a = json(#"{"huge":1e30,"fine":7}"#)
        let strings: [String: Any] = ["nan": "nan", "inf": "inf"]
        func show(_ v: Int?) -> String { v.map(String.init) ?? "nil" }
        print("huge=\(show(a.int("huge"))) nan=\(show(strings.int("nan"))) inf=\(show(strings.int("inf"))) fine=\(show(a.int("fine")))")
        exit(0)
    default:
        print("unknown child \(args)")
        exit(64)
    }
}

import Foundation

private struct Run {
    var status: Int32
    var out: String
    var err: String
}

private let binary: String? = ProcessInfo.processInfo.environment["MAC_USE_BIN"]

/// Runs the built binary with the scratch MAC_USE_HOME. Callers only pass commands that return before any real side effect.
private func runBinary(_ args: [String], stdin: String? = nil) -> Run {
    guard let binary else { return Run(status: -1, out: "", err: "MAC_USE_BIN is not set") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["MAC_USE_HOME"] = Env.root.path
    process.environment = env
    let out = Pipe(), err = Pipe(), input = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = input
    do { try process.run() } catch { return Run(status: -1, out: "", err: "\(error)") }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
    if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
    try? input.fileHandleForWriting.close()
    var outData = Data(), errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    outData = out.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()
    return Run(status: process.terminationReason == .exit ? process.terminationStatus : -process.terminationStatus,
                out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self))
}

private func lines(_ text: String) -> [[String: Any]] {
    text.split(separator: "\n").compactMap { json(String($0)) }
}

func registerCLITests() {
    suite("CLI: informational commands") {
        test("tools prints one tool name per line") {
            let r = runBinary(["tools"])
            expectEqual(r.status, 0)
            expectEqual(r.out, Tools.all.map(\.name).joined(separator: "\n") + "\n")
            expectEqual(r.err, "")
        }

        test("standard prints the instructions the MCP server sends") {
            let r = runBinary(["standard"])
            expectEqual(r.status, 0)
            expectEqual(r.out, Standard.instructions + "\n")
        }

        test("help, -h and --help print the usage and exit 0") {
            let first = runBinary(["--help"])
            expectEqual(first.status, 0)
            expectContains(first.out, "mac-use \(Standard.version) — local computer use for agents (MCP server + CLI)")
            for part in ["mac-use [mcp]", "mac-use call <tool> [json]", "mac-use tools", "mac-use status", "mac-use pause | resume", "mac-use standard"] {
                expectContains(first.out, part)
            }
            for flag in ["-h", "help"] {
                let r = runBinary([flag])
                expectEqual(r.status, 0, flag)
                expectEqual(r.out, first.out, flag)
            }
        }

        test("an unknown command prints the usage and exits 2") {
            let r = runBinary(["bogus"])
            expectEqual(r.status, 2)
            expectContains(r.out, "Usage:")
            expectEqual(r.out, runBinary(["--help"]).out)
        }

        test("commands are case-sensitive") {
            expectEqual(runBinary(["TOOLS"]).status, 2)
        }
    }

    suite("CLI: call") {
        test("call without a tool prints the usage and exits 2") {
            let r = runBinary(["call"])
            expectEqual(r.status, 2)
            expectContains(r.out, "Usage:")
        }

        test("an unknown tool prints the error and exits 1") {
            let r = runBinary(["call", "bogus"])
            expectEqual(r.status, 1)
            expectEqual(r.out, "Unknown tool 'bogus'.\n")
        }

        test("an unknown tool with a JSON object argument exits 1 too") {
            let r = runBinary(["call", "bogus", #"{"a":1}"#])
            expectEqual(r.status, 1)
            expectEqual(r.out, "Unknown tool 'bogus'.\n")
        }

        test("chained steps are numbered and the first failure stops the run") {
            let r = runBinary(["call", "bogus1", "bogus2"])
            expectEqual(r.status, 1)
            expectEqual(r.out, "== 1. bogus1\nUnknown tool 'bogus1'.\n")
        }

        test("a malformed JSON argument exits 2 with a message on stderr and runs nothing") {
            let r = runBinary(["call", "bogus", #"{"a":"#])
            expectEqual(r.status, 2)
            expectEqual(r.err, "Arguments for bogus must be a JSON object.\n")
            expectEqual(r.out, "")
        }

        test("an argument error in a later step is reported before any step runs") {
            let r = runBinary(["call", "bogus1", "bogus2", "{oops"])
            expectEqual(r.status, 2)
            expectEqual(r.err, "Arguments for bogus2 must be a JSON object.\n")
            expectEqual(r.out, "")
        }
    }

    suite("CLI: MCP over stdio") {
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#
        let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#

        test("a client session of initialize, initialized, ping and tools/list gets three replies and a clean exit at EOF") {
            let input = [initialize, initialized, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, list].joined(separator: "\n") + "\n"
            let r = runBinary(["mcp"], stdin: input)
            expectEqual(r.status, 0, "stderr: \(r.err)")
            let replies = lines(r.out)
            expectEqual(replies.count, 3)
            expectEqual(replies.map { $0["id"] as? Int }, [1, 3, 2])
            let info = (replies[0]["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
            expectEqual(info?["name"] as? String, "mac-use")
            expectEqual(((replies[0]["result"] as? [String: Any])?["instructions"]) as? String, Standard.instructions)
            let tools = (replies[2]["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            expectEqual(tools?.map { $0["name"] as? String ?? "" }, Tools.all.map(\.name))
        }

        test("with no arguments the binary runs the MCP server") {
            let r = runBinary([], stdin: #"{"jsonrpc":"2.0","id":7,"method":"ping"}"# + "\n")
            expectEqual(r.status, 0, "stderr: \(r.err)")
            expectEqual(lines(r.out).first?["id"] as? Int, 7)
        }

        test("serve is an alias for mcp") {
            let r = runBinary(["serve"], stdin: #"{"jsonrpc":"2.0","id":8,"method":"ping"}"# + "\n")
            expectEqual(r.status, 0)
            expectEqual(lines(r.out).first?["id"] as? Int, 8)
        }

        test("malformed JSON and unknown methods get error replies and the server keeps going") {
            let input = ["{broken", #"{"jsonrpc":"2.0","id":4,"method":"nope"}"#, #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#].joined(separator: "\n") + "\n"
            let r = runBinary(["mcp"], stdin: input)
            expectEqual(r.status, 0)
            let replies = lines(r.out)
            expectEqual(replies.count, 3)
            expectEqual((replies[0]["error"] as? [String: Any])?["code"] as? Int, -32700)
            expectEqual((replies[1]["error"] as? [String: Any])?["code"] as? Int, -32601)
            expectEqual(replies[2]["id"] as? Int, 5)
        }

        test("a last line without a trailing newline is still handled") {
            let r = runBinary(["mcp"], stdin: #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#)
            expectEqual(r.status, 0)
            expectEqual(lines(r.out).first?["id"] as? Int, 9)
        }

        test("an unknown tool over the wire is an error result") {
            let r = runBinary(["mcp"], stdin: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"bogus","arguments":{}}}"# + "\n")
            expectEqual(r.status, 0)
            let res = lines(r.out).first?["result"] as? [String: Any]
            expectEqual(res?["isError"] as? Bool, true)
        }

        test("closing stdin immediately exits 0 with no output") {
            let r = runBinary(["mcp"], stdin: "")
            expectEqual(r.status, 0)
            expectEqual(r.out, "")
        }
    }

    suite("CLI: state stays in the scratch home") {
        test("running the binary created nothing outside MAC_USE_HOME and never wrote a pause file") {
            _ = runBinary(["call", "bogus"])
            _ = runBinary(["mcp"], stdin: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n")
            expect(!Safety.isPaused)
            expect(!FileManager.default.fileExists(atPath: Paths.actionLog.path))
        }

        skip("status, pause, resume", "they read or write the real pause state, config and permissions")
        skip("call with a real tool", "every real tool touches the screen, apps or input")
    }
}

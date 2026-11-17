import Foundation

private final class Sink {
    var chunks: [Data] = []
    var text: String { chunks.map { String(decoding: $0, as: UTF8.self) }.joined() }
    var messages: [[String: Any]] { text.split(separator: "\n").compactMap { json(String($0)) } }
}

private func send(_ lines: String...) -> Sink {
    let sink = Sink()
    let server = MCPServer { sink.chunks.append($0) }
    for line in lines { server.handleLine(line) }
    return sink
}

private func reply(_ line: String) -> [String: Any]? {
    send(line).messages.first
}

private func result(_ line: String) -> [String: Any]? {
    reply(line)?["result"] as? [String: Any]
}

private func errorBody(_ line: String) -> (code: Int, message: String)? {
    guard let e = reply(line)?["error"] as? [String: Any], let code = e["code"] as? Int, let message = e["message"] as? String else { return nil }
    return (code, message)
}

func registerMCPTests() {
    suite("MCP: initialize") {
        test("the handshake reports the server, its tools capability and the standard as instructions") {
            let r = reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
            expectEqual(r?["jsonrpc"] as? String, "2.0")
            expectEqual(r?["id"] as? Int, 1)
            let res = r?["result"] as? [String: Any]
            expectEqual(res?["protocolVersion"] as? String, "2025-03-26")
            let info = res?["serverInfo"] as? [String: Any]
            expectEqual(info?["name"] as? String, "mac-use")
            expectEqual(info?["version"] as? String, Standard.version)
            let caps = res?["capabilities"] as? [String: Any]
            let tools = caps?["tools"] as? [String: Any]
            expectEqual(tools?["listChanged"] as? Bool, false)
            expectEqual(Set(caps?.keys.map { $0 } ?? []), ["tools"])
            expectEqual(res?["instructions"] as? String, Standard.instructions)
        }

        test("without a protocol version it answers 2025-06-18") {
            expectEqual(result(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)?["protocolVersion"] as? String, "2025-06-18")
            expectEqual(result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)?["protocolVersion"] as? String, "2025-06-18")
        }

        test("a non-string protocol version falls back to the default") {
            expectEqual(result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":5}}"#)?["protocolVersion"] as? String, "2025-06-18")
        }

        test("any requested protocol version is echoed back (pinned)") {
            expectEqual(result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)?["protocolVersion"] as? String, "1999-01-01")
        }
    }

    suite("MCP: ids and framing") {
        test("integer, zero, negative, string and unicode ids are echoed unchanged") {
            expectEqual(reply(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#)?["id"] as? Int, 0)
            expectEqual(reply(#"{"jsonrpc":"2.0","id":-7,"method":"ping"}"#)?["id"] as? Int, -7)
            expectEqual(reply(#"{"jsonrpc":"2.0","id":"abc-1","method":"ping"}"#)?["id"] as? String, "abc-1")
            expectEqual(reply(#"{"jsonrpc":"2.0","id":"日本語","method":"ping"}"#)?["id"] as? String, "日本語")
            expectEqual(reply(#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#)?["id"] as? Double, 1.5)
            expectEqual(reply(#"{"jsonrpc":"2.0","id":9007199254740993,"method":"ping"}"#)?["id"] as? Int64, 9007199254740993)
        }

        test("a null id is still answered, with a null id (pinned)") {
            let r = reply(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
            expect(r != nil)
            expect(r?["id"] is NSNull)
        }

        test("each reply is exactly one newline-terminated line") {
            let sink = send(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
            expect(sink.text.hasSuffix("\n"))
            expectEqual(sink.text.split(separator: "\n", omittingEmptySubsequences: false).count, 2)
            expectEqual(sink.chunks.count, 1)
        }

        test("slashes are not escaped in the output") {
            let sink = send(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
            expectContains(sink.text, "AppleScript/JXA")
            expectNotContains(sink.text, "\\/")
        }

        test("requests are answered in order, one reply each") {
            let sink = send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":"two","method":"ping"}"#, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
            let ids = sink.messages.map { $0["id"] }
            expectEqual(ids.count, 3)
            expectEqual(ids[0] as? Int, 1)
            expectEqual(ids[1] as? String, "two")
            expectEqual(ids[2] as? Int, 3)
        }

        test("blank lines and surrounding whitespace are ignored") {
            expectEqual(send("", "   ", "\t").text, "")
            expectEqual(reply("  \t" + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\r")?["id"] as? Int, 1)
        }

        test("the jsonrpc member is not required") {
            expectEqual(reply(#"{"id":4,"method":"ping"}"#)?["id"] as? Int, 4)
        }
    }

    suite("MCP: ping and listings") {
        test("ping returns an empty result") {
            let res = result(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
            expect(res != nil)
            expectEqual(res?.count, 0)
        }

        test("tools/list returns every tool definition") {
            let tools = result(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?["tools"] as? [[String: Any]]
            expectEqual(tools?.map { $0["name"] as? String ?? "" }, Tools.all.map(\.name))
            for t in tools ?? [] {
                expect(t["inputSchema"] is [String: Any], "\(t["name"] ?? "?") has no inputSchema")
                expect(t["annotations"] is [String: Any])
                expect(!(t["description"] as? String ?? "").isEmpty)
            }
        }

        test("tools/list advertises the read-only hint for observe and not for click") {
            let tools = result(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?["tools"] as? [[String: Any]] ?? []
            func hint(_ name: String) -> Bool? {
                (tools.first { $0["name"] as? String == name }?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool
            }
            expectEqual(hint("observe"), true)
            expectEqual(hint("click"), false)
        }

        test("tools/list ignores params") {
            expectEqual((result(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"x"}}"#)?["tools"] as? [Any])?.count, Tools.all.count)
        }

        test("resources/list and prompts/list are empty") {
            expectEqual((result(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)?["resources"] as? [Any])?.count, 0)
            expectEqual((result(#"{"jsonrpc":"2.0","id":1,"method":"prompts/list"}"#)?["prompts"] as? [Any])?.count, 0)
        }
    }

    suite("MCP: tools/call") {
        test("an unknown tool is an error result, not a protocol error") {
            let r = reply(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)
            expect(r?["error"] == nil)
            let res = r?["result"] as? [String: Any]
            expectEqual(res?["isError"] as? Bool, true)
            let content = res?["content"] as? [[String: Any]]
            expectEqual(content?.count, 1)
            expectEqual(content?[0]["type"] as? String, "text")
            expectEqual(content?[0]["text"] as? String, "Unknown tool 'nope'.")
        }

        test("a missing name is an unknown tool with an empty name") {
            for line in [#"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#,
                         #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#,
                         #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":7}}"#] {
                let text = ((result(line)?["content"] as? [[String: Any]])?.first)?["text"] as? String
                expectEqual(text, "Unknown tool ''.", line)
            }
        }

        test("a known tool with missing arguments returns its validation error") {
            let res = result(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"type_text","arguments":{}}}"#)
            expectEqual(res?["isError"] as? Bool, true)
            expectEqual(((res?["content"] as? [[String: Any]])?.first)?["text"] as? String, "'text' is required.")
        }

        test("missing or non-object arguments count as an empty object") {
            for line in [#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"press_key"}}"#,
                         #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"press_key","arguments":[1,2]}}"#,
                         #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"press_key","arguments":"keys"}}"#] {
                let text = ((result(line)?["content"] as? [[String: Any]])?.first)?["text"] as? String
                expectEqual(text, "'keys' is required.", line)
            }
        }

        test("arguments reach the tool and the call is logged") {
            let res = result(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"press_key","arguments":{"keys":"hyper+s"}}}"#)
            expectEqual(((res?["content"] as? [[String: Any]])?.first)?["text"] as? String, "Unknown modifier 'hyper'. Use cmd, shift, alt, ctrl, fn.")
            let entry = Env.logEntries().first
            expectEqual(entry?["tool"] as? String, "press_key")
            expectEqual((entry?["args"] as? [String: Any])?["keys"] as? String, "hyper+s")
        }

        test("a paused server refuses tool calls") {
            Safety.pause("by the user")
            let res = result(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"press_key","arguments":{"keys":"a"}}}"#)
            expectEqual(res?["isError"] as? Bool, true)
            expectContains(((res?["content"] as? [[String: Any]])?.first)?["text"] as? String ?? "", "mac-use is paused")
        }
    }

    suite("MCP: errors and notifications") {
        test("an unknown method is -32601 with the method name and the request id") {
            let r = reply(#"{"jsonrpc":"2.0","id":"x9","method":"foo/bar"}"#)
            expectEqual(r?["id"] as? String, "x9")
            expect(r?["result"] == nil)
            let e = r?["error"] as? [String: Any]
            expectEqual(e?["code"] as? Int, -32601)
            expectEqual(e?["message"] as? String, "Method not found: foo/bar")
        }

        test("notifications get no reply, known or unknown") {
            expectEqual(send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).text, "")
            expectEqual(send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#).text, "")
            expectEqual(send(#"{"jsonrpc":"2.0","method":"ping"}"#).text, "")
            expectEqual(send(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"press_key"}}"#).text, "")
            expectEqual(Env.logText(), "")
        }

        test("responses to the server and messages without a method are ignored") {
            expectEqual(send(#"{"jsonrpc":"2.0","id":1,"result":{}}"#).text, "")
            expectEqual(send(#"{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"x"}}"#).text, "")
            expectEqual(send("{}").text, "")
        }

        test("a non-string method is ignored (pinned)") {
            expectEqual(send(#"{"jsonrpc":"2.0","id":1,"method":5}"#).text, "")
        }

        test("malformed JSON is a -32700 parse error with a null id") {
            for line in ["{", "not json", #"{"jsonrpc":"2.0","id":1,"method":"ping""#, "{'id':1}", #"{"id":1,"method":"ping"} trailing"#] {
                let r = reply(line)
                expect(r?["id"] is NSNull, "id for \(line)")
                let e = r?["error"] as? [String: Any]
                expectEqual(e?["code"] as? Int, -32700, line)
                expectEqual(e?["message"] as? String, "Parse error", line)
                expectEqual(r?["jsonrpc"] as? String, "2.0")
            }
        }

        test("valid JSON that is not an object is also reported as a parse error (pinned)") {
            for line in ["[1,2]", "42", #""text""#, "null", "true"] {
                expectEqual(errorBody(line)?.code, -32700, line)
            }
        }

        test("a batch array is not supported and reports a parse error (pinned)") {
            expectEqual(errorBody(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)?.code, -32700)
        }

        test("the server keeps working after a bad line") {
            let sink = send("{", #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
            expectEqual(sink.messages.count, 2)
            expectEqual(sink.messages[1]["id"] as? Int, 2)
            expect(sink.messages[1]["result"] != nil)
        }
    }
}

import Foundation

private func run(_ tool: Tool, _ args: String = "{}") -> String {
    do {
        _ = try tool.run(json(args))
        return "<no error>"
    } catch {
        return "\(error)"
    }
}

private let noObservation = "No current observation. Call observe first."
private let noScreenshot = "No screenshot yet. Call observe or screenshot first."

func registerToolsTests() {
    suite("Tools: registry and schemas") {
        test("all fifteen tools are registered with unique names") {
            let names = Tools.all.map(\.name)
            expectEqual(names, ["list_apps", "open_app", "observe", "screenshot", "click", "type_text", "set_value", "press_key",
                                "scroll", "drag", "hover", "find_text", "wait_for", "menu", "run_script"])
            expectEqual(Set(names).count, names.count)
        }

        test("find returns a tool by name and nil for unknown names") {
            expectEqual(Tools.find("click")?.name, "click")
            expect(Tools.find("nope") == nil)
            expect(Tools.find("") == nil)
            expect(Tools.find("CLICK") == nil)
        }

        test("each definition is a complete, JSON-serializable MCP tool") {
            for tool in Tools.all {
                let d = tool.definition
                expect(JSONSerialization.isValidJSONObject(d), "\(tool.name) definition is not valid JSON")
                expectEqual(d["name"] as? String, tool.name)
                expect(!(d["description"] as? String ?? "").isEmpty, "\(tool.name) has no description")
                let schema = d["inputSchema"] as? [String: Any]
                expectEqual(schema?["type"] as? String, "object", tool.name)
                let props = schema?["properties"] as? [String: Any] ?? [:]
                let required = schema?["required"] as? [String] ?? []
                for key in required { expect(props[key] != nil, "\(tool.name) requires \(key) but does not declare it") }
                for (key, value) in props {
                    let p = value as? [String: Any]
                    expect(["string", "number", "integer", "boolean"].contains(p?["type"] as? String ?? ""), "\(tool.name).\(key) has a bad type")
                    expect(!(p?["description"] as? String ?? "").isEmpty, "\(tool.name).\(key) has no description")
                }
            }
        }

        test("required arguments per tool") {
            let expected: [String: [String]] = [
                "list_apps": [], "open_app": ["app"], "observe": [], "screenshot": [], "click": [], "type_text": ["text"],
                "set_value": ["element", "value"], "press_key": ["keys"], "scroll": [], "drag": [], "hover": [],
                "find_text": [], "wait_for": ["text"], "menu": [], "run_script": ["script"],
            ]
            for tool in Tools.all { expectEqual(tool.required, expected[tool.name] ?? ["?"], tool.name) }
        }

        test("only pure reads are marked read-only") {
            let readOnly = Set(Tools.all.filter(\.readOnly).map(\.name))
            expectEqual(readOnly, ["list_apps", "observe", "screenshot", "find_text", "wait_for"])
            for tool in Tools.all {
                let a = tool.definition["annotations"] as? [String: Any]
                expectEqual(a?["readOnlyHint"] as? Bool, tool.readOnly, tool.name)
                expectEqual(a?["destructiveHint"] as? Bool, false, tool.name)
                expectEqual(a?["openWorldHint"] as? Bool, false, tool.name)
            }
        }

        test("enum arguments list their allowed values") {
            func values(_ tool: Tool, _ key: String) -> [String]? {
                (tool.properties[key] as? [String: Any])?["enum"] as? [String]
            }
            expectEqual(values(Tools.click, "button"), ["left", "right", "middle"])
            expectEqual(values(Tools.click, "method"), ["auto", "press", "mouse"])
            expectEqual(values(Tools.scroll, "direction"), ["up", "down", "left", "right"])
            expectEqual(values(Tools.runScript, "language"), ["applescript", "javascript"])
        }

        test("element arguments are integers and coordinates are numbers") {
            func type(_ tool: Tool, _ key: String) -> String? { (tool.properties[key] as? [String: Any])?["type"] as? String }
            expectEqual(type(Tools.click, "element"), "integer")
            expectEqual(type(Tools.click, "x"), "number")
            expectEqual(type(Tools.drag, "from_element"), "integer")
            expectEqual(type(Tools.drag, "to_y"), "number")
            expectEqual(type(Tools.pressKey, "repeat"), "integer")
            expectEqual(type(Tools.observe, "screenshot"), "boolean")
        }
    }

    suite("Tools: Tools.call") {
        test("an unknown tool is an error result and is not logged") {
            let (content, isError) = Tools.call("nope", [:])
            expect(isError)
            expectEqual(Tools.firstText(content), "Unknown tool 'nope'.")
            expectEqual(Env.logText(), "")
        }

        test("an empty tool name is unknown") {
            expectEqual(Tools.firstText(Tools.call("", [:]).content), "Unknown tool ''.")
        }

        test("validation errors come back as error results with the plain message") {
            let (content, isError) = Tools.call("type_text", [:])
            expect(isError)
            expectEqual(content.count, 1)
            expectEqual(Tools.firstText(content), "'text' is required.")
        }

        test("a failing action tool is logged with its arguments and the error") {
            _ = Tools.call("type_text", ["element": "abc", "text": "hello"])
            let entries = Env.logEntries()
            expectEqual(entries.count, 1)
            expectEqual(entries[0]["tool"] as? String, "type_text")
            expectEqual(entries[0]["result"] as? String, "error: Bad element index 'abc'.")
            expectEqual((entries[0]["args"] as? [String: Any])?["text"] as? String, "hello")
        }

        test("long typed text is truncated in the log") {
            _ = Tools.call("type_text", ["element": "abc", "text": String(repeating: "x", count: 500)])
            let text = (Env.logEntries()[0]["args"] as? [String: Any])?["text"] as? String
            expectEqual(text?.count, 121)
        }

        test("a failing read-only tool is not logged") {
            let (content, isError) = Tools.call("wait_for", [:])
            expect(isError)
            expectEqual(Tools.firstText(content), "'text' is required.")
            expectEqual(Env.logText(), "")
        }

        test("without accessibility permission action tools fail before validating") {
            Tools.isTrusted = { false }
            let (content, isError) = Tools.call("type_text", [:])
            expect(isError)
            expectContains(Tools.firstText(content), "Accessibility permission is missing")
            expectContains(Env.logEntries().first?["result"] as? String ?? "", "error: Accessibility permission is missing")
        }

        test("run_script does not need accessibility permission") {
            Tools.isTrusted = { false }
            expectEqual(Tools.firstText(Tools.call("run_script", [:]).content), "'script' is required.")
        }

        test("a paused mac-use stops action tools before validation and logs the refusal") {
            Safety.pause("by the user")
            let (content, isError) = Tools.call("type_text", [:])
            expect(isError)
            expectEqual(Tools.firstText(content), "mac-use is paused (by the user). Stop and tell the user; they can resume with `mac-use resume`.")
            expectContains(Env.logEntries().first?["result"] as? String ?? "", "error: mac-use is paused")
        }

        test("a paused mac-use also stops read-only tools other than list_apps") {
            Safety.pause("by the user")
            let (content, isError) = Tools.call("wait_for", ["text": "x"])
            expect(isError)
            expectContains(Tools.firstText(content), "mac-use is paused")
        }

        test("the failsafe corner pauses mac-use through Tools.call") {
            Safety.mouseLocation = { CGPoint(x: 0, y: 0) }
            let (content, isError) = Tools.call("click", [:])
            expect(isError)
            expectContains(Tools.firstText(content), "mac-use is paused (failsafe")
            expect(Safety.isPaused)
        }

        test("missing accessibility permission is reported before the pause") {
            Tools.isTrusted = { false }
            Safety.pause("x")
            expectContains(Tools.firstText(Tools.call("click", [:]).content), "Accessibility permission is missing")
        }

        test("firstText skips images and returns an empty string when there is no text") {
            expectEqual(Tools.firstText([.image(Data(), mime: "image/png"), .text("b"), .text("c")]), "b")
            expectEqual(Tools.firstText([.image(Data(), mime: "image/png")]), "")
            expectEqual(Tools.firstText([]), "")
        }
    }

    suite("Tools: open_app arguments") {
        test("app is required") {
            expectEqual(run(Tools.openApp), "'app' is required.")
            expectEqual(run(Tools.openApp, #"{"app":""}"#), "'app' is required.")
            expectEqual(run(Tools.openApp, #"{"app":null}"#), "'app' is required.")
            expectEqual(run(Tools.openApp, #"{"app":true}"#), "'app' is required.")
        }

        test("a denied app is refused before anything launches") {
            expectEqual(run(Tools.openApp, #"{"app":"1Password"}"#),
                        "This mentions '1Password', which is in deny_apps (\(Paths.config.path)). Ask the user to do this step.")
            expectContains(run(Tools.openApp, #"{"app":"com.apple.keychainaccess"}"#), "deny_apps")
            expectContains(run(Tools.openApp, #"{"app":"/System/Applications/Utilities/Keychain Access.app"}"#), "'Keychain Access'")
            expectContains(run(Tools.openApp, #"{"app":"bitwarden"}"#), "'Bitwarden'")
        }

        test("a custom deny entry is honored") {
            Env.writeConfig(#"{"deny_apps":["Secret Notes"]}"#)
            expectContains(run(Tools.openApp, #"{"app":"secret notes"}"#), "'Secret Notes'")
        }
    }

    suite("Tools: click arguments") {
        test("needs an element, text or both coordinates") {
            let message = "Give element, text, or x and y."
            expectEqual(run(Tools.click), message)
            expectEqual(run(Tools.click, #"{"x":10}"#), message)
            expectEqual(run(Tools.click, #"{"y":10}"#), message)
            expectEqual(run(Tools.click, #"{"text":""}"#), message)
            expectEqual(run(Tools.click, #"{"button":"left","count":2}"#), message)
        }

        test("a bad element index is rejected first") {
            expectEqual(run(Tools.click, #"{"element":"abc"}"#), "Bad element index 'abc'.")
            expectEqual(run(Tools.click, #"{"element":"zz","text":"OK","x":1,"y":1}"#), "Bad element index 'zz'.")
        }

        test("an element needs a prior observe") {
            expectEqual(run(Tools.click, #"{"element":1}"#), noObservation)
        }

        test("an element outside the observed list is rejected with the valid range") {
            installFakeSnapshot(count: 3)
            expectEqual(run(Tools.click, #"{"element":4}"#), "Element [4] is not in the latest observe (1-3). Call observe again.")
            expectEqual(run(Tools.click, #"{"element":0}"#), "Element [0] is not in the latest observe (1-3). Call observe again.")
        }

        test("an element whose app has gone away asks for a new observe") {
            installFakeSnapshot(count: 3)
            expectEqual(run(Tools.click, #"{"element":2}"#), noObservation)
        }

        test("coordinates need a screenshot") {
            expectEqual(run(Tools.click, #"{"x":5,"y":5}"#), noScreenshot)
        }

        test("coordinates outside the screenshot are rejected") {
            installFakeGeometry(width: 800, height: 600)
            expectEqual(run(Tools.click, #"{"x":900,"y":5}"#), "(900,5) is outside the latest screenshot (800x600).")
            expectEqual(run(Tools.click, #"{"x":5,"y":-3}"#), "(5,-3) is outside the latest screenshot (800x600).")
            expectEqual(run(Tools.click, #"{"x":"900","y":"5"}"#), "(900,5) is outside the latest screenshot (800x600).")
        }
    }

    suite("Tools: type_text arguments") {
        test("text is required and must be a string") {
            expectEqual(run(Tools.typeText), "'text' is required.")
            expectEqual(run(Tools.typeText, #"{"text":null}"#), "'text' is required.")
            expectEqual(run(Tools.typeText, #"{"text":42}"#), "'text' is required.")
            expectEqual(run(Tools.typeText, #"{"text":true}"#), "'text' is required.")
            expectEqual(run(Tools.typeText, #"{"clear":true,"submit":true}"#), "'text' is required.")
        }

        test("a bad or missing element is rejected before anything is typed") {
            expectEqual(run(Tools.typeText, #"{"text":"a","element":"abc"}"#), "Bad element index 'abc'.")
            expectEqual(run(Tools.typeText, #"{"text":"a","element":1}"#), noObservation)
            installFakeSnapshot(count: 2)
            expectEqual(run(Tools.typeText, #"{"text":"a","element":3}"#), "Element [3] is not in the latest observe (1-2). Call observe again.")
            expectEqual(run(Tools.typeText, #"{"text":"a","element":2}"#), noObservation)
        }
    }

    suite("Tools: set_value arguments") {
        test("element is required") {
            expectEqual(run(Tools.setValue), "'element' is required.")
            expectEqual(run(Tools.setValue, #"{"value":"x"}"#), "'element' is required.")
        }

        test("a bad or missing element is rejected") {
            expectEqual(run(Tools.setValue, #"{"element":"abc","value":"x"}"#), "Bad element index 'abc'.")
            expectEqual(run(Tools.setValue, #"{"element":1,"value":"x"}"#), noObservation)
            installFakeSnapshot(count: 1)
            expectEqual(run(Tools.setValue, #"{"element":2,"value":"x"}"#), "Element [2] is not in the latest observe (1-1). Call observe again.")
        }

        test("value is required once the element resolves") {
            installFakeSnapshot(count: 2)
            expectEqual(run(Tools.setValue, #"{"element":1}"#), "'value' is required.")
            expectEqual(run(Tools.setValue, #"{"element":2,"value":null}"#), "'value' is required.")
            expectEqual(run(Tools.setValue, #"{"element":2,"value":true}"#), "'value' is required.")
        }

        test("a resolved element and value need a live observation") {
            installFakeSnapshot(count: 2)
            expectEqual(run(Tools.setValue, #"{"element":1,"value":"x"}"#), noObservation)
            expectEqual(run(Tools.setValue, #"{"element":1,"value":""}"#), noObservation)
        }
    }

    suite("Tools: press_key arguments") {
        test("keys are required") {
            expectEqual(run(Tools.pressKey), "'keys' is required.")
            expectEqual(run(Tools.pressKey, #"{"keys":""}"#), "'keys' is required.")
            expectEqual(run(Tools.pressKey, #"{"keys":null}"#), "'keys' is required.")
            expectEqual(run(Tools.pressKey, #"{"app":"Notes","repeat":3}"#), "'keys' is required.")
        }

        test("unknown keys and modifiers are rejected before any app is touched") {
            expectContains(run(Tools.pressKey, #"{"keys":"bogus"}"#), "Unknown key 'bogus'.")
            expectContains(run(Tools.pressKey, #"{"keys":"cmd+bogus"}"#), "Unknown key 'bogus'.")
            expectEqual(run(Tools.pressKey, #"{"keys":"hyper+s"}"#), "Unknown modifier 'hyper'. Use cmd, shift, alt, ctrl, fn.")
            expectContains(run(Tools.pressKey, #"{"keys":"cmd+a nope","app":"Notes"}"#), "Unknown key 'nope'.")
        }
    }

    suite("Tools: scroll arguments") {
        test("coordinates need a screenshot and must be inside it") {
            expectEqual(run(Tools.scroll, #"{"x":5,"y":5}"#), noScreenshot)
            installFakeGeometry(width: 800, height: 600)
            expectEqual(run(Tools.scroll, #"{"x":5,"y":700,"direction":"up"}"#), "(5,700) is outside the latest screenshot (800x600).")
        }

        test("a bad or missing element is rejected") {
            expectEqual(run(Tools.scroll, #"{"element":"abc"}"#), "Bad element index 'abc'.")
            expectEqual(run(Tools.scroll, #"{"element":1}"#), noObservation)
            installFakeSnapshot(count: 1)
            expectEqual(run(Tools.scroll, #"{"element":5}"#), "Element [5] is not in the latest observe (1-1). Call observe again.")
            expectEqual(run(Tools.scroll, #"{"element":1}"#), noObservation)
        }
    }

    suite("Tools: drag arguments") {
        let message = "Give from_element or from_x/from_y, and to_element or to_x/to_y."

        test("both ends are required") {
            expectEqual(run(Tools.drag), message)
            expectEqual(run(Tools.drag, #"{"to_x":1,"to_y":1}"#), message)
            installFakeGeometry()
            expectEqual(run(Tools.drag, #"{"from_x":1,"from_y":1}"#), message)
            expectEqual(run(Tools.drag, #"{"from_x":1,"from_y":1,"to_x":5}"#), message)
        }

        test("points need a screenshot and must be inside it") {
            expectEqual(run(Tools.drag, #"{"from_x":1,"from_y":1,"to_x":2,"to_y":2}"#), noScreenshot)
            installFakeGeometry(width: 800, height: 600)
            expectEqual(run(Tools.drag, #"{"from_x":1,"from_y":1,"to_x":9999,"to_y":2}"#), "(9999,2) is outside the latest screenshot (800x600).")
            expectEqual(run(Tools.drag, #"{"from_x":-1,"from_y":1,"to_x":2,"to_y":2}"#), "(-1,1) is outside the latest screenshot (800x600).")
        }

        test("a bad or missing element is rejected") {
            expectEqual(run(Tools.drag, #"{"from_element":"zz","to_x":1,"to_y":1}"#), "Bad element index 'zz'.")
            expectEqual(run(Tools.drag, #"{"from_element":1,"to_element":2}"#), noObservation)
            installFakeSnapshot(count: 1)
            expectEqual(run(Tools.drag, #"{"from_element":2,"to_element":1}"#), "Element [2] is not in the latest observe (1-1). Call observe again.")
        }
    }

    suite("Tools: hover arguments") {
        test("needs an element or both coordinates") {
            expectEqual(run(Tools.hover), "Give element or x and y.")
            expectEqual(run(Tools.hover, #"{"x":1}"#), "Give element or x and y.")
        }

        test("coordinates need a screenshot and must be inside it") {
            expectEqual(run(Tools.hover, #"{"x":1,"y":1}"#), noScreenshot)
            installFakeGeometry(width: 640, height: 480)
            expectEqual(run(Tools.hover, #"{"x":641,"y":1}"#), "(641,1) is outside the latest screenshot (640x480).")
        }

        test("a bad or missing element is rejected") {
            expectEqual(run(Tools.hover, #"{"element":"abc"}"#), "Bad element index 'abc'.")
            expectEqual(run(Tools.hover, #"{"element":2}"#), noObservation)
        }
    }

    suite("Tools: wait_for arguments") {
        test("text is required") {
            expectEqual(run(Tools.waitFor), "'text' is required.")
            expectEqual(run(Tools.waitFor, #"{"text":""}"#), "'text' is required.")
            expectEqual(run(Tools.waitFor, #"{"app":"Notes","gone":true,"timeout":5}"#), "'text' is required.")
        }
    }

    suite("Tools: run_script arguments") {
        test("script is required and must be a non-empty string") {
            expectEqual(run(Tools.runScript), "'script' is required.")
            expectEqual(run(Tools.runScript, #"{"script":""}"#), "'script' is required.")
            expectEqual(run(Tools.runScript, #"{"script":null}"#), "'script' is required.")
            expectEqual(run(Tools.runScript, #"{"script":42}"#), "'script' is required.")
            expectEqual(run(Tools.runScript, #"{"language":"javascript","timeout":5}"#), "'script' is required.")
        }

        test("a script that mentions a denied app is refused before anything is written or run") {
            let message = run(Tools.runScript, #"{"script":"tell application \"1Password\" to activate"}"#)
            expectEqual(message, "This mentions '1Password', which is in deny_apps (\(Paths.config.path)). Ask the user to do this step.")
            expectEqual((try? FileManager.default.contentsOfDirectory(atPath: Paths.caches.path)) ?? [], [], "script files were written")
        }

        test("the deny check ignores case and applies to JavaScript too") {
            expectContains(run(Tools.runScript, #"{"script":"Application('KEYCHAIN ACCESS').activate()","language":"javascript"}"#), "'Keychain Access'")
        }
    }

    suite("Tools: not covered here") {
        skip("list_apps", "reads the real running apps")
        skip("observe", "first step resolves and activates a real app")
        skip("screenshot", "first step reads the real frontmost app and captures the screen")
        skip("find_text", "first step resolves a real app and runs OCR on its window")
        skip("menu", "first step resolves a real app and reads its menu bar")
        skip("positive paths of click, type_text, set_value, press_key, scroll, drag, hover, run_script, open_app", "they post input events, press UI or run osascript")
    }
}

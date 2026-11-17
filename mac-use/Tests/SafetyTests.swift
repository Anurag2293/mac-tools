import AppKit
import Foundation

func registerSafetyTests() {
    suite("Safety: paths") {
        test("every state path lives under MAC_USE_HOME") {
            let home = Paths.home.resolvingSymlinksInPath().path
            expectEqual(home, Env.root.path)
            expectEqual(Paths.support.lastPathComponent, "mac-use")
            expectEqual(Paths.config.lastPathComponent, "config.json")
            expectEqual(Paths.paused.lastPathComponent, "PAUSED")
            expectEqual(Paths.actionLog.lastPathComponent, "actions.jsonl")
            expect(Paths.support.path.hasSuffix("Library/Application Support/mac-use"))
            expect(Paths.logs.path.hasSuffix("Library/Logs/mac-use"))
            expect(Paths.caches.path.hasSuffix("Library/Caches/mac-use"))
            for url in [Paths.support, Paths.logs, Paths.caches, Paths.config, Paths.paused, Paths.actionLog] {
                expect(url.resolvingSymlinksInPath().path.hasPrefix(home + "/"), "\(url.path) escapes the scratch home")
            }
        }

        test("ensure creates the three directories") {
            Paths.ensure()
            for url in [Paths.support, Paths.logs, Paths.caches] {
                var isDir: ObjCBool = false
                expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue, "\(url.path) missing")
            }
        }
    }

    suite("Safety: config") {
        test("a missing config is seeded with the default deny list") {
            let config = Config.load()
            expectEqual(config.denyApps, Config.defaultDeny)
            expectEqual(config.allowApps, [])
            let seeded = (try? Data(contentsOf: Paths.config)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            expectEqual(seeded?["deny_apps"] as? [String], Config.defaultDeny)
            expectEqual(seeded?["allow_apps"] as? [String], [])
            expect((seeded?["_help"] as? String)?.contains("deny_apps") == true)
        }

        test("the default deny list covers password managers and Keychain") {
            let lower = Config.defaultDeny.map { $0.lowercased() }
            for name in ["com.apple.keychainaccess", "keychain access", "com.apple.passwords", "passwords",
                         "com.1password.1password", "1password", "com.bitwarden.desktop", "bitwarden"] {
                expect(lower.contains(name), "\(name) missing from defaultDeny")
            }
        }

        test("a user config is read as written") {
            Env.writeConfig(#"{"deny_apps":["Foo","com.bar"],"allow_apps":["Baz"]}"#)
            let config = Config.load()
            expectEqual(config.denyApps, ["Foo", "com.bar"])
            expectEqual(config.allowApps, ["Baz"])
        }

        test("an existing config is not overwritten by load") {
            let text = #"{"deny_apps":["Foo"]}"#
            Env.writeConfig(text)
            _ = Config.load()
            expectEqual(try String(contentsOf: Paths.config, encoding: .utf8), text)
        }

        test("an explicitly empty deny list stays empty") {
            Env.writeConfig(#"{"deny_apps":[],"allow_apps":[]}"#)
            expectEqual(Config.load().denyApps, [])
        }

        test("missing keys fall back to the defaults") {
            Env.writeConfig(#"{"allow_apps":["Safari"]}"#)
            let config = Config.load()
            expectEqual(config.denyApps, Config.defaultDeny)
            expectEqual(config.allowApps, ["Safari"])
        }

        test("malformed JSON falls back to the defaults and leaves the file alone") {
            Env.writeConfig("{not json")
            let config = Config.load()
            expectEqual(config.denyApps, Config.defaultDeny)
            expectEqual(config.allowApps, [])
            expectEqual(try String(contentsOf: Paths.config, encoding: .utf8), "{not json")
        }

        test("an empty or non-object config falls back to the defaults") {
            Env.writeConfig("")
            expectEqual(Config.load().denyApps, Config.defaultDeny)
            Env.writeConfig("[1,2]")
            expectEqual(Config.load().denyApps, Config.defaultDeny)
        }

        test("a deny_apps of the wrong type keeps the default deny list") {
            Env.writeConfig(#"{"deny_apps":"Keychain Access"}"#)
            expectEqual(Config.load().denyApps, Config.defaultDeny)
            Env.writeConfig(#"{"deny_apps":["Foo",1]}"#)
            expectEqual(Config.load().denyApps, Config.defaultDeny)
        }

        test("an allow_apps of the wrong type is ignored, which lifts the restriction (pinned)") {
            Env.writeConfig(#"{"allow_apps":"Safari"}"#)
            expectEqual(Config.load().allowApps, [])
        }
    }

    suite("Safety: app matching") {
        test("matches by bundle id or name, ignoring case") {
            expect(Safety.matches(names: ["com.1password.1password", "1Password"], ["1PASSWORD"]))
            expect(Safety.matches(names: ["com.1password.1password", "1Password"], ["Com.1Password.1Password"]))
            expect(Safety.matches(names: [nil, "Passwords"], ["passwords"]))
            expect(Safety.matches(names: ["com.apple.Passwords", nil], ["COM.APPLE.PASSWORDS"]))
        }

        test("matching is exact, not substring") {
            expect(!Safety.matches(names: ["com.1password.1password", "1Password"], ["Password"]))
            expect(!Safety.matches(names: ["com.example.passwordsafe", "Passwords Helper"], ["Passwords"]))
        }

        test("nothing matches an app without a name and an empty list") {
            expect(!Safety.matches(names: [nil, nil], ["a"]))
            expect(!Safety.matches(names: ["x"], []))
        }

        test("checkApp lets everything through with the default lists") {
            try Safety.check(names: ["com.apple.finder", "Finder"], display: "Finder")
        }

        test("checkApp blocks deny_apps by name and by bundle id") {
            expectError("mac-use is not allowed to touch 1Password (deny_apps in \(Paths.config.path)). Ask the user to do this step.") {
                try Safety.check(names: ["com.1password.1password", "1Password"], display: "1Password")
            }
            expectErrorContaining("not allowed to touch Vault") {
                try Safety.check(names: ["com.bitwarden.desktop", nil], display: "Vault")
            }
            expectErrorContaining("not allowed to touch Keychain Access") {
                try Safety.check(names: [nil, "keychain access"], display: "Keychain Access")
            }
        }

        test("checkApp with allow_apps blocks everything else") {
            Env.writeConfig(#"{"deny_apps":[],"allow_apps":["Safari"]}"#)
            try Safety.check(names: ["com.apple.Safari", "Safari"], display: "Safari")
            expectError("Finder is not in allow_apps (\(Paths.config.path)). Ask the user to do this step or to allow the app.") {
                try Safety.check(names: ["com.apple.finder", "Finder"], display: "Finder")
            }
        }

        test("deny_apps wins over allow_apps") {
            Env.writeConfig(#"{"deny_apps":["Safari"],"allow_apps":["Safari"]}"#)
            expectErrorContaining("not allowed to touch Safari") {
                try Safety.check(names: ["com.apple.Safari", "Safari"], display: "Safari")
            }
        }

        test("checkApp(nil) is a no-op") {
            try Safety.checkApp(nil)
        }

        test("checkName blocks text that mentions a denied app, ignoring case") {
            expectError("This mentions '1Password', which is in deny_apps (\(Paths.config.path)). Ask the user to do this step.") {
                try Safety.checkName("open my 1PASSWORD vault")
            }
            expectErrorContaining("'Keychain Access'") { try Safety.checkName("tell application \"keychain access\" to activate") }
        }

        test("checkName is a substring check, so harmless text with a denied word is blocked (pinned)") {
            expectErrorContaining("'Passwords'") { try Safety.checkName("reset passwords policy") }
        }

        test("checkName allows unrelated text and honors a cleared deny list") {
            try Safety.checkName("tell application \"Finder\" to get name of home")
            Env.writeConfig(#"{"deny_apps":[]}"#)
            try Safety.checkName("1Password")
        }

        test("checkName reports the first matching deny entry") {
            Env.writeConfig(#"{"deny_apps":["alpha","beta"]}"#)
            expectErrorContaining("'alpha'") { try Safety.checkName("beta and alpha") }
        }
    }

    suite("Safety: pause state") {
        test("not paused by default") {
            expect(!Safety.isPaused)
        }

        test("pause writes the reason and resume removes it") {
            Safety.pause("because")
            expect(Safety.isPaused)
            expectEqual(try String(contentsOf: Paths.paused, encoding: .utf8), "because")
            Safety.resume()
            expect(!Safety.isPaused)
            expect(!FileManager.default.fileExists(atPath: Paths.paused.path))
        }

        test("resume without a pause does nothing") {
            Safety.resume()
            expect(!Safety.isPaused)
        }

        test("checkNotPaused passes when running") {
            try Safety.checkNotPaused()
        }

        test("checkNotPaused tells the agent to stop and quotes the trimmed reason") {
            Safety.pause("  by the user \n")
            expectError("mac-use is paused (by the user). Stop and tell the user; they can resume with `mac-use resume`.") {
                try Safety.checkNotPaused()
            }
        }

        test("checkNotPaused with an empty reason still blocks") {
            Safety.pause("")
            expectErrorContaining("mac-use is paused") { try Safety.checkNotPaused() }
        }

        test("a second pause replaces the reason") {
            Safety.pause("first")
            Safety.pause("second")
            expectEqual(try String(contentsOf: Paths.paused, encoding: .utf8), "second")
        }

        test("resume lets actions through again") {
            Safety.pause("x")
            Safety.resume()
            try Safety.checkNotPaused()
        }
    }

    suite("Safety: failsafe corner") {
        test("the top-left corner pauses and records why") {
            Safety.mouseLocation = { CGPoint(x: 0, y: 0) }
            expect(Safety.failsafeTripped())
            expect(Safety.isPaused)
            let reason = try String(contentsOf: Paths.paused, encoding: .utf8)
            expectContains(reason, "failsafe: mouse moved to the top-left corner at ")
        }

        test("the trigger zone is x and y both within 2 points") {
            let cases: [(CGFloat, CGFloat, Bool)] = [(2, 2, true), (1, 0, true), (-5, -5, true), (0, 3, false), (3, 0, false), (2.5, 1, false), (500, 500, false)]
            for (x, y, trips) in cases {
                Env.reset()
                Safety.mouseLocation = { CGPoint(x: x, y: y) }
                expectEqual(Safety.failsafeTripped(), trips, "at (\(x),\(y))")
                expectEqual(Safety.isPaused, trips, "paused state at (\(x),\(y))")
            }
        }

        test("an unknown mouse location does not trip") {
            Safety.mouseLocation = { nil }
            expect(!Safety.failsafeTripped())
            expect(!Safety.isPaused)
        }

        test("once paused it stays tripped when the mouse moves away, and keeps the first reason") {
            Safety.pause("by the user")
            Safety.mouseLocation = { CGPoint(x: 0, y: 0) }
            expect(Safety.failsafeTripped())
            expectEqual(try String(contentsOf: Paths.paused, encoding: .utf8), "by the user")
            Safety.mouseLocation = { CGPoint(x: 900, y: 900) }
            expect(Safety.failsafeTripped())
        }

        test("checkNotPaused trips on the corner") {
            Safety.mouseLocation = { CGPoint(x: 1, y: 1) }
            expectErrorContaining("mac-use is paused (failsafe: mouse moved to the top-left corner at ") {
                try Safety.checkNotPaused()
            }
        }

        test("timestamps are ISO 8601") {
            let ts = Safety.timestamp()
            expect(ISO8601DateFormatter().date(from: ts) != nil, "\(ts) does not parse")
            expect(ts.hasSuffix("Z"))
        }
    }

    suite("Safety: action log") {
        test("an entry is one JSON line with ts, tool, args, front and result") {
            Safety.log("click", ["element": 3, "button": "left"], "ok: Pressed [3]")
            let text = Env.logText()
            expect(text.hasSuffix("\n"))
            expectEqual(text.split(separator: "\n").count, 1)
            let entry = Env.logEntries()[0]
            expectEqual(Set(entry.keys), ["ts", "tool", "args", "front", "result"])
            expectEqual(entry["tool"] as? String, "click")
            expectEqual(entry["front"] as? String, "TestApp")
            expectEqual(entry["result"] as? String, "ok: Pressed [3]")
            let args = entry["args"] as? [String: Any]
            expectEqual(args?["element"] as? Int, 3)
            expectEqual(args?["button"] as? String, "left")
            expect(ISO8601DateFormatter().date(from: entry["ts"] as? String ?? "") != nil)
        }

        test("keys are sorted so the line starts with args") {
            Safety.log("x", [:], "r")
            expect(Env.logText().hasPrefix(#"{"args":{},"front":"TestApp","result":"r","tool":"x","ts":""#), Env.logText())
        }

        test("entries append in order") {
            Safety.log("one", [:], "1")
            Safety.log("two", [:], "2")
            Safety.log("three", [:], "3")
            expectEqual(Env.logEntries().compactMap { $0["tool"] as? String }, ["one", "two", "three"])
        }

        test("the log directory is created on demand") {
            expect(!FileManager.default.fileExists(atPath: Paths.logs.path))
            Safety.log("x", [:], "r")
            expect(FileManager.default.fileExists(atPath: Paths.actionLog.path))
        }

        test("text, value and script longer than 120 characters are truncated with an ellipsis") {
            let long = String(repeating: "a", count: 200)
            Safety.log("t", ["text": long, "value": long, "script": long, "other": long], "r")
            let args = Env.logEntries()[0]["args"] as? [String: Any]
            let expected = String(repeating: "a", count: 120) + "…"
            expectEqual(args?["text"] as? String, expected)
            expectEqual(args?["value"] as? String, expected)
            expectEqual(args?["script"] as? String, expected)
            expectEqual((args?["other"] as? String)?.count, 200)
        }

        test("exactly 120 characters are kept whole") {
            let s = String(repeating: "b", count: 120)
            Safety.log("t", ["text": s], "r")
            expectEqual((Env.logEntries()[0]["args"] as? [String: Any])?["text"] as? String, s)
        }

        test("truncation counts characters, not bytes") {
            let s = String(repeating: "あ", count: 130)
            Safety.log("t", ["text": s], "r")
            expectEqual((Env.logEntries()[0]["args"] as? [String: Any])?["text"] as? String, String(repeating: "あ", count: 120) + "…")
        }

        test("results are cut at 300 characters") {
            Safety.log("t", [:], String(repeating: "r", count: 500))
            expectEqual((Env.logEntries()[0]["result"] as? String)?.count, 300)
        }

        test("quotes, newlines and unicode survive as valid JSON") {
            Safety.log("t", ["text": "say \"hi\"\nsecond line\t日本語"], "ok")
            expectEqual(Env.logText().split(separator: "\n").count, 1)
            expectEqual((Env.logEntries()[0]["args"] as? [String: Any])?["text"] as? String, "say \"hi\"\nsecond line\t日本語")
        }

        test("arguments that are not valid JSON drop the entry instead of crashing (pinned)") {
            Safety.log("t", ["when": Date()], "r")
            expectEqual(Env.logText(), "")
        }

        test("front comes from the frontmost-app probe") {
            Safety.frontName = { "Notes" }
            Safety.log("t", [:], "r")
            expectEqual(Env.logEntries()[0]["front"] as? String, "Notes")
        }

        skip("rate limits", "mac-use has no rate limiting; the only throttles are the repeat cap of 100 and the 60 s wait_for cap")
    }
}

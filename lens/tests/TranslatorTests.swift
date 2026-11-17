import Foundation

/// Stands in for Apple's on-device translation: answers "A:" + text, in the order given.
final class FakeApple {
    var calls: [[(index: Int, text: String)]] = []
    var failure: Error?

    var fallback: Translator.Fallback {
        return { pending, each in
            self.calls.append(pending)
            if let f = self.failure { throw f }
            for p in pending { each(p.index, "A:" + p.text) }
        }
    }
}

private func makeTranslator(engine: String = "google", net: FakeGoogle = FakeGoogle(), apple: FakeApple = FakeApple())
    -> (Translator, FakeGoogle, FakeApple) {
    var env = ["LENS_ENGINE": engine]
    env["LENS_FROM"] = "ja"
    let t = Translator(config: Config(env: env), transport: net.transport, fallback: apple.fallback)
    return (t, net, apple)
}

private func run(_ t: Translator, _ texts: [String]) async throws -> [Int: String] {
    var got: [Int: String] = [:]
    try await t.translate(texts) { got[$0] = $1 }
    return got
}

func translatorTests() async {
    let savedSink = logSink
    var logs: [String] = []
    logSink = { logs.append($0) }

    await suite("config") {
        await test("defaults") {
            let c = Config(env: [:])
            eq(c.from, "ja"); eq(c.to, "en"); eq(c.hotkey, "double:rcmd"); eq(c.engine, "google")
        }
        await test("environment overrides") {
            let c = Config(env: ["LENS_FROM": "zh", "LENS_TO": "de", "LENS_HOTKEY": "ctrl+opt+t", "LENS_ENGINE": "apple"])
            eq(c.from, "zh"); eq(c.to, "de"); eq(c.hotkey, "ctrl+opt+t"); eq(c.engine, "apple")
        }
        await test("unrelated variables are ignored") {
            let c = Config(env: ["HOME": "/x", "LENS_OTHER": "y", "lens_from": "ko"])
            eq(c.from, "ja")
        }
        await test("pinned: an empty value is used as is, not as unset") {
            let c = Config(env: ["LENS_FROM": "", "LENS_ENGINE": ""])
            eq(c.from, ""); eq(c.engine, "")
        }
    }

    await suite("translator") {
        await test("google translates and fills the cache") {
            let (t, net, apple) = makeTranslator()
            let got = try await run(t, ["a", "b"])
            eq(got, [0: "T:a", 1: "T:b"]); eq(net.requests.count, 1); eq(apple.calls.count, 0)
            eq(t.cache, ["a": "T:a", "b": "T:b"])
        }
        await test("cached texts come back without a request") {
            let (t, net, _) = makeTranslator()
            _ = try await run(t, ["a", "b"])
            let got = try await run(t, ["b", "a"])
            eq(got, [0: "T:b", 1: "T:a"]); eq(net.requests.count, 1)
        }
        await test("cached texts are delivered before the network is used") {
            let (t, net, _) = makeTranslator()
            _ = try await run(t, ["a"])
            var order: [Int] = []
            net.override = { _, req in
                order.append(-1)
                return (jsonData([net.texts(req).map { "T:" + $0 }]), httpResponse(200))
            }
            try await t.translate(["new", "a"]) { i, _ in order.append(i) }
            eq(order, [1, -1, 0])
        }
        await test("only uncached texts are sent, with their own indices") {
            let (t, net, _) = makeTranslator()
            _ = try await run(t, ["b"])
            let got = try await run(t, ["a", "b", "c"])
            eq(got, [0: "T:a", 1: "T:b", 2: "T:c"])
            eq(net.texts(net.requests[1]), ["a", "c"])
        }
        await test("pinned: duplicates in one call are sent twice and both filled") {
            let (t, net, _) = makeTranslator()
            let got = try await run(t, ["x", "x"])
            eq(got, [0: "T:x", 1: "T:x"]); eq(net.texts(net.requests[0]), ["x", "x"])
        }
        await test("an empty list does nothing") {
            let (t, net, apple) = makeTranslator()
            let r7773 = try await run(t, [])
            eq(r7773, [:]); eq(net.requests.count, 0); eq(apple.calls.count, 0)
        }
        await test("an unchanged translation is cached too") {
            let (t, net, _) = makeTranslator()
            net.transform = { $0 }
            _ = try await run(t, ["same"]); _ = try await run(t, ["same"])
            eq(net.requests.count, 1)
        }
        await test("empty strings are translated like any other text") {
            let (t, net, _) = makeTranslator()
            let got = try await run(t, ["", "a"])
            eq(got, [0: "T:", 1: "T:a"]); eq(net.requests.count, 1)
        }
        await test("many texts go out in chunks and all come back") {
            let (t, net, _) = makeTranslator()
            let texts = (0..<1000).map { "t\($0)" }
            let got = try await run(t, texts)
            eq(got.count, 1000); eq(got[999], "T:t999"); eq(net.requests.count, 10)
        }
        await test("failing Google falls back to on-device with the pending texts, and caches those") {
            logs.removeAll()
            let (t, net, apple) = makeTranslator()
            net.status = 503
            let got = try await run(t, ["a", "b"])
            eq(got, [0: "A:a", 1: "A:b"])
            eq(apple.calls.count, 1); eq(apple.calls[0].map(\.text), ["a", "b"]); eq(apple.calls[0].map(\.index), [0, 1])
            eq(t.cache, ["a": "A:a", "b": "A:b"])
            check(logs.contains { $0.contains("falling back to on-device translation") && $0.contains("503") }, "\(logs)")
        }
        await test("the fallback only sees texts that were not cached") {
            let (t, net, apple) = makeTranslator()
            _ = try await run(t, ["a"])
            net.status = 500
            let got = try await run(t, ["a", "b", "c"])
            eq(got, [0: "T:a", 1: "A:b", 2: "A:c"])
            eq(apple.calls[0].map(\.index), [1, 2])
        }
        await test("hostile Google answers fall back instead of failing") {
            let answers: [(Int, Data)] = [(200, Data()), (200, Data("not json".utf8)), (200, jsonData([["one"]])), (200, jsonData([[1, 2]])),
                                          (200, jsonData(["x"])), (429, Data("slow down".utf8)), (200, jsonData(["error"]))]
            for (code, body) in answers {
                let (t, net, apple) = makeTranslator()
                net.override = { _, _ in (body, httpResponse(code)) }
                let got = try await run(t, ["a", "b"])
                eq(got, [0: "A:a", 1: "A:b"], "\(code) \(String(decoding: body, as: UTF8.self))")
                eq(apple.calls.count, 1)
            }
        }
        await test("transport errors fall back") {
            for err in [URLError(.notConnectedToInternet), URLError(.timedOut), URLError(.cannotFindHost)] {
                let (t, net, apple) = makeTranslator()
                net.override = { _, _ in throw err }
                let r6442 = try await run(t, ["a"])
                eq(r6442, [0: "A:a"]); eq(apple.calls.count, 1)
            }
        }
        await test("a failure in a later chunk delivers nothing from Google and falls back for everything") {
            let (t, net, apple) = makeTranslator()
            net.override = { n, req in
                if n == 1 { throw URLError(.timedOut) }
                return (jsonData([net.texts(req).map { "T:" + $0 }]), httpResponse(200))
            }
            let got = try await run(t, (0..<150).map(String.init))
            eq(got.count, 150); eq(got[0], "A:0"); eq(apple.calls[0].count, 150)
        }
        await test("engine apple never touches the network") {
            let (t, net, apple) = makeTranslator(engine: "apple")
            let r2442 = try await run(t, ["a"])
            eq(r2442, [0: "A:a"]); eq(net.requests.count, 0); eq(apple.calls.count, 1)
        }
        await test("pinned: any engine other than google means on-device only") {
            for e in ["Google", "GOOGLE", "", "bing", "apple", " google"] {
                let (t, net, apple) = makeTranslator(engine: e)
                _ = try await run(t, ["a"])
                eq(net.requests.count, 0, e); eq(apple.calls.count, 1, e)
            }
        }
        await test("a failing fallback fails the call") {
            let (t, net, apple) = makeTranslator()
            net.status = 500
            apple.failure = LensError("ja→en is not downloaded")
            let e = await thrown { _ = try await run(t, ["a"]) }
            check("\(e!)".contains("not downloaded"))
            eq(t.cache.count, 0)
        }
        await test("a fallback that answers only some texts leaves the rest unanswered") {
            let (t, net, _) = makeTranslator()
            net.status = 500
            let apple = FakeApple()
            t.fallback = { pending, each in each(pending[0].index, "A:" + pending[0].text) }
            _ = apple
            let got = try await run(t, ["a", "b"])
            eq(got, [0: "A:a"]); eq(t.cache, ["a": "A:a"])
        }
        await test("cancellation during the request is rethrown without fallback") {
            let (t, net, apple) = makeTranslator()
            net.override = { _, _ in throw CancellationError() }
            let e = await thrown { _ = try await run(t, ["a"]) }
            check(e is CancellationError); eq(apple.calls.count, 0)
        }
        await test("cancellation after the answer arrives delivers nothing") {
            let (t, net, apple) = makeTranslator()
            net.override = { _, req in
                withUnsafeCurrentTask { $0?.cancel() }
                return (jsonData([net.texts(req).map { "T:" + $0 }]), httpResponse(200))
            }
            var delivered = 0
            let task = Task { try await t.translate(["a", "b"]) { _, _ in delivered += 1 } }
            let r = await task.result
            if case .failure(let e) = r { check(e is CancellationError, "\(e)") } else { check(false, "should have thrown") }
            eq(delivered, 0); eq(t.cache.count, 0); eq(apple.calls.count, 0)
        }
        await test("URLSession reports a cancelled task as URLError.cancelled: no fallback, no result") {
            let (t, net, apple) = makeTranslator()
            net.override = { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.cancelled)
            }
            let task = Task { try await t.translate(["a"]) { _, _ in } }
            let r = await task.result
            if case .failure(let e) = r { check(e is CancellationError, "\(e)") } else { check(false, "should have thrown") }
            eq(apple.calls.count, 0, "on-device translation must not start after a dismiss")
        }
        await test("cancellation inside the fallback propagates") {
            let (t, net, _) = makeTranslator(engine: "apple")
            _ = net
            t.fallback = { _, _ in throw CancellationError() }
            let e = await thrown { _ = try await run(t, ["a"]) }
            check(e is CancellationError)
        }
        await test("the cache is cleared at the start of a call once it holds more than 5000 entries") {
            let (t, net, _) = makeTranslator()
            for i in 0..<5000 { t.cache["k\(i)"] = "v" }
            _ = try await run(t, ["new"])
            eq(t.cache.count, 5001, "5000 entries are kept")
            _ = try await run(t, ["newer"])
            eq(t.cache.count, 1, "5001 entries are dropped before the call")
            eq(net.requests.count, 2)
        }
        await test("a cached hit still works in the call that clears the cache only for texts added afterwards") {
            let (t, net, _) = makeTranslator()
            for i in 0..<5001 { t.cache["k\(i)"] = "v" }
            let got = try await run(t, ["k0"])
            eq(got, [0: "T:k0"], "evicted entries are translated again"); eq(net.requests.count, 1)
        }
        await test("japanese round trip through the fake server") {
            let (t, net, _) = makeTranslator()
            net.transform = { $0 == "設定" ? "Settings" : "?" }
            let r5661 = try await run(t, ["設定", "未知"])
            eq(r5661, [0: "Settings", 1: "?"])
        }
    }

    logSink = savedSink
}

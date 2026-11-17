import Foundation

private func unescaped(_ s: String) -> String { htmlUnescape(s) }

/// Server side of translateHtml: answers `[[translations...], ["ja"]]` for each request.
final class FakeGoogle {
    var requests: [URLRequest] = []
    var status = 200
    var transform: (String) -> String = { "T:" + $0 }
    var override: ((Int, URLRequest) async throws -> (Data, URLResponse))?

    func texts(_ req: URLRequest) -> [String] {
        let body = jsonBody(req) as! [Any]
        return ((body[0] as! [Any])[0] as! [String])
    }

    var transport: Transport {
        return { req in
            let n = self.requests.count
            self.requests.append(req)
            if let o = self.override { return try await o(n, req) }
            let out = self.texts(req).map(self.transform)
            return (jsonData([out, ["ja"]]), httpResponse(self.status))
        }
    }
}

func googleTests() async {
    await suite("html escaping") {
        await test("escape") {
            eq(htmlEscape("a & b < c > d"), "a &amp; b &lt; c &gt; d")
            eq(htmlEscape(""), "")
            eq(htmlEscape("日本語"), "日本語")
            eq(htmlEscape("&amp;"), "&amp;amp;")
            eq(htmlEscape("\"quoted\" 'single'"), "\"quoted\" 'single'")
        }
        await test("unescape named entities") {
            eq(unescaped("&lt;b&gt; &amp; &quot;q&quot; &apos;s&apos;"), "<b> & \"q\" 's'")
            eq(unescaped("a&nbsp;b"), "a b")
            eq(unescaped("no entities"), "no entities")
            eq(unescaped(""), "")
        }
        await test("unescape numeric entities") {
            eq(unescaped("&#65;&#x42;&#x63;"), "ABc")
            eq(unescaped("&#39;"), "'")
            eq(unescaped("&#x65E5;&#26412;"), "日本")
            eq(unescaped("&#x1F600;"), "\u{1F600}")
        }
        await test("entities that are not valid are left alone") {
            for s in ["&", "&&", "&;", "&#;", "&#x;", "&unknown;", "&amp", "&#xD800;", "&#99999999999;", "&#1a;", "&#xZZ;", "&#X41;", "&AMP;", "&LT;", "a & b"] {
                eq(unescaped(s), s, s)
            }
        }
        await test("an ampersand entity is decoded once, not twice") {
            eq(unescaped("&amp;lt;"), "&lt;")
            eq(unescaped("&amp;amp;"), "&amp;")
            eq(unescaped("&amp;#65;"), "&#65;")
            eq(unescaped("&amp;quot;"), "&quot;")
        }
        await test("a numeric ampersand is not decoded again") {
            eq(unescaped("&#38;amp;"), "&amp;")
            eq(unescaped("&#x26;lt;"), "&lt;")
            eq(unescaped("&#38;#65;"), "&#65;")
        }
        await test("escape then unescape is the identity") {
            let samples = ["a & b", "<tag>", "&lt;", "&amp;", "&#65;", "&amp;lt;", "&&&", "<<>>", "5 > 3 && 2 < 4", "日本語&英語<br>",
                           "&#x26;", "&nbsp;", "\u{1F600} & \u{1F600}", "", "&", "a&b;c", "&quot;", "line\nbreak & tab\t"]
            for s in samples { eq(unescaped(htmlEscape(s)), s, s) }
        }
        await test("pinned: nbsp becomes a plain space and NUL is decoded") {
            eq(unescaped("&nbsp;"), " ")
            eq(unescaped("&#0;"), "\u{0}")
        }
        await test("many entities") {
            let s = String(repeating: "&amp;&#65;&lt;", count: 3000)
            let t0 = Date()
            eq(unescaped(s), String(repeating: "&A<", count: 3000))
            check(Date().timeIntervalSince(t0) < 5, "took \(Date().timeIntervalSince(t0)) s")
        }
    }

    await suite("google chunks") {
        await test("empty") { eq(googleChunks([]).count, 0) }
        await test("one text") { eq(googleChunks(["a"]), [0..<1]) }
        await test("at most 100 texts per request") {
            eq(googleChunks(Array(repeating: "x", count: 100)), [0..<100])
            eq(googleChunks(Array(repeating: "x", count: 101)), [0..<100, 100..<101])
            eq(googleChunks(Array(repeating: "x", count: 250)), [0..<100, 100..<200, 200..<250])
        }
        await test("at most about 8000 characters per request") {
            eq(googleChunks([String(repeating: "x", count: 5000), String(repeating: "x", count: 5000)]), [0..<1, 1..<2])
            eq(googleChunks([String(repeating: "x", count: 3000), String(repeating: "x", count: 4999)]), [0..<2])
            eq(googleChunks([String(repeating: "x", count: 3000), String(repeating: "x", count: 5000)]), [0..<1, 1..<2], "7999 fits, 8000 does not")
        }
        await test("an oversized text gets a request of its own") {
            let big = String(repeating: "x", count: 20000)
            eq(googleChunks([big]), [0..<1])
            eq(googleChunks(["a", big, "b"]), [0..<1, 1..<2, 2..<3])
        }
        await test("empty strings still count toward the 100 limit") {
            eq(googleChunks(Array(repeating: "", count: 150)), [0..<100, 100..<150])
        }
        await test("characters, not bytes, are counted") {
            eq(googleChunks([String(repeating: "日", count: 3999), String(repeating: "日", count: 3999)]), [0..<2])
        }
        await test("chunks are contiguous and cover every text") {
            var texts: [String] = []
            for i in 0..<777 { texts.append(String(repeating: "あ", count: (i * 37) % 900)) }
            let chunks = googleChunks(texts)
            var next = 0
            for c in chunks {
                eq(c.lowerBound, next); check(!c.isEmpty); check(c.count <= 100)
                next = c.upperBound
            }
            eq(next, texts.count)
        }
    }

    await suite("google request") {
        await test("url, method, headers and timeout") {
            let r = try googleRequest(["a"], from: "ja", to: "en")
            eq(r.url, googleURL); eq(r.httpMethod, "POST"); eq(r.timeoutInterval, 8)
            eq(r.value(forHTTPHeaderField: "Content-Type"), "application/json+protobuf")
            eq(r.value(forHTTPHeaderField: "X-Goog-API-Key"), googleKey)
            eq(googleURL.absoluteString, "https://translate-pa.googleapis.com/v1/translateHtml")
        }
        await test("body is [[texts, from, to], \"te_lib\"]") {
            let r = try googleRequest(["こんにちは", "設定"], from: "ja", to: "en")
            let body = jsonBody(r) as! [Any]
            eq(body.count, 2); eq(body[1] as? String, "te_lib")
            let inner = body[0] as! [Any]
            eq(inner[0] as? [String], ["こんにちは", "設定"]); eq(inner[1] as? String, "ja"); eq(inner[2] as? String, "en")
        }
        await test("texts are HTML escaped") {
            let r = try googleRequest(["a < b & c > d"], from: "ja", to: "en")
            eq((((jsonBody(r) as! [Any])[0] as! [Any])[0] as! [String]), ["a &lt; b &amp; c &gt; d"])
        }
        await test("empty list and empty strings") {
            let r = try googleRequest([], from: "ja", to: "en")
            eq(String(decoding: r.httpBody!, as: UTF8.self), "[[[],\"ja\",\"en\"],\"te_lib\"]")
            let s = try googleRequest(["", ""], from: "ja", to: "en")
            eq((((jsonBody(s) as! [Any])[0] as! [Any])[0] as! [String]), ["", ""])
        }
        await test("quotes, backslashes, newlines, control characters and emoji survive JSON") {
            let tricky = ["say \"hi\"", "back\\slash", "line\nbreak\ttab", "nul\u{0}char", "\u{1F600} \u{1F468}\u{200D}\u{1F469}", "/slash/", "\u{2028}"]
            let r = try googleRequest(tricky, from: "ja", to: "en")
            eq((((jsonBody(r) as! [Any])[0] as! [Any])[0] as! [String]), tricky)
        }
        await test("language codes are passed through") {
            let r = try googleRequest(["x"], from: "zh", to: "de")
            let inner = (jsonBody(r) as! [Any])[0] as! [Any]
            eq(inner[1] as? String, "zh"); eq(inner[2] as? String, "de")
        }
    }

    await suite("google response") {
        await test("a well-formed response") {
            let out = try parseGoogleResponse(jsonData([["Hello", "World"], ["ja", "ja"]]), httpResponse(200), expecting: 2)
            eq(out, ["Hello", "World"])
        }
        await test("entities in the response are decoded") {
            let out = try parseGoogleResponse(jsonData([["a &amp; b &lt;c&gt; &#39;q&#39;"]]), httpResponse(200), expecting: 1)
            eq(out, ["a & b <c> 'q'"])
        }
        await test("pinned: markup in a translation is not stripped") {
            let out = try parseGoogleResponse(jsonData([["<b>Hello</b>"]]), httpResponse(200), expecting: 1)
            eq(out, ["<b>Hello</b>"])
            let esc = try parseGoogleResponse(jsonData([["&lt;b&gt;Hello&lt;/b&gt;"]]), httpResponse(200), expecting: 1)
            eq(esc, ["<b>Hello</b>"])
        }
        await test("extra trailing elements are accepted") {
            let r7544 = try parseGoogleResponse(jsonData([["a"], ["ja"], 5, NSNull()]), httpResponse(200), expecting: 1)
            eq(r7544, ["a"])
        }
        await test("zero expected and an empty list") {
            let r4094 = try parseGoogleResponse(jsonData([[String]()]), httpResponse(200), expecting: 0)
            eq(r4094, [])
        }
        await test("empty translations are kept") {
            let r5801 = try parseGoogleResponse(jsonData([["", "x"]]), httpResponse(200), expecting: 2)
            eq(r5801, ["", "x"])
        }
        await test("unicode in translations") {
            let r7960 = try parseGoogleResponse(jsonData([["日本語 \u{1F600}"]]), httpResponse(200), expecting: 1)
            eq(r7960, ["日本語 \u{1F600}"])
        }
        await test("error statuses fail and name the status") {
            for code in [400, 403, 429, 500, 503, 302, 204] {
                let e = await thrown { _ = try parseGoogleResponse(jsonData([["a"]]), httpResponse(code), expecting: 1) }
                check("\(e!)".contains("HTTP \(code)"), "\(e!)")
            }
        }
        await test("a wrong count fails") {
            _ = await thrown { _ = try parseGoogleResponse(jsonData([["a"]]), httpResponse(200), expecting: 2) }
            _ = await thrown { _ = try parseGoogleResponse(jsonData([["a", "b", "c"]]), httpResponse(200), expecting: 2) }
            _ = await thrown { _ = try parseGoogleResponse(jsonData([[String]()]), httpResponse(200), expecting: 1) }
        }
        await test("wrong shapes fail") {
            let bodies: [Any] = [[], [[1, 2]], [["a", NSNull()]], [[["a"]]], ["a"], [NSNull()], [[["a", "b"]]], [1], [["a", 1]]]
            for b in bodies {
                _ = await thrown { _ = try parseGoogleResponse(jsonData(b), httpResponse(200), expecting: 1) }
            }
        }
        await test("top-level JSON that is not an array fails") {
            for raw in ["{\"error\":{\"code\":403}}", "null", "\"text\"", "42", "true"] {
                _ = await thrown { _ = try parseGoogleResponse(Data(raw.utf8), httpResponse(200), expecting: 1) }
            }
        }
        await test("empty, truncated and non-JSON bodies fail") {
            for raw in ["", "[[\"a\"", "<html>unusual traffic</html>", "\u{0}\u{1}", "[[\"a\"]] trailing"] {
                _ = await thrown { _ = try parseGoogleResponse(Data(raw.utf8), httpResponse(200), expecting: 1) }
            }
            _ = await thrown { _ = try parseGoogleResponse(Data([0xFF, 0xFE, 0x00, 0x80]), httpResponse(200), expecting: 1) }
        }
        await test("a non-HTTP response fails with status 0") {
            let r = URLResponse(url: googleURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            let e = await thrown { _ = try parseGoogleResponse(jsonData([["a"]]), r, expecting: 1) }
            check("\(e!)".contains("HTTP 0"), "\(e!)")
        }
        await test("the error message quotes at most 200 bytes of the body") {
            let body = Data(String(repeating: "x", count: 5000).utf8)
            let e = await thrown { _ = try parseGoogleResponse(body, httpResponse(500), expecting: 1) }
            check("\(e!)".count < 300, "\(e!.localizedDescription.count)")
            let big = Data(String(repeating: "日本語", count: 500).utf8)
            let f = await thrown { _ = try parseGoogleResponse(big, httpResponse(500), expecting: 1) }
            check("\(f!)".count < 300)
        }
        await test("a huge response is handled") {
            let list = (0..<20000).map { "translation \($0) &amp; more" }
            let out = try parseGoogleResponse(jsonData([list]), httpResponse(200), expecting: 20000)
            eq(out.count, 20000); eq(out[19999], "translation 19999 & more")
        }
    }

    await suite("googleTranslate") {
        await test("nothing to translate sends nothing") {
            let net = FakeGoogle()
            let r1216 = try await googleTranslate([], from: "ja", to: "en", via: net.transport)
            eq(r1216, [])
            eq(net.requests.count, 0)
        }
        await test("one request for a small batch, results in order") {
            let net = FakeGoogle()
            let r5402 = try await googleTranslate(["a", "b", "c"], from: "ja", to: "en", via: net.transport)
            eq(r5402, ["T:a", "T:b", "T:c"])
            eq(net.requests.count, 1)
        }
        await test("large batches are split and kept in order") {
            let net = FakeGoogle()
            let texts = (0..<250).map { "text \($0)" }
            let out = try await googleTranslate(texts, from: "ja", to: "en", via: net.transport)
            eq(out, texts.map { "T:" + $0 }); eq(net.requests.count, 3)
            eq(net.requests.map { net.texts($0).count }, [100, 100, 50])
        }
        await test("requests are sequential, one chunk at a time") {
            let net = FakeGoogle()
            var inFlight = 0, peak = 0
            net.override = { _, req in
                inFlight += 1; peak = max(peak, inFlight)
                try await Task.sleep(nanoseconds: 1_000_000)
                inFlight -= 1
                let out = net.texts(req).map { "T:" + $0 }
                return (jsonData([out]), httpResponse(200))
            }
            _ = try await googleTranslate((0..<250).map(String.init), from: "ja", to: "en", via: net.transport)
            eq(peak, 1)
        }
        await test("text is escaped going out and unescaped coming back") {
            let net = FakeGoogle()
            net.transform = { $0 }
            let texts = ["a < b & c > d", "&amp; literal", "<script>x</script>"]
            let r3295 = try await googleTranslate(texts, from: "ja", to: "en", via: net.transport)
            eq(r3295, texts)
            eq(net.texts(net.requests[0]), ["a &lt; b &amp; c &gt; d", "&amp;amp; literal", "&lt;script&gt;x&lt;/script&gt;"])
        }
        await test("long Japanese input is translated whole") {
            let net = FakeGoogle()
            let long = String(repeating: "これは長い文章です。", count: 3000)
            let r750 = try await googleTranslate([long], from: "ja", to: "en", via: net.transport)
            eq(r750, ["T:" + long])
        }
        await test("a failing chunk fails the whole call") {
            let net = FakeGoogle()
            net.override = { n, req in
                if n == 1 { return (Data("<html>unusual traffic</html>".utf8), httpResponse(429)) }
                return (jsonData([net.texts(req).map { "T:" + $0 }]), httpResponse(200))
            }
            let e = await thrown { _ = try await googleTranslate((0..<150).map(String.init), from: "ja", to: "en", via: net.transport) }
            check("\(e!)".contains("429"))
            eq(net.requests.count, 2)
        }
        await test("transport errors propagate") {
            let net = FakeGoogle()
            net.override = { _, _ in throw URLError(.notConnectedToInternet) }
            let e = await thrown { _ = try await googleTranslate(["a"], from: "ja", to: "en", via: net.transport) }
            check((e as? URLError)?.code == .notConnectedToInternet)
        }
        await test("a short answer is an error") {
            let net = FakeGoogle()
            net.override = { _, _ in (jsonData([["only one"]]), httpResponse(200)) }
            _ = await thrown { _ = try await googleTranslate(["a", "b"], from: "ja", to: "en", via: net.transport) }
        }
        await test("languages reach the request") {
            let net = FakeGoogle()
            _ = try await googleTranslate(["a"], from: "ko", to: "fr", via: net.transport)
            let inner = (jsonBody(net.requests[0]) as! [Any])[0] as! [Any]
            eq(inner[1] as? String, "ko"); eq(inner[2] as? String, "fr")
        }
    }
}

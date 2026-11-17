import AppKit
import Foundation

func registerCoreTests() {
    suite("Core: argument helpers") {
        test("string reads strings, numbers and ignores empty values and booleans") {
            let a = json(#"{"s":"hi","empty":"","n":5,"f":2.5,"t":true,"f2":false,"null":null}"#)
            expectEqual(a.string("s"), "hi")
            expectEqual(a.string("empty"), nil)
            expectEqual(a.string("n"), "5")
            expectEqual(a.string("f"), "2.5")
            expectEqual(a.string("t"), nil)
            expectEqual(a.string("f2"), nil)
            expectEqual(a.string("null"), nil)
            expectEqual(a.string("missing"), nil)
        }

        test("string keeps surrounding whitespace") {
            expectEqual(json(#"{"s":"  x "}"#).string("s"), "  x ")
        }

        test("double reads numbers and numeric strings, rejects booleans and junk") {
            let a = json(#"{"n":3,"f":1.25,"s":" 7.5 ","bad":"abc","t":true,"e":""}"#)
            expectEqual(a.double("n"), 3)
            expectEqual(a.double("f"), 1.25)
            expectEqual(a.double("s"), 7.5)
            expectEqual(a.double("bad"), nil)
            expectEqual(a.double("t"), nil)
            expectEqual(a.double("e"), nil)
            expectEqual(a.double("missing"), nil)
        }

        test("int truncates toward zero") {
            let a = json(#"{"a":2.9,"b":-2.9,"c":"4","d":"4.7","e":0}"#)
            expectEqual(a.int("a"), 2)
            expectEqual(a.int("b"), -2)
            expectEqual(a.int("c"), 4)
            expectEqual(a.int("d"), 4)
            expectEqual(a.int("e"), 0)
        }

        test("bool accepts booleans and true/1/yes strings") {
            let a = json(#"{"t":true,"f":false,"s1":"true","s2":"YES","s3":"1","s4":"no","s5":"maybe"}"#)
            expectEqual(a.bool("t"), true)
            expectEqual(a.bool("f"), false)
            expectEqual(a.bool("s1"), true)
            expectEqual(a.bool("s2"), true)
            expectEqual(a.bool("s3"), true)
            expectEqual(a.bool("s4"), false)
            expectEqual(a.bool("s5"), false)
            expectEqual(a.bool("missing"), nil)
        }

        test("bool: a JSON number 1 or 0 bridges to a boolean (pinned)") {
            let a = json(#"{"one":1,"zero":0,"two":2}"#)
            expectEqual(a.bool("one"), true)
            expectEqual(a.bool("zero"), false)
            expectEqual(a.bool("two"), nil)
        }
    }

    suite("Core: Content") {
        test("text content JSON") {
            let c = Content.text("hello").json
            expectEqual(c["type"] as? String, "text")
            expectEqual(c["text"] as? String, "hello")
        }

        test("image content JSON is base64 with a mime type") {
            let c = Content.image(Data([0xFF, 0xD8, 0xFF]), mime: "image/jpeg").json
            expectEqual(c["type"] as? String, "image")
            expectEqual(c["data"] as? String, "/9j/")
            expectEqual(c["mimeType"] as? String, "image/jpeg")
        }

        test("ToolError description is its message") {
            expectEqual("\(ToolError("boom"))", "boom")
        }
    }

    suite("Core: Geometry") {
        test("toScreen and toImage are inverses") {
            let g = Geometry(rect: CGRect(x: 100, y: 50, width: 400, height: 300), pixelSize: CGSize(width: 800, height: 600), pid: nil)
            expectEqual(g.pointsPerPixel, 0.5)
            expectEqual(g.toScreen(CGPoint(x: 10, y: 10)), CGPoint(x: 105, y: 55))
            expectEqual(g.toImage(CGPoint(x: 105, y: 55)), CGPoint(x: 10, y: 10))
            let p = CGPoint(x: 333, y: 222)
            expectEqual(g.toImage(g.toScreen(p)), p)
        }

        test("zero pixel width does not divide by zero") {
            let g = Geometry(rect: CGRect(x: 0, y: 0, width: 400, height: 300), pixelSize: .zero, pid: nil)
            expect(g.pointsPerPixel.isFinite)
        }
    }

    suite("Core: Target") {
        test("element returns nil when the argument is absent") {
            installFakeSnapshot(count: 2)
            expect(try Target.element(json("{}")) == nil)
        }

        test("element rejects non-numeric input") {
            installFakeSnapshot(count: 2)
            expectError("Bad element index 'abc'.") { try Target.element(json(#"{"element":"abc"}"#)) }
        }

        test("element needs an observation") {
            expectError("No current observation. Call observe first.") { try Target.element(json(#"{"element":1}"#)) }
        }

        test("element range is 1-based and reports the valid range") {
            installFakeSnapshot(count: 2)
            expectError("Element [0] is not in the latest observe (1-2). Call observe again.") { try Target.element(json(#"{"element":0}"#)) }
            expectError("Element [3] is not in the latest observe (1-2). Call observe again.") { try Target.element(json(#"{"element":3}"#)) }
            let (i, el) = try Target.element(json(#"{"element":2}"#))!
            expectEqual(i, 2)
            expectEqual(el.label, "item 2")
        }

        test("element accepts bracketed and string indices") {
            installFakeSnapshot(count: 12)
            expectEqual(try Target.element(json(#"{"element":"[7]"}"#))!.0, 7)
            expectEqual(try Target.element(json(#"{"element":"12"}"#))!.0, 12)
            expectEqual(try Target.element(json(#"{"element":"3abc"}"#))!.0, 3)
        }

        test("element strips every non-digit, so -1 and 1.5 resolve to 1 and 15 (pinned)") {
            installFakeSnapshot(count: 20)
            expectEqual(try Target.element(json(#"{"element":-1}"#))!.0, 1)
            expectEqual(try Target.element(json(#"{"element":1.5}"#))!.0, 15)
        }

        test("element with an all-digit value beyond Int is a bad index") {
            installFakeSnapshot(count: 2)
            expectError("Bad element index '99999999999999999999'.") { try Target.element(json(#"{"element":"99999999999999999999"}"#)) }
        }

        test("element with no elements reports an empty range") {
            installFakeSnapshot(count: 0)
            expectError("Element [1] is not in the latest observe (1-0). Call observe again.") { try Target.element(json(#"{"element":1}"#)) }
        }

        test("screenPoint needs a screenshot") {
            expectError("No screenshot yet. Call observe or screenshot first.") { try Target.screenPoint(1, 1) }
        }

        test("screenPoint rejects points outside the screenshot") {
            installFakeGeometry(width: 800, height: 600)
            expectError("(-1,5) is outside the latest screenshot (800x600).") { try Target.screenPoint(-1, 5) }
            expectError("(5,-1) is outside the latest screenshot (800x600).") { try Target.screenPoint(5, -1) }
            expectError("(801,5) is outside the latest screenshot (800x600).") { try Target.screenPoint(801, 5) }
            expectError("(5,601) is outside the latest screenshot (800x600).") { try Target.screenPoint(5, 601) }
        }

        test("screenPoint maps screenshot pixels to screen points") {
            State.geometry = Geometry(rect: CGRect(x: 100, y: 50, width: 400, height: 300), pixelSize: CGSize(width: 800, height: 600), pid: nil)
            expectEqual(try Target.screenPoint(0, 0), CGPoint(x: 100, y: 50))
            expectEqual(try Target.screenPoint(800, 600), CGPoint(x: 500, y: 350))
            expectEqual(try Target.screenPoint(10, 10), CGPoint(x: 105, y: 55))
        }

        test("describe formats screenshot pixels, or nothing without a screenshot") {
            expectEqual(Target.describe(CGPoint(x: 5, y: 5)), "")
            State.geometry = Geometry(rect: CGRect(x: 100, y: 50, width: 400, height: 300), pixelSize: CGSize(width: 800, height: 600), pid: nil)
            expectEqual(Target.describe(CGPoint(x: 105, y: 55)), "(10,10)")
        }

        test("point returns nil when neither an element nor both coordinates are given") {
            installFakeGeometry()
            expect(try Target.point(json(#"{"x":5}"#), element: "element", x: "x", y: "y") == nil)
            expect(try Target.point(json("{}"), element: "element", x: "x", y: "y") == nil)
        }

        test("point maps coordinates under custom argument names") {
            installFakeGeometry()
            let p = try Target.point(json(#"{"from_x":10,"from_y":20}"#), element: "from_element", x: "from_x", y: "from_y")
            expectEqual(p, CGPoint(x: 10, y: 20))
        }

        test("point with an element from a vanished app asks for a new observe") {
            installFakeSnapshot(count: 1)
            expectError("No current observation. Call observe first.") {
                try Target.point(json(#"{"element":1}"#), element: "element", x: "x", y: "y")
            }
        }
    }
}

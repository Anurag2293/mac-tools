import Foundation

private let macUseDir: URL? = ProcessInfo.processInfo.environment["MAC_USE_DIR"].map { URL(fileURLWithPath: $0) }

private func read(_ name: String) -> String? {
    macUseDir.flatMap { try? String(contentsOf: $0.appendingPathComponent(name), encoding: .utf8) }
}

private func normalized(_ text: String) -> String {
    text.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
        .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func tableTools(in markdown: String) -> [String] {
    guard let start = markdown.range(of: "\n## Tools\n") else { return [] }
    let section = markdown[start.upperBound...]
    var names: [String] = []
    for line in section.split(separator: "\n") {
        if line.hasPrefix("## ") { break }
        guard line.hasPrefix("| `"), let end = line.dropFirst(3).firstIndex(of: "`") else { continue }
        names.append(String(line.dropFirst(3)[..<end]))
    }
    return names
}

private func positions(of markers: [String], in text: String) -> [Int?] {
    markers.map { m in text.range(of: m).map { text.distance(from: text.startIndex, to: $0.lowerBound) } }
}

func registerStandardTests() {
    suite("Standard") {
        test("STANDARD.md and the README are readable from MAC_USE_DIR") {
            expect(read("STANDARD.md") != nil, "set MAC_USE_DIR to the mac-use folder")
            expect(read("README.md") != nil)
        }

        test("both texts name the same standard and version") {
            let md = read("STANDARD.md") ?? ""
            expect(md.hasPrefix("# Local Computer Use Standard v1\n"))
            expectContains(Standard.instructions, "Follow the Local Computer Use Standard v1:")
            expect(!Standard.version.isEmpty)
        }

        test("the tool table in STANDARD.md lists exactly the registered tools, in order") {
            expectEqual(tableTools(in: read("STANDARD.md") ?? ""), Tools.all.map(\.name))
        }

        test("the route preference order is the same in both texts") {
            let md = normalized(read("STANDARD.md") ?? "")
            let ladderStart = md.range(of: "pick the least-invasive route")?.lowerBound ?? md.startIndex
            let ladder = String(md[ladderStart...])
            let mdOrder = positions(of: ["existing cli, api", "run_script", "menu", "element actions", "find_text", "raw x,y"], in: ladder)
            let swiftOrder = positions(of: ["existing cli, api", "run_script", "menu", "element actions", "find_text", "raw x,y"], in: normalized(Standard.instructions))
            for (name, order) in [("STANDARD.md", mdOrder), ("Standard.swift", swiftOrder)] {
                expect(!order.contains { $0 == nil }, "\(name) is missing a rung of the ladder: \(order)")
                let values = order.compactMap { $0 }
                expectEqual(values, values.sorted(), "\(name) lists the rungs out of order")
            }
        }

        test("both texts carry the same safety rules") {
            let md = normalized(read("STANDARD.md") ?? "")
            let swift = normalized(Standard.instructions)
            let shared: [[String]] = [
                ["deny_apps"], ["top-left"], ["mac-use pause"], ["actions.jsonl"], ["2fa codes"], ["payment details"],
                ["never open a browser window on the desktop for a web page"], ["t3 code"], ["playwright"],
                ["irreversible or outward-facing"], ["sending messages or email"], ["granting permission"],
                ["only the user"], ["latest observe"], ["re-observe whenever the ui may have changed"],
                ["tool results only say an event was sent", "tool result only means the event was sent"],
                ["screenshot: false", "screenshot false"],
            ]
            for variants in shared {
                expect(variants.contains { md.contains($0) }, "STANDARD.md lacks '\(variants[0])'")
                expect(variants.contains { swift.contains($0) }, "Standard.swift lacks '\(variants[0])'")
            }
        }

        test("every tool or setting named in the instructions exists") {
            let words = Standard.instructions.split { !($0.isLetter || $0 == "_") }.map(String.init).filter { $0.contains("_") }
            let known = Set(Tools.all.map(\.name)).union(["deny_apps", "allow_apps"])
            for word in Set(words) { expect(known.contains(word), "'\(word)' is not a tool or config key") }
        }

        test("the action log path in both texts matches the code") {
            let md = read("STANDARD.md") ?? ""
            expectContains(md, "~/Library/Logs/mac-use/actions.jsonl")
            expectContains(Standard.instructions, "~/Library/Logs/mac-use/actions.jsonl")
            expect(Paths.actionLog.path.hasSuffix("Library/Logs/mac-use/actions.jsonl"))
        }

        test("the README file table matches the code's paths") {
            let readme = read("README.md") ?? ""
            expectContains(readme, "~/Library/Application Support/mac-use/config.json")
            expectContains(readme, "~/Library/Application Support/mac-use/PAUSED")
            expectContains(readme, "~/Library/Logs/mac-use/actions.jsonl")
            expectContains(readme, "~/Library/Caches/mac-use/")
            expect(Paths.config.path.hasSuffix("Library/Application Support/mac-use/config.json"))
            expect(Paths.paused.path.hasSuffix("Library/Application Support/mac-use/PAUSED"))
        }

        test("the instructions are numbered 1 to 8 and each rule is on one line") {
            let lines = Standard.instructions.split(separator: "\n").map(String.init)
            let numbered = lines.filter { $0.first?.isNumber == true }
            expectEqual(numbered.count, 8)
            for (i, line) in numbered.enumerated() { expect(line.hasPrefix("\(i + 1). "), "rule \(i + 1) is mislabeled: \(line)") }
        }

        test("the instructions have no leading indentation from the source file") {
            for line in Standard.instructions.split(separator: "\n") { expect(!line.hasPrefix(" "), "indented line: \(line)") }
            expect(!Standard.instructions.hasSuffix("\n"))
        }
    }
}

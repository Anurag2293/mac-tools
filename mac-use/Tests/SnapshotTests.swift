import AppKit
import ApplicationServices
import Foundation

func registerSnapshotTests() {
    let geometry = Geometry(rect: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 800, height: 600), pid: nil)

    suite("Snapshot: text cleanup") {
        test("clean replaces double quotes with apostrophes") {
            expectEqual(SnapshotBuilder.clean(#"say "hi""#, 100), "say 'hi'")
        }

        test("clean flattens newlines and collapses spaces") {
            expectEqual(SnapshotBuilder.clean("a\nb\r\nc", 100), "a b c")
            expectEqual(SnapshotBuilder.clean("  a    b   ", 100), "a b")
            expectEqual(SnapshotBuilder.clean("\n\n", 100), "")
        }

        test("clean truncates past the limit with an ellipsis and keeps text at the limit") {
            expectEqual(SnapshotBuilder.clean("abcdef", 3), "abc…")
            expectEqual(SnapshotBuilder.clean("abc", 3), "abc")
            expectEqual(SnapshotBuilder.clean("", 3), "")
        }

        test("clean limits count characters, not bytes") {
            expectEqual(SnapshotBuilder.clean("日本語テキスト", 3), "日本語…")
            expectEqual(SnapshotBuilder.clean("👍🏽👍🏽👍🏽", 2), "👍🏽👍🏽…")
        }

        test("nonEmpty trims and drops blanks") {
            expectEqual(SnapshotBuilder.nonEmpty(nil), nil)
            expectEqual(SnapshotBuilder.nonEmpty(""), nil)
            expectEqual(SnapshotBuilder.nonEmpty("  \n\t"), nil)
            expectEqual(SnapshotBuilder.nonEmpty("  a b \n"), "a b")
        }
    }

    suite("Snapshot: role and value display") {
        test("roles lose the AX prefix and are lowercased") {
            expectEqual(SnapshotBuilder.displayRole("AXButton", nil), "button")
            expectEqual(SnapshotBuilder.displayRole("AXPopUpButton", nil), "popupbutton")
            expectEqual(SnapshotBuilder.displayRole("Custom", nil), "custom")
        }

        test("only the named subroles replace the role") {
            expectEqual(SnapshotBuilder.displayRole("AXButton", "AXCloseButton"), "closebutton")
            expectEqual(SnapshotBuilder.displayRole("AXTextField", "AXSearchField"), "searchfield")
            expectEqual(SnapshotBuilder.displayRole("AXTextField", "AXSecureTextField"), "securetextfield")
            expectEqual(SnapshotBuilder.displayRole("AXCheckBox", "AXSwitch"), "switch")
            expectEqual(SnapshotBuilder.displayRole("AXButton", "AXUnknownSubrole"), "button")
            expectEqual(SnapshotBuilder.displayRole("AXGroup", "AXLandmarkMain"), "group")
        }

        test("secure fields never show their value") {
            expectEqual(SnapshotBuilder.displayValue("AXTextField", "AXSecureTextField", "hunter2"), "•••")
            expectEqual(SnapshotBuilder.displayValue("AXTextField", "AXSecureTextField", ""), nil)
            expectEqual(SnapshotBuilder.displayValue("AXTextField", "AXSecureTextField", nil), nil)
        }

        test("text-like values are shown, truncated at 120") {
            expectEqual(SnapshotBuilder.displayValue("AXTextField", nil, "hello"), "hello")
            expectEqual(SnapshotBuilder.displayValue("AXTextArea", nil, ""), nil)
            expectEqual(SnapshotBuilder.displayValue("AXComboBox", nil, "x\ny"), "x y")
            expectEqual(SnapshotBuilder.displayValue("AXSearchField", nil, String(repeating: "z", count: 130)), String(repeating: "z", count: 120) + "…")
        }

        test("checkbox and radio values become on or off") {
            expectEqual(SnapshotBuilder.displayValue("AXCheckBox", nil, "1"), "on")
            expectEqual(SnapshotBuilder.displayValue("AXCheckBox", nil, "0"), "off")
            expectEqual(SnapshotBuilder.displayValue("AXRadioButton", nil, "1"), "on")
            expectEqual(SnapshotBuilder.displayValue("AXCheckBox", nil, "2"), "2")
            expectEqual(SnapshotBuilder.displayValue("AXCheckBox", nil, String(repeating: "m", count: 40)), String(repeating: "m", count: 30) + "…")
        }

        test("sliders, pop-ups and date fields show their value, truncated at 60") {
            for role in ["AXSlider", "AXIncrementor", "AXPopUpButton", "AXDateField", "AXTimeField"] {
                expectEqual(SnapshotBuilder.displayValue(role, nil, "42"), "42", role)
                expectEqual(SnapshotBuilder.displayValue(role, nil, ""), nil, role)
            }
            expectEqual(SnapshotBuilder.displayValue("AXSlider", nil, String(repeating: "9", count: 70)), String(repeating: "9", count: 60) + "…")
        }

        test("other roles show no value") {
            expectEqual(SnapshotBuilder.displayValue("AXButton", nil, "x"), nil)
            expectEqual(SnapshotBuilder.displayValue("AXStaticText", nil, "x"), nil)
            expectEqual(SnapshotBuilder.displayValue("AXTextField", nil, nil), nil)
        }
    }

    suite("Snapshot: element lines") {
        test("a plain button line has index, role, label and center in screenshot pixels") {
            let e = fakeElement("AXButton", label: "OK", frame: CGRect(x: 100, y: 200, width: 40, height: 20))
            expectEqual(SnapshotBuilder.line(1, e, geometry), #"[1] button "OK" (120,210)"#)
        }

        test("an unlabeled element omits the label") {
            let e = fakeElement("AXSlider", value: "5")
            expectEqual(SnapshotBuilder.line(4, e, geometry), #"[4] slider value="5" (120,210)"#)
        }

        test("checkboxes and radio buttons print their state without value=") {
            expectEqual(SnapshotBuilder.line(2, fakeElement("AXCheckBox", label: "Remember", value: "1"), geometry), #"[2] checkbox "Remember" on (120,210)"#)
            expectEqual(SnapshotBuilder.line(3, fakeElement("AXRadioButton", label: "A", value: "0"), geometry), #"[3] radiobutton "A" off (120,210)"#)
        }

        test("text fields print value=") {
            expectEqual(SnapshotBuilder.line(5, fakeElement("AXTextField", label: "Name", value: "Anurag"), geometry), #"[5] textfield "Name" value="Anurag" (120,210)"#)
        }

        test("a secure field line never contains the secret") {
            let line = SnapshotBuilder.line(6, fakeElement("AXTextField", label: "Password", value: "hunter2", sub: "AXSecureTextField"), geometry)
            expectEqual(line, #"[6] securetextfield "Password" value="•••" (120,210)"#)
            expectNotContains(line, "hunter2")
        }

        test("focused and disabled flags come last, in that order") {
            let e = fakeElement("AXButton", label: "Go", enabled: false, focused: true)
            expectEqual(SnapshotBuilder.line(7, e, geometry), #"[7] button "Go" (120,210) focused disabled"#)
        }

        test("an element without a frame has no coordinates") {
            expectEqual(SnapshotBuilder.line(8, fakeElement("AXLink", label: "Docs", frame: nil), geometry), #"[8] link "Docs""#)
        }

        test("coordinates are scaled into screenshot pixels") {
            let g = Geometry(rect: CGRect(x: 100, y: 50, width: 400, height: 300), pixelSize: CGSize(width: 800, height: 600), pid: nil)
            let e = fakeElement("AXButton", label: "Z", frame: CGRect(x: 200, y: 100, width: 100, height: 50))
            expectEqual(SnapshotBuilder.line(9, e, g), #"[9] button "Z" (300,150)"#)
        }

        test("summary prefers the label") {
            expectEqual(fakeElement("AXButton", label: "OK").summary, #"button "OK""#)
            expectEqual(fakeElement("AXButton").summary, "button")
        }
    }

    suite("Snapshot: constants") {
        test("fetchNames order matches the indices SnapshotBuilder.build reads") {
            let expected = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                            kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
                            kAXFocusedAttribute, kAXChildrenAttribute, "AXPlaceholderValue", kAXHelpAttribute]
            expectEqual(SnapshotBuilder.fetchNames, expected)
        }

        test("every pressable role is interactive") {
            expect(Observe.pressable.isSubset(of: SnapshotBuilder.interactive))
        }

        test("pop-up and menu buttons are not pressable, so they get a real click") {
            expect(!Observe.pressable.contains("AXPopUpButton"))
            expect(!Observe.pressable.contains("AXMenuButton"))
        }

        test("snapshots keep their pid, elements and overflow flag") {
            let s = Snapshot(pid: 42, elements: [fakeElement()], more: true)
            expectEqual(s.pid, 42)
            expectEqual(s.elements.count, 1)
            expect(s.more)
        }
    }
}

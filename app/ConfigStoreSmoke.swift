import Foundation

@main
struct ConfigStoreSmoke {
    static func main() async throws {
        try await MainActor.run {
            let path = ProcessInfo.processInfo.environment["PANDA_CONFIG"]!
            let store = PandaConfigStore()
            precondition(store.path == path)

            let focusLeft = store.bindings.first { $0.id == "focus_left" }!
            store.update(focusLeft, chord: "alt+h")
            precondition(store.errorMessage == nil)
            precondition(store.bindings.first { $0.id == "focus_left" }?.chord == "option+h")

            let focusDown = store.bindings.first { $0.id == "focus_down" }!
            store.update(focusDown, chord: "option+h")
            precondition(store.errorMessage?.contains("already assigned") == true)

            store.setLayout("grid")
            store.setBorderEnabled(false)
            store.reload()
            precondition(store.layout == "grid")
            precondition(!store.borderEnabled)

            let saved = try String(contentsOfFile: path, encoding: .utf8)
            precondition(saved.contains("focus_left = \"option+h\""))
            precondition(saved.contains("layout = \"grid\""))
            precondition(saved.contains("border = false"))

            try Self.fixture.write(toFile: path, atomically: true, encoding: .utf8)
            store.reload()
            let workspaceOne = store.bindings.first { $0.id == "switch_1" }!
            precondition(workspaceOne.chord == "cmd+1")
            precondition(workspaceOne.section == "shortcuts" && workspaceOne.configKey == "desktop_1")
            store.update(workspaceOne, chord: "cmd+2")
            let overrideText = try String(contentsOfFile: path, encoding: .utf8)
            precondition(overrideText.contains("desktop_1 = \"cmd+2\""))

            try "return make_config()\n".write(toFile: path, atomically: true, encoding: .utf8)
            store.reload()
            store.setLayout("bsp")
            precondition(store.errorMessage?.contains("dynamic Lua") == true)
            let dynamicText = try String(contentsOfFile: path, encoding: .utf8)
            precondition(dynamicText == "return make_config()\n")

            try Self.fixture.write(toFile: path, atomically: true, encoding: .utf8)
            store.reload()
            try "-- external edit\n\(Self.fixture)".write(toFile: path, atomically: true, encoding: .utf8)
            store.setLayout("master-stack")
            precondition(store.errorMessage?.contains("changed in another app") == true)
            let externallyEditedText = try String(contentsOfFile: path, encoding: .utf8)
            precondition(externallyEditedText.hasPrefix("-- external edit"))
        }
    }

    private static let fixture = """
    -- preserve this comment
    return {
      layout = "bsp",
      border = true,
      desktop = {
        switch_1 = "option+1",
      },
      shortcuts = {
        focus_left = "alt+h",
        desktop_1 = "cmd+1",
      },
    }
    """
}

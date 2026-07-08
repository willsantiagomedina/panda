import Foundation

struct PandaBinding: Identifiable, Hashable {
    let id: String
    let title: String
    let section: String
    let configKey: String
    let isWorkspace: Bool
    let defaultChord: String?
    var chord: String
}

@MainActor
final class PandaConfigStore: ObservableObject {
    @Published var bindings: [PandaBinding] = []
    @Published var errorMessage: String?
    @Published var savedMessage: String?
    @Published var scope = "all-main-display"
    @Published var layout = "bsp"
    @Published var borderEnabled = true

    let path: String
    private var fileSignature: String?
    private var watchTimer: Timer?
    private var readError: String?

    init() {
        if let override = ProcessInfo.processInfo.environment["PANDA_CONFIG"], !override.isEmpty {
            path = NSString(string: override).expandingTildeInPath
        } else {
            path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/panda/config.lua").path
        }
        reload()
        fileSignature = currentFileSignature()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForExternalChange() }
        }
    }

    func reload() {
        readError = nil
        let text = readText()
        let values = parseValues(text)
        scope = rootString("scope", in: text) ?? "all-main-display"
        layout = rootString("layout", in: text) ?? "bsp"
        borderEnabled = rootBool("border", in: text) ?? true
        bindings = Self.definitions.map { definition in
            PandaBinding(
                id: definition.id,
                title: definition.title,
                section: values[definition.id]?.section ?? definition.section,
                configKey: values[definition.id]?.key ?? definition.id,
                isWorkspace: definition.section == "desktop",
                defaultChord: definition.defaultChord,
                chord: values[definition.id]?.chord ?? definition.defaultChord ?? ""
            )
        }
        fileSignature = currentFileSignature()
        errorMessage = readError
    }

    func setScope(_ value: String) { if updateRoot("scope", value: "\"\(value)\"") { scope = value } }
    func setLayout(_ value: String) { if updateRoot("layout", value: "\"\(value)\"") { layout = value } }
    func setBorderEnabled(_ value: Bool) { if updateRoot("border", value: value ? "true" : "false") { borderEnabled = value } }

    func update(_ binding: PandaBinding, chord rawChord: String) {
        let chord = normalize(rawChord)
        guard chord.isEmpty || isValid(chord) else {
            errorMessage = "Use a chord such as option+shift+1 or alt+h."
            return
        }
        if !chord.isEmpty, let conflict = bindings.first(where: { $0.id != binding.id && normalize($0.chord) == chord }) {
            errorMessage = "That shortcut is already assigned to \(conflict.title)."
            return
        }
        do {
            try writeValue(section: binding.section, key: binding.configKey, value: chord.isEmpty ? nil : chord)
            if let index = bindings.firstIndex(where: { $0.id == binding.id }) { bindings[index].chord = chord }
            errorMessage = nil
            savedMessage = "Saved"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetAll() {
        do {
            var text = readText()
            for binding in bindings {
                text = try editing(text: text, section: binding.section, key: binding.configKey, value: binding.defaultChord)
            }
            try atomicWrite(text)
            reload()
            applyRuntime()
            savedMessage = "Restored runtime defaults"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func conflicts(for binding: PandaBinding) -> Bool {
        let chord = normalize(binding.chord)
        return !chord.isEmpty && bindings.contains { $0.id != binding.id && normalize($0.chord) == chord }
    }

    private func readText() -> String {
        guard FileManager.default.fileExists(atPath: path) else { return Self.starterConfig }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            readError = "Panda could not read this config: \(error.localizedDescription)"
            return ""
        }
    }

    private struct ParsedBinding {
        let chord: String
        let section: String
        let key: String
    }

    private func parseValues(_ text: String) -> [String: ParsedBinding] {
        var result: [String: ParsedBinding] = [:]
        var section = "root"
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "--.*$", with: "", options: .regularExpression)
            if let match = line.firstMatch(of: /^\s*(desktop|shortcuts)\s*=\s*\{/) {
                section = String(match.1)
                continue
            }
            if section != "root", line.firstMatch(of: /^\s*\}/) != nil { section = "root"; continue }
            guard section == "desktop" || section == "shortcuts" else { continue }
            if let match = line.firstMatch(of: #/^\s*([A-Za-z0-9_-]+)\s*=\s*["']([^"']+)["']/#) {
                let key = String(match.1)
                let logicalKey = section == "shortcuts" ? logicalAction(forShortcutKey: key) : key
                if Self.definitionIds.contains(logicalKey) {
                    result[logicalKey] = ParsedBinding(chord: normalize(String(match.2)), section: section, key: key)
                }
            }
        }
        return result
    }

    private func logicalAction(forShortcutKey key: String) -> String {
        if key == "desktop_prev" { return "switch_prev" }
        if key == "desktop_next" { return "switch_next" }
        if key == "desktop_move_prev" || key == "move_desktop_prev" { return "move_prev" }
        if key == "desktop_move_next" || key == "move_desktop_next" { return "move_next" }
        if let match = key.firstMatch(of: /^desktop_([1-9])$/) { return "switch_\(match.1)" }
        if let match = key.firstMatch(of: /^(?:desktop_move|move_desktop)_([1-9])$/) { return "move_\(match.1)" }
        return key
    }

    private func writeValue(section: String, key: String, value: String?) throws {
        let updated = try editing(text: readText(), section: section, key: key, value: value)
        try atomicWrite(updated)
        applyRuntime()
    }

    @discardableResult private func updateRoot(_ key: String, value: String) -> Bool {
        do {
            let text = readText()
            guard isSafelyEditable(text) else {
                throw NSError(domain: "PandaConfig", code: 1, userInfo: [NSLocalizedDescriptionKey: "This config uses dynamic Lua that Panda Settings cannot safely rewrite."])
            }
            var lines = text.components(separatedBy: "\n")
            let pattern = "^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*="
            if let index = lines.indices.first(where: { lines[$0].range(of: pattern, options: .regularExpression) != nil }) {
                lines[index] = "  \(key) = \(value),"
            } else if let end = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("}") }) {
                lines.insert("  \(key) = \(value),", at: end)
            } else {
                throw NSError(domain: "PandaConfig", code: 1, userInfo: [NSLocalizedDescriptionKey: "The config structure is not safe to edit visually."])
            }
            try atomicWrite(lines.joined(separator: "\n"))
            applyRuntime()
            errorMessage = nil
            savedMessage = "Saved"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func rootString(_ key: String, in text: String) -> String? {
        let pattern = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func rootBool(_ key: String, in text: String) -> Bool? {
        let pattern = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*(true|false)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return text[range] == "true"
    }

    private func editing(text: String, section: String, key: String, value: String?) throws -> String {
        guard isSafelyEditable(text) else {
            throw NSError(domain: "PandaConfig", code: 1, userInfo: [NSLocalizedDescriptionKey: "This config uses dynamic Lua that Panda Settings cannot safely rewrite. Continue editing it in your text editor."])
        }
        var lines = text.components(separatedBy: "\n")
        var sectionStart: Int?
        var sectionEnd: Int?
        var depth = 0
        for index in lines.indices {
            let stripped = lines[index].replacingOccurrences(of: "--.*$", with: "", options: .regularExpression)
            if sectionStart == nil, stripped.range(of: "^\\s*\(section)\\s*=\\s*\\{", options: .regularExpression) != nil {
                sectionStart = index
                depth = 1
                continue
            }
            guard sectionStart != nil else { continue }
            depth += stripped.filter { $0 == "{" }.count
            depth -= stripped.filter { $0 == "}" }.count
            if depth <= 0 { sectionEnd = index; break }
        }

        if let start = sectionStart, let end = sectionEnd {
            let pattern = "^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*="
            if let index = (start + 1..<end).first(where: { lines[$0].range(of: pattern, options: .regularExpression) != nil }) {
                if let value { lines[index] = "    \(key) = \"\(value)\"," } else { lines.remove(at: index) }
            } else if let value {
                lines.insert("    \(key) = \"\(value)\",", at: end)
            }
        } else if let value {
            let sectionAssignment = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: section))\\s*="
            if text.range(of: sectionAssignment, options: .regularExpression) != nil {
                throw NSError(domain: "PandaConfig", code: 2, userInfo: [NSLocalizedDescriptionKey: "The \(section) section is dynamic and cannot be edited safely."])
            }
            guard let rootEnd = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("}") }) else {
                throw NSError(domain: "PandaConfig", code: 1, userInfo: [NSLocalizedDescriptionKey: "The config structure is not safe to edit visually."])
            }
            lines.insert(contentsOf: ["", "  \(section) = {", "    \(key) = \"\(value)\",", "  },"], at: rootEnd)
        }
        return lines.joined(separator: "\n")
    }

    private func atomicWrite(_ text: String) throws {
        let url = URL(fileURLWithPath: path)
        guard currentFileSignature() == fileSignature else {
            reload()
            fileSignature = currentFileSignature()
            throw NSError(domain: "PandaConfig", code: 3, userInfo: [NSLocalizedDescriptionKey: "The config changed in another app. Panda reloaded it instead of overwriting those changes."])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".config.lua.panda-\(UUID().uuidString)")
        try text.data(using: .utf8)!.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("panda-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        fileSignature = currentFileSignature()
    }

    private func checkForExternalChange() {
        let signature = currentFileSignature()
        guard signature != fileSignature else { return }
        fileSignature = signature
        reload()
        savedMessage = "Reloaded after an external config change"
    }

    private func currentFileSignature() -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = attributes[.size] as? NSNumber ?? 0
        return "\(date):\(size)"
    }

    private func isSafelyEditable(_ text: String) -> Bool {
        guard text.range(of: "(?m)^\\s*return\\s*\\{", options: .regularExpression) != nil else { return false }
        var depth = 0
        var quote: Character?
        var previous: Character?
        for character in text {
            if let activeQuote = quote {
                if character == activeQuote && previous != "\\" { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth < 0 { return false }
            }
            previous = character
        }
        return depth == 0 && quote == nil
    }

    private func applyRuntime() {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/panda-cli")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["reload"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 && Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
                let fallback = Process()
                fallback.executableURL = executable
                fallback.arguments = ["install-daemon"]
                fallback.standardOutput = FileHandle.nullDevice
                fallback.standardError = FileHandle.nullDevice
                try? fallback.run()
                fallback.waitUntilExit()
            }
        }
    }

    private func normalize(_ chord: String) -> String {
        let tokens = chord.lowercased().replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map { token in
                switch token {
                case "command", "super": "cmd"
                case "control", "ctl": "ctrl"
                case "opt", "alt": "option"
                default: String(token)
                }
            }
        guard let key = tokens.last else { return "" }
        let modifiers = Set(tokens.dropLast())
        let ordered = ["cmd", "ctrl", "option", "shift"].filter { modifiers.contains($0) }
        return (ordered + [key]).joined(separator: "+")
    }

    private func isValid(_ chord: String) -> Bool {
        let parts = chord.split(separator: "+")
        guard parts.count >= 2, let key = parts.last, !key.isEmpty else { return false }
        let modifiers = Set(parts.dropLast().map(String.init))
        return !modifiers.isEmpty && modifiers.allSatisfy { ["cmd", "ctrl", "option", "alt", "shift"].contains($0) }
    }

    private static let definitions: [(id: String, title: String, section: String, defaultChord: String?)] = {
        var rows: [(String, String, String, String?)] = [
            ("focus_left", "Focus left", "shortcuts", nil), ("focus_down", "Focus down", "shortcuts", nil),
            ("focus_up", "Focus up", "shortcuts", nil), ("focus_right", "Focus right", "shortcuts", nil),
            ("swap_left", "Swap left", "shortcuts", nil), ("swap_down", "Swap down", "shortcuts", nil),
            ("swap_up", "Swap up", "shortcuts", nil), ("swap_right", "Swap right", "shortcuts", nil),
            ("switch_prev", "Previous workspace", "desktop", "ctrl+left"), ("switch_next", "Next workspace", "desktop", "ctrl+right"),
            ("move_prev", "Move to previous workspace", "desktop", "ctrl+shift+left"), ("move_next", "Move to next workspace", "desktop", "ctrl+shift+right")
        ]
        for number in 1...9 {
            rows.append(("switch_\(number)", "Switch to workspace \(number)", "desktop", "option+\(number)"))
            rows.append(("move_\(number)", "Move window to workspace \(number)", "desktop", "option+shift+\(number)"))
        }
        rows.append(("border_toggle", "Toggle borders", "shortcuts", nil))
        return rows
    }()
    private static let definitionIds = Set(definitions.map(\.id))

    private static let starterConfig = """
    -- panda config (managed by Panda Settings; terminal edits remain supported)
    return {
      scope = "all-main-display",
      layout = "bsp",
      border = true,
    }
    """
}

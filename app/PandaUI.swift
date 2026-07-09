import AppKit
import ApplicationServices
import Combine
import Darwin
import ServiceManagement
import SwiftUI

private enum SettingsRoute: String, CaseIterable, Identifiable {
    case general = "General"
    case keybinds = "Keybinds"
    case layout = "Layout"
    case appearance = "Appearance"
    case workspaces = "Workspaces"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .keybinds: "keyboard"
        case .layout: "rectangle.3.group"
        case .appearance: "paintbrush"
        case .workspaces: "square.grid.3x3"
        }
    }
}

@MainActor
private final class PandaModel: ObservableObject {
    @Published var route: SettingsRoute = .general
    @Published var configPath = "Loading…"
    @Published var configStatus = "Checking configuration"
    @Published var daemonStatus = "Checking Panda"
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var menuBarAnimationEnabled = UserDefaults.standard.object(forKey: "menuBarAnimationEnabled") as? Bool ?? true
    let configStore = PandaConfigStore()

    init() { refresh() }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        Task { [weak self] in
            let results = await Task.detached {
                (Self.runCLI(["config"]), Self.runCLI(["daemon-status"]))
            }.value
            guard let self else { return }
            let config = results.0
            let daemon = results.1
            let lines = config.output.split(separator: "\n")
            if let line = lines.first(where: { $0.hasPrefix("config: ") }) {
                self.configPath = String(line.dropFirst("config: ".count))
            }
            self.configStatus = config.succeeded ? "Configuration loaded" : "Configuration needs attention"
            self.daemonStatus = daemon.succeeded ? "Panda is running" : "Panda is stopped"
        }
    }

    func ensureDaemonRunning() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }

        Task { [weak self] in
            let isRunning = await Task.detached {
                Self.runCLI(["daemon-status"]).succeeded
            }.value
            if !isRunning {
                _ = await Task.detached {
                    Self.runCLI(["install-daemon"])
                }.value
            }
            self?.refresh()
        }
    }

    func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openConfig() {
        let url = URL(fileURLWithPath: configPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            NSAlert(error: error).runModal()
        }
    }

    func setMenuBarAnimationEnabled(_ enabled: Bool) {
        menuBarAnimationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "menuBarAnimationEnabled")
    }

    func reloadConfig() {
        configStore.reload()
        if !Self.runCLI(["reload"]).succeeded && Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
            _ = Self.runCLI(["install-daemon"])
        }
        refresh()
    }
    func restart() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            showInstallRequiredAlert(action: "restart the daemon")
            return
        }
        _ = Self.runCLI(["install-daemon"])
        refresh()
    }
    func stop() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }
        _ = Self.runCLI(["uninstall-daemon"])
        refresh()
    }

    private func showInstallRequiredAlert(action: String) {
        let alert = NSAlert()
        alert.messageText = "Install Panda first"
        alert.informativeText = "Move Panda to Applications before trying to \(action)."
        alert.runModal()
    }

    nonisolated private static func runCLI(_ arguments: [String]) -> (succeeded: Bool, output: String) {
        let process = Process()
        let pipe = Pipe()
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/panda-cli")
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

private struct SettingsRootView: View {
    @ObservedObject var model: PandaModel

    var body: some View {
        NavigationSplitView {
            List(SettingsRoute.allCases, selection: $model.route) { route in
                Label(route.rawValue, systemImage: route.icon).tag(route)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.configStore.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                }
                Group {
                    switch model.route {
                    case .general: GeneralView(model: model)
                    case .keybinds: KeybindsView(model: model)
                    case .layout: LayoutSettings(store: model.configStore)
                    case .appearance: AppearanceSettings(store: model.configStore)
                    case .workspaces: WorkspaceSettings(model: model)
                    }
                }
            }
            .frame(minWidth: 560, minHeight: 440)
        }
    }
}

private struct WorkspaceSettings: View {
    @ObservedObject var model: PandaModel

    var body: some View {
        Form {
            Section("Virtual workspaces") {
                Text("Panda manages nine lightweight workspaces independently of Mission Control. Workspace assignments remain in memory until the daemon restarts.")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(1...9, id: \.self) { number in
                        VStack(spacing: 6) {
                            Text("\(number)").font(.title2.bold())
                            Text("⌥\(number)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Keyboard control") {
                LabeledContent("Switch workspace", value: "Option + 1…9")
                LabeledContent("Move focused window", value: "Option + Shift + 1…9")
                Button("Customize Workspace Keybinds") { model.route = .keybinds }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Workspaces")
    }
}

private struct LayoutSettings: View {
    @ObservedObject var store: PandaConfigStore
    var body: some View {
        Form {
            Section("Default layout") {
                Picker("Layout", selection: Binding(get: { store.layout }, set: { store.setLayout($0) })) {
                    Text("BSP").tag("bsp")
                    Text("Grid").tag("grid")
                    Text("Master Stack").tag("master-stack")
                }.pickerStyle(.radioGroup)
            }
            Section("Window scope") {
                Picker("Tile", selection: Binding(get: { store.scope }, set: { store.setScope($0) })) {
                    Text("All windows on the focused display").tag("all-main-display")
                    Text("Only the focused application").tag("focused-app")
                }.pickerStyle(.radioGroup)
            }
        }.formStyle(.grouped).navigationTitle("Layout")
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var store: PandaConfigStore
    var body: some View {
        Form {
            Section("Borders") {
                Toggle("Show active-window borders", isOn: Binding(get: { store.borderEnabled }, set: { store.setBorderEnabled($0) }))
                Text("Border color and thickness are currently managed by Panda's runtime defaults.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).navigationTitle("Appearance")
    }
}

private struct GeneralView: View {
    @ObservedObject var model: PandaModel
    var body: some View {
        Form {
            Section("Panda") {
                LabeledContent("Status", value: model.daemonStatus)
                LabeledContent("Accessibility", value: model.accessibilityGranted ? "Granted" : "Required")
                if !model.accessibilityGranted { Button("Open Accessibility Settings", action: model.openAccessibility) }
                Toggle("Launch Panda at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Animate Panda in the menu bar", isOn: Binding(get: { model.menuBarAnimationEnabled }, set: { model.setMenuBarAnimationEnabled($0) }))
            }
            Section("Configuration") {
                LabeledContent("Status", value: model.configStatus)
                Text(model.configPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack { Button("Show in Finder", action: model.openConfig); Button("Refresh", action: model.refresh) }
            }
            Section("Service") {
                HStack { Button("Restart Panda", action: model.restart); Button("Stop Panda", role: .destructive, action: model.stop) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

private struct KeybindsView: View {
    @ObservedObject var model: PandaModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Click a shortcut and press a new combination. Delete clears it.").foregroundStyle(.secondary)
                Spacer()
                if let message = model.configStore.savedMessage { Text(message).font(.caption).foregroundStyle(.green) }
                Button("Reset All", action: model.configStore.resetAll)
            }.padding()
            List {
                Section("Window Management") {
                    ForEach(model.configStore.bindings.filter { !$0.isWorkspace }) { binding in
                        BindingEditor(store: model.configStore, binding: binding)
                    }
                }
                Section("Workspaces") {
                    ForEach(model.configStore.bindings.filter(\.isWorkspace)) { binding in
                        BindingEditor(store: model.configStore, binding: binding)
                    }
                }
            }
        }
        .navigationTitle("Keybinds")
    }
}

private struct BindingEditor: View {
    @ObservedObject var store: PandaConfigStore
    let binding: PandaBinding
    @State private var draft: String

    init(store: PandaConfigStore, binding: PandaBinding) {
        self.store = store
        self.binding = binding
        _draft = State(initialValue: binding.chord)
    }

    var body: some View {
        HStack {
            Text(binding.title)
            Spacer()
            if store.conflicts(for: binding) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            KeyRecorderField(chord: $draft) { chord in store.update(binding, chord: chord) }
                .frame(width: 190, height: 24)
                .onChange(of: binding.chord) { draft = $0 }
            Button {
                draft = binding.defaultChord ?? ""
                store.update(binding, chord: draft)
            } label: { Image(systemName: "arrow.counterclockwise") }
            .buttonStyle(.borderless)
            .help("Reset shortcut")
        }
    }
}

private struct KeyRecorderField: NSViewRepresentable {
    @Binding var chord: String
    let onRecord: (String) -> Void

    func makeNSView(context: Context) -> ShortcutTextField {
        let field = ShortcutTextField()
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.alignment = .center
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.placeholderString = "Record shortcut"
        field.onRecord = { value in
            chord = value
            onRecord(value)
        }
        return field
    }

    func updateNSView(_ field: ShortcutTextField, context: Context) {
        if field.stringValue != chord { field.stringValue = chord }
    }
}

private final class ShortcutTextField: NSTextField {
    var onRecord: ((String) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { setDaemonHotkeysPaused(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        setDaemonHotkeysPaused(false)
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            stringValue = ""
            onRecord?("")
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        guard !parts.isEmpty, let key = keyName(for: event) else {
            NSSound.beep()
            return
        }
        parts.append(key)
        let value = parts.joined(separator: "+")
        stringValue = value
        onRecord?(value)
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if currentEditor() != nil { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }

    private func keyName(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 36: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 53: return "escape"
        case 122: return "f1"
        case 120: return "f2"
        case 99: return "f3"
        case 118: return "f4"
        case 96: return "f5"
        case 97: return "f6"
        case 98: return "f7"
        case 100: return "f8"
        case 101: return "f9"
        case 109: return "f10"
        case 103: return "f11"
        case 111: return "f12"
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else { return nil }
            return characters
        }
    }

    private func setDaemonHotkeysPaused(_ paused: Bool) {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/panda-cli")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["hotkeys", paused ? "pause" : "resume"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}

private struct PlaceholderSettings: View {
    let title: String
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .navigationTitle(title)
    }
}

private struct AnimatedPandaMascot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bobbing = false

    var body: some View {
        Group {
            if let image = NSImage(named: "PandaMascot") {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 104, height: 104)
        .scaleEffect(reduceMotion ? 1 : (bobbing ? 1.04 : 0.96))
        .offset(y: reduceMotion ? 0 : (bobbing ? -5 : 5))
        .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: bobbing)
        .onAppear {
            guard !reduceMotion else { return }
            bobbing = true
        }
    }
}

private struct OnboardingView: View {
    let isUpdate: Bool
    let version: String
    @State private var permissionGranted: Bool
    let openPermission: () -> Void
    let finish: () -> Void
    let highlights: [String]
    @State private var page = 0

    init(isUpdate: Bool, version: String, permissionGranted: Bool, highlights: [String], openPermission: @escaping () -> Void, finish: @escaping () -> Void) {
        self.isUpdate = isUpdate
        self.version = version
        _permissionGranted = State(initialValue: permissionGranted)
        self.highlights = highlights
        self.openPermission = openPermission
        self.finish = finish
    }

    var body: some View {
        VStack(spacing: 22) {
            AnimatedPandaMascot()
            if isUpdate {
                Text("Welcome back").font(.largeTitle.bold())
                Text("Panda \(version) is ready. Your configuration and terminal workflow are unchanged.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
                GroupBox("What’s new") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(highlights, id: \.self) { highlight in
                            Label(highlight, systemImage: "sparkles")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                Button("Continue", action: finish).buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                onboardingPage
                HStack {
                    if page > 0 { Button("Back") { page -= 1 } }
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle().fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 7, height: 7)
                        }
                    }
                    Spacer()
                    if page < 2 {
                        Button("Continue") { page += 1 }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Open Settings", action: finish).buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(36)
        .frame(width: 600, height: 520)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            permissionGranted = AXIsProcessTrusted()
        }
    }

    @ViewBuilder private var onboardingPage: some View {
        switch page {
        case 0:
            Text("Welcome to Panda").font(.largeTitle.bold())
            Text("A fast, keyboard-first tiling window manager that keeps the native macOS apps you already use.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 24) {
                Label("Automatic tiling", systemImage: "rectangle.3.group")
                Label("Nine workspaces", systemImage: "square.grid.3x3")
                Label("Global keybinds", systemImage: "keyboard")
            }.font(.callout)
        case 1:
            Text("Allow window control").font(.largeTitle.bold())
            Text("macOS requires Accessibility permission before Panda can focus, move, or tile windows.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            GroupBox {
                HStack {
                    Image(systemName: permissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(permissionGranted ? .green : .orange)
                    Text(permissionGranted ? "Accessibility permission granted" : "Permission is still required")
                    Spacer()
                    if !permissionGranted { Button("Open System Settings", action: openPermission) }
                }.padding(6)
            }
        default:
            Text("You’re ready").font(.largeTitle.bold())
            Text("Use workspaces to keep projects separate, then customize every shortcut whenever you like.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            VStack(alignment: .leading, spacing: 10) {
                Label("Option + 1…9 switches workspaces", systemImage: "arrow.left.arrow.right")
                Label("Option + Shift + 1…9 moves a window", systemImage: "macwindow.on.rectangle")
                Label("The menu bar opens Settings at any time", systemImage: "menubar.rectangle")
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PandaModel()
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var statusObservation: AnyCancellable?
    private var statusAnimationObservation: AnyCancellable?
    private var statusAnimationTimer: Timer?
    private var statusAnimationPhase = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.pandaStatusImage(waving: false)
        rebuildMenu()
        statusObservation = model.$daemonStatus.combineLatest(model.$accessibilityGranted).sink { [weak self] status, permission in
            self?.statusMenuItem.title = permission ? status : "Accessibility permission required"
            self?.statusItem.button?.contentTintColor = permission ? nil : .systemOrange
        }
        statusAnimationObservation = model.$menuBarAnimationEnabled.sink { [weak self] enabled in
            self?.updateStatusAnimation(enabled: enabled)
            self?.rebuildMenu()
        }
        model.ensureDaemonRunning()
        if !showOnboardingIfNeeded() {
            showSettings(route: .general)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusAnimationTimer?.invalidate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboardingWindow?.isVisible != true {
            showSettings(route: .general)
        }
        return true
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: model.daemonStatus, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Open Keybinds…", action: #selector(openKeybinds), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "")
        menu.addItem(withTitle: "Restart Panda", action: #selector(restartPanda), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Welcome…", action: #selector(showWelcome), keyEquivalent: "")
        let animationItem = menu.addItem(withTitle: "Animate Panda", action: #selector(toggleStatusAnimation), keyEquivalent: "")
        animationItem.state = model.menuBarAnimationEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Panda", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Panda", action: #selector(quitPanda), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func updateStatusAnimation(enabled: Bool) {
        statusAnimationTimer?.invalidate()
        statusAnimationTimer = nil
        statusAnimationPhase = false
        statusItem.button?.image = Self.pandaStatusImage(waving: false)

        guard enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        statusAnimationTimer = Timer.scheduledTimer(
            timeInterval: 1.15,
            target: self,
            selector: #selector(advanceStatusAnimation),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func advanceStatusAnimation() {
        statusAnimationPhase.toggle()
        statusItem.button?.image = Self.pandaStatusImage(waving: statusAnimationPhase)
    }

    private static func pandaStatusImage(waving: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let earLift: CGFloat = waving ? 0.9 : 0
            NSBezierPath(ovalIn: NSRect(x: 1.4, y: 10.7 + earLift, width: 5.2, height: 5.2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11.4, y: 10.7 + earLift, width: 5.2, height: 5.2)).fill()

            let face = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.2, width: 13, height: 12.8))
            face.lineWidth = 1.35
            face.stroke()

            let leftEye = NSBezierPath(ovalIn: NSRect(x: 5.0, y: 7.0, width: 2.5, height: 3.5))
            leftEye.fill()
            let rightEye = NSBezierPath(ovalIn: NSRect(x: 10.5, y: 7.0, width: 2.5, height: 3.5))
            rightEye.fill()

            NSBezierPath(ovalIn: NSRect(x: 8.0, y: 5.2, width: 2.0, height: 1.4)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Panda"
        return image
    }

    @objc private func openSettings() { showSettings(route: .general) }
    @objc private func openKeybinds() { showSettings(route: .keybinds) }
    @objc private func reloadConfig() { model.reloadConfig() }
    @objc private func restartPanda() { model.restart() }
    @objc private func showWelcome() { showOnboarding(isUpdate: false) }
    @objc private func toggleStatusAnimation() { model.setMenuBarAnimationEnabled(!model.menuBarAnimationEnabled) }
    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func quitPanda() {
        if Bundle.main.bundleURL.path.hasPrefix("/Applications/") { model.stop() }
        NSApp.terminate(nil)
    }

    private func showSettings(route: SettingsRoute) {
        model.route = route
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsRootView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "Panda Settings"
            window.setContentSize(NSSize(width: 780, height: 520))
            window.styleMask.insert([.resizable, .miniaturizable, .closable, .titled])
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    private func showOnboardingIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let completed = defaults.bool(forKey: "hasCompletedOnboarding")
        let lastVersion = defaults.string(forKey: "lastSeenVersion")
        guard !completed || (lastVersion != nil && lastVersion != version) else { return false }
        showOnboarding(isUpdate: completed)
        return true
    }

    private func showOnboarding(isUpdate: Bool) {
        let defaults = UserDefaults.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let view = OnboardingView(
            isUpdate: isUpdate,
            version: version,
            permissionGranted: model.accessibilityGranted,
            highlights: releaseHighlights(for: version),
            openPermission: { [weak self] in self?.model.openAccessibility() },
            finish: { [weak self] in
                guard let self else { return }
                defaults.set(true, forKey: "hasCompletedOnboarding")
                defaults.set(version, forKey: "lastSeenVersion")
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
                self.showSettings(route: .general)
            }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = isUpdate ? "What’s New in Panda" : "Welcome to Panda"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func releaseHighlights(for version: String) -> [String] {
        struct Entry: Decodable { let title: String; let highlights: [String] }
        guard let url = Bundle.main.url(forResource: "PandaChangelog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([String: Entry].self, from: data),
              let entry = notes[version] else {
            return ["Panda has been updated with fixes and improvements."]
        }
        return entry.highlights
    }
}

@main
struct PandaUIApplication {
    static func main() {
        let lockPath = "/tmp/panda-ui-\(getuid()).lock"
        let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

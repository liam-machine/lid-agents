// Lid Agents — menu bar front end for the `agents` script bundled in Contents/Resources.
//
// All behaviour (the pmset flag, busy-agent detection, the auto-pause guard) lives in that
// script so the terminal and the menu bar can never disagree. This app only shows its state,
// runs its subcommands, owns the global hotkey and posts notifications with its own icon.

import AppKit
import Carbon.HIToolbox
import UserNotifications

let bundleID = Bundle.main.bundleIdentifier ?? "io.github.liam-machine.lid-agents"
let stateDir = NSHomeDirectory() + "/.cache/lid-agents"
let logPath = stateDir + "/lid-agents.log"
let launchAgentPath = NSHomeDirectory() + "/Library/LaunchAgents/\(bundleID).plist"

// MARK: - The agents script

struct AgentState {
    var keeping = false
    var busy = 0
    var guardRunning = false
    var battery = 0
    var onBattery = false
    var lidClosed = false
    var setupOK = true
    var idleMinutes = 3
    var always = false              // kept on whether or not an agent is busy (`agents keep --always`)
}

/// One agent the menu lists: working, or stopped on a prompt and waiting for you
struct AgentRow {
    var pid = 0
    var name = ""
    var waiting = false
    var onPhone: Bool?              // a Claude session on Remote Control (nil: not one Lid Agents can tell)
    var folder = ""
}

/// Everything the menu shows, from one `agents state --menu`
struct MenuSnapshot {
    var state = AgentState()
    var remoteOn: Bool?             // Remote Control for new Claude sessions (nil: no Claude Code here)
    var remoteUnset = false         // …and you've never chosen either way (it's off)
    var agents: [AgentRow] = []
    var offPhone: [AgentRow] { agents.filter { $0.onPhone == false } }
}

enum Agents {
    static let script = Bundle.main.path(forResource: "agents", ofType: nil) ?? ""

    @discardableResult
    static func run(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func parseState(_ line: String) -> AgentState {
        let f = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        guard f.count >= 8 else { return AgentState() }
        return AgentState(keeping: f[0] == "keep", busy: Int(f[1]) ?? 0, guardRunning: f[2] == "1",
                          battery: Int(f[3]) ?? 0, onBattery: f[4] == "battery", lidClosed: f[5] == "closed",
                          setupOK: f[6] == "ok", idleMinutes: Int(f[7]) ?? 3, always: f.count > 8 && f[8] == "always")
    }

    static func state() -> AgentState { parseState(run(["state"]).output) }

    /// The state, Remote Control and the agents, busy ones first, from one look at the processes
    static func snapshot() -> MenuSnapshot {
        let lines = run(["state", "--menu"]).output.split(separator: "\n").map(String.init)
        var snap = MenuSnapshot(state: parseState(lines.first ?? ""))
        for line in lines.dropFirst() {
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            if f.count == 2, f[0] == "remote" {
                snap.remoteOn = f[1] == "on" ? true : f[1] == "off" || f[1] == "unset" ? false : nil
                snap.remoteUnset = f[1] == "unset"
            } else if f.count >= 5, f[0] == "agent", let pid = Int(f[1]) {
                snap.agents.append(AgentRow(pid: pid, name: f[2], waiting: f[3] == "waiting",
                                            onPhone: f[4] == "yes" ? true : f[4] == "no" ? false : nil,
                                            folder: f.count > 5 ? f[5] : ""))
            }
        }
        snap.agents.sort { !$0.waiting && $1.waiting }
        return snap
    }

    /// "claude in a, claude in b"
    static func names(_ agents: [AgentRow]) -> String {
        agents.map { "\($0.name) in " + ($0.folder.isEmpty ? "?" : ($0.folder as NSString).lastPathComponent) }
            .joined(separator: ", ")
    }

    static func lastAutoPauseReason() -> String? {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8),
              let line = text.split(separator: "\n").last(where: { $0.contains("auto-pause:") }),
              let range = line.range(of: "auto-pause: ") else { return nil }
        return String(line[range.upperBound...])
    }
}

// MARK: - Updates (notify only; installing is always the user's click)

enum Updater {
    static let repo = "liam-machine/lid-agents"
    static let logPath = stateDir + "/update.log"

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func isVersion(_ s: String) -> Bool {
        s.range(of: #"^[0-9]+(\.[0-9]+){1,3}$"#, options: .regularExpression) != nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// The latest release's version, from GitHub's public API (one anonymous request).
    static func latest(_ done: @escaping (String?) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            var tag = json?["tag_name"] as? String
            if tag?.hasPrefix("v") == true { tag = String(tag!.dropFirst()) }
            done(tag.flatMap { isVersion($0) ? $0 : nil })
        }.resume()
    }

    /// Runs that release's installer, which quits this app, replaces it and reopens it.
    static func install(_ version: String) {
        guard isVersion(version) else { return }
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Replace this copy wherever it lives (/Applications for DMG installs, ~/Applications for curl)
        var env = ProcessInfo.processInfo.environment
        env["LID_AGENTS_VERSION"] = version
        env["LID_AGENTS_APP"] = Bundle.main.bundlePath
        process.environment = env
        process.arguments = ["-c", """
            curl -fsSL https://github.com/\(repo)/releases/download/v\(version)/install.sh \
              | bash >> "\(logPath)" 2>&1
            """]
        try? process.run()
    }
}

// MARK: - Global hotkey (Carbon RegisterEventHotKey needs no Accessibility permission)

struct Hotkey: Equatable {
    let spec: String            // normalised, as stored in the Hotkey default
    let keyCode: UInt32
    let modifiers: UInt32
    let symbols: String
    let menuKey: String
    let menuModifiers: NSEvent.ModifierFlags

    static let fallback = "ctrl+0"
    static let presets = ["ctrl+0", "ctrl+opt+cmd+a", "ctrl+opt+cmd+l", "ctrl+opt+cmd+k", "ctrl+shift+cmd+space"]

    static let keys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space,
    ]

    /// Parses "ctrl+opt+cmd+a" style strings; nil for "none" or anything unrecognised.
    static func parse(_ spec: String) -> Hotkey? {
        var mods: UInt32 = 0
        var flags: NSEvent.ModifierFlags = []
        var key: String?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": mods |= UInt32(controlKey); flags.insert(.control)
            case "opt", "option", "alt": mods |= UInt32(optionKey); flags.insert(.option)
            case "shift": mods |= UInt32(shiftKey); flags.insert(.shift)
            case "cmd", "command": mods |= UInt32(cmdKey); flags.insert(.command)
            default: key = part
            }
        }
        guard let key, let code = keys[key] else { return nil }
        // A global hotkey needs ⌃, ⌥ or ⌘; a bare letter (or ⇧+letter) would swallow typing
        guard !flags.isDisjoint(with: [.control, .option, .command]) else { return nil }
        var symbols = ""
        var normalised: [String] = []
        if flags.contains(.control) { symbols += "⌃"; normalised.append("ctrl") }
        if flags.contains(.option) { symbols += "⌥"; normalised.append("opt") }
        if flags.contains(.shift) { symbols += "⇧"; normalised.append("shift") }
        if flags.contains(.command) { symbols += "⌘"; normalised.append("cmd") }
        symbols += key == "space" ? "Space" : key.uppercased()
        normalised.append(key)
        return Hotkey(spec: normalised.joined(separator: "+"), keyCode: UInt32(code), modifiers: mods,
                      symbols: symbols, menuKey: key == "space" ? " " : key, menuModifiers: flags)
    }

    /// The hotkey a key press in the recorder describes, or nil if it isn't usable as one.
    static func from(_ event: NSEvent) -> Hotkey? {
        guard let key = keys.first(where: { $0.value == Int(event.keyCode) })?.key else { return nil }
        let flags = event.modifierFlags
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        return parse((parts + [key]).joined(separator: "+"))
    }

    static var configured: Hotkey? {
        let spec = UserDefaults.standard.string(forKey: "Hotkey") ?? fallback
        return spec.lowercased() == "none" ? nil : (parse(spec) ?? parse(fallback))
    }
}

var hotkeyHandler: (() -> Void)?
var hotkeyRef: EventHotKeyRef?
var hotkeyHandlerInstalled = false

/// Makes `hotkey` the global hotkey (nil clears it). False when macOS refuses the combination.
@discardableResult
func setGlobalHotkey(_ hotkey: Hotkey?) -> Bool {
    if !hotkeyHandlerInstalled {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { hotkeyHandler?() }
            return noErr
        }, 1, &spec, nil, nil)
        hotkeyHandlerInstalled = true
    }
    if let ref = hotkeyRef {
        UnregisterEventHotKey(ref)
        hotkeyRef = nil
    }
    guard let hotkey else { return true }
    let id = EventHotKeyID(signature: OSType(0x4C414754), id: 1)   // 'LAGT'
    return RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &hotkeyRef) == noErr
}

// MARK: - Hotkey recorder window

/// Captures the next key press, including ⌘ combinations that would otherwise go to menus.
final class RecorderView: NSView {
    var onKey: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        onKey?(event)
        return true
    }
}

final class HotkeyRecorder: NSObject, NSWindowDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let keys = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "")
    var onFinish: ((Hotkey?) -> Void)?      // nil when cancelled
    var finished = false

    init(current: Hotkey?) {
        super.init()
        window.title = "Lid Agents Hotkey"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.level = .floating

        let view = RecorderView(frame: window.contentRect(forFrameRect: window.frame))
        view.onKey = { [weak self] in self?.handle($0) }

        let prompt = NSTextField(labelWithString: "Press the keys you want to use")
        prompt.font = .systemFont(ofSize: 13, weight: .semibold)
        keys.stringValue = current?.symbols ?? "—"
        keys.font = .systemFont(ofSize: 30, weight: .medium)
        keys.alignment = .center
        hint.stringValue = "Use ⌃, ⌥ or ⌘ with a letter, number or Space. Esc cancels."
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))

        let stack = NSStackView(views: [prompt, keys, hint, cancel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        window.contentView = view
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
    }

    func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { cancel(); return }
        guard let hotkey = Hotkey.from(event) else {
            hint.stringValue = "That needs ⌃, ⌥ or ⌘ as well. Try again, or press Esc."
            hint.textColor = .systemOrange
            return
        }
        keys.stringValue = hotkey.symbols
        hint.stringValue = "Saved."
        hint.textColor = .secondaryLabelColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.finish(hotkey) }
    }

    @objc func cancel() { finish(nil) }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    func finish(_ hotkey: Hotkey?) {
        guard !finished else { return }
        finished = true
        window.close()
        onFinish?(hotkey)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var hotkey = Hotkey.configured
    var recorder: HotkeyRecorder?
    var state = AgentState()
    var acting = false          // a change this app made, so it isn't reported as an auto-pause
    var timer: Timer?
    var updateTimer: Timer?
    var availableUpdate: String?
    var updating = false
    var appliedHotkeySpec: String?      // the Hotkey default last applied, to spot `agents hotkey` changes
    var appliedHotkeyStamp = 0.0        // HotkeyRequested last applied: `agents hotkey` re-run with the same keys
    var unavailableHotkey: Hotkey?      // the configured hotkey macOS refused at launch (nothing registered)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if moveToApplicationsIfNeeded() { return }
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        statusItem = makeStatusItem()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading

        hotkeyHandler = { [weak self] in self?.toggle() }
        appliedHotkeySpec = UserDefaults.standard.string(forKey: "Hotkey")
        appliedHotkeyStamp = UserDefaults.standard.double(forKey: "HotkeyRequested")
        if let wanted = hotkey, !setGlobalHotkey(wanted) {
            // Keep the choice saved (the other app may let go of it) but don't show it as working
            unavailableHotkey = wanted
            hotkey = nil
            appendLog("hotkey \(wanted.spec) unavailable: another app has it")
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            // For `agents` status: without notifications, a switch by hotkey looks like nothing happened
            try? (granted ? "allowed\n" : "denied\n").write(toFile: stateDir + "/notifications", atomically: true, encoding: .utf8)
            guard granted else { return }
            // Posted only now, so it isn't dropped before notifications are allowed
            DispatchQueue.main.async {
                if let refused = self?.unavailableHotkey {
                    self?.notify("\(refused.symbols) isn't available",
                                 "Another app is using it. Pick one under the cup → Hotkey, or run `agents hotkey \(refused.spec)` to retry.")
                }
            }
            let defaults = UserDefaults.standard
            let lastRun = defaults.string(forKey: "LastRunVersion")
            defaults.set(Updater.current, forKey: "LastRunVersion")
            if !defaults.bool(forKey: "Welcomed") {
                defaults.set(true, forKey: "Welcomed")
                let how = self?.hotkey.map { "Press \($0.symbols) or click" } ?? "Click"
                self?.notify("Lid Agents is ready", "\(how) the cup in the menu bar to keep agents running with the lid closed.")
            } else if let lastRun, Updater.isNewer(Updater.current, than: lastRun) {
                self?.notify("Lid Agents updated to \(Updater.current)",
                             "See what's new at github.com/\(Updater.repo)/releases.")
            }
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        DispatchQueue.main.async { self.finishSetupIfNeeded() }

        // Check at launch, then whenever a day has passed since the last check
        checkForUpdates(manual: false)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            let last = UserDefaults.standard.double(forKey: "LastUpdateCheck")
            if Date().timeIntervalSince1970 - last > 86_400 { self?.checkForUpdates(manual: false) }
        }
    }

    // MARK: First-run setup (a DMG install never runs install.sh, so the app does its part)

    /// Opened straight from the disk image: offer to copy into /Applications and relaunch there.
    /// True when this copy is quitting.
    func moveToApplicationsIfNeeded() -> Bool {
        let here = Bundle.main.bundlePath
        guard here.hasPrefix("/Volumes/") else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Lid Agents to Applications?"
        alert.informativeText = "It's running from the disk image, which goes away when you eject it."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return true }

        let target = "/Applications/" + (here as NSString).lastPathComponent
        do {
            if FileManager.default.fileExists(atPath: target) {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .filter { $0.processIdentifier != getpid() }.forEach { $0.terminate() }
                try FileManager.default.removeItem(atPath: target)
            }
            try FileManager.default.copyItem(atPath: here, toPath: target)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't copy Lid Agents"
            failed.informativeText = "Drag it into Applications from the disk image instead.\n\n\(error.localizedDescription)"
            failed.runModal()
            NSApp.terminate(nil)
            return true
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: target), configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// Links the `agents` command, turns on Open at Login, and (once, with the user's OK)
    /// installs the pmset rule through the macOS administrator prompt.
    func finishSetupIfNeeded(force: Bool = false) {
        linkCommand()
        // An upgrade from the DMG never runs install.sh: refresh an installed OpenCode plugin here
        DispatchQueue.global(qos: .utility).async { Agents.run(["integrate", "--refresh"]) }
        let defaults = UserDefaults.standard
        // Already set up (curl install, or an earlier run): never re-ask, never touch Open at Login
        guard !Agents.state().setupOK else {
            defaults.set(true, forKey: "SetupDone")
            offerRemoteControlIfNeeded()
            return
        }
        guard force || !defaults.bool(forKey: "SetupDone") else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Finish setting up Lid Agents"
        alert.informativeText = """
            To keep agents running with the lid closed, Lid Agents needs to run one command \
            as administrator: pmset -a disablesleep (on or off). Nothing else.

            macOS will ask for your password once.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        defaults.set(true, forKey: "SetupDone")      // ask once; "Finish Setup…" stays in the menu
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !force && !FileManager.default.fileExists(atPath: launchAgentPath) { setOpenAtLogin(true) }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Agents.run(["install"])
            let next = Agents.state()
            DispatchQueue.main.async {
                self.apply(next)
                if next.setupOK {
                    let how = self.hotkey.map { "Press \($0.symbols) or click" } ?? "Click"
                    self.notify("Lid Agents is set up", "\(how) the cup in the menu bar to keep agents running with the lid closed.")
                    self.offerRemoteControlIfNeeded()
                } else {
                    let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.notify("Setup didn't finish", message.isEmpty ? "Try Finish Setup… in the cup's menu." : message)
                }
            }
        }
    }

    @objc func finishSetup() { finishSetupIfNeeded(force: true) }

    /// ~/.local/bin/agents → the script inside this bundle (moving aside anything that isn't ours)
    func linkCommand() {
        let fm = FileManager.default
        let link = NSHomeDirectory() + "/.local/bin/agents"
        if let target = try? fm.destinationOfSymbolicLink(atPath: link), target == Agents.script { return }
        try? fm.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
            try? fm.removeItem(atPath: link)
        } else if fm.fileExists(atPath: link) {
            try? fm.moveItem(atPath: link, toPath: link + ".bak")
        }
        try? fm.createSymbolicLink(atPath: link, withDestinationPath: Agents.script)
    }

    func setOpenAtLogin(_ on: Bool) {
        guard on else { try? FileManager.default.removeItem(atPath: launchAgentPath); return }
        let plist: [String: Any] = [
            "Label": bundleID,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        try? FileManager.default.createDirectory(atPath: (launchAgentPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            FileManager.default.createFile(atPath: launchAgentPath, contents: data)
        }
    }

    // MARK: Updates

    var updatesEnabled: Bool { UserDefaults.standard.object(forKey: "CheckForUpdates") as? Bool ?? true }

    func checkForUpdates(manual: Bool) {
        guard manual || updatesEnabled else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "LastUpdateCheck")
        Updater.latest { [weak self] latest in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let latest else {
                    if manual { self.notify("Couldn't check for updates", "GitHub didn't answer. Try again later.") }
                    return
                }
                guard Updater.isNewer(latest, than: Updater.current) else {
                    self.availableUpdate = nil
                    if manual { self.notify("Lid Agents is up to date", "You have the latest version, \(Updater.current).") }
                    return
                }
                self.availableUpdate = latest
                // Tell the user once per version; the menu item stays until they update
                if manual || UserDefaults.standard.string(forKey: "NotifiedUpdate") != latest {
                    UserDefaults.standard.set(latest, forKey: "NotifiedUpdate")
                    self.notify("Lid Agents \(latest) is available",
                                "Click the cup in the menu bar, then Update to \(latest).")
                }
            }
        }
    }

    @objc func manualUpdateCheck() { checkForUpdates(manual: true) }

    // MARK: Hotkey

    /// The one way the hotkey changes: the Hotkey menu, the recorder, and `agents hotkey`.
    /// If macOS refuses `new`, the working hotkey stays registered and is written back to the
    /// Hotkey default, so `agents` status and the next launch show what actually works.
    func useHotkey(_ new: Hotkey?) {
        if setGlobalHotkey(new) {
            hotkey = new
            unavailableHotkey = nil
            saveHotkeySpec(new?.spec ?? "none")
            appendLog("hotkey: \(new?.spec ?? "none")")
            notify(new.map { "Hotkey: \($0.symbols)" } ?? "Hotkey off",
                   new.map { "Press \($0.symbols) anywhere to switch." } ?? "Use the cup in the menu bar to switch.")
        } else {
            setGlobalHotkey(hotkey)
            saveHotkeySpec(hotkey?.spec ?? unavailableHotkey?.spec ?? "none")
            appendLog("hotkey \(new?.spec ?? "?") unavailable: another app has it")
            let kept = hotkey.map { "\($0.symbols) stays" } ?? "No hotkey is set"
            notify("\(new?.symbols ?? "That hotkey") isn't available", "Another app is using it. \(kept); pick a different one.")
        }
    }

    func saveHotkeySpec(_ spec: String) {
        UserDefaults.standard.set(spec, forKey: "Hotkey")
        appliedHotkeySpec = spec
    }

    /// `agents hotkey <keys>` writes the Hotkey default (and a request stamp, so re-running it
    /// with the same keys retries one that failed); apply it here without a restart.
    func reloadHotkeyIfChanged() {
        let defaults = UserDefaults.standard
        let spec = defaults.string(forKey: "Hotkey")
        let stamp = defaults.double(forKey: "HotkeyRequested")
        guard spec != appliedHotkeySpec || stamp != appliedHotkeyStamp else { return }
        appliedHotkeySpec = spec
        appliedHotkeyStamp = stamp
        let next = Hotkey.configured
        if next == hotkey && unavailableHotkey == nil { return }   // already registered as asked
        useHotkey(next)
    }

    // MARK: When an agent needs you

    static let defaultWaitMinutes = 3
    static let waitChoices = [3, 10, 30, 60]

    /// Minutes a closed Mac stays awake for an agent stopped on a prompt. The `agents` guard reads
    /// the same WaitMinutes default on every pass, so a change applies to a keep already running.
    var waitMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: "WaitMinutes")
        return stored > 0 ? stored : Self.defaultWaitMinutes
    }

    func waitMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Wait for your answer: \(waitMinutes) min", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let note = NSMenuItem(title: "With the lid closed, an agent that needs you keeps the Mac awake this long", action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)
        var choices = Self.waitChoices
        if !choices.contains(waitMinutes) { choices.append(waitMinutes); choices.sort() }
        for minutes in choices {
            let title = "\(minutes) minutes" + (minutes == Self.defaultWaitMinutes ? "  (default)" : "")
            let choice = NSMenuItem(title: title, action: #selector(chooseWaitMinutes(_:)), keyEquivalent: "")
            choice.target = self
            choice.tag = minutes
            choice.state = minutes == waitMinutes ? .on : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    @objc func chooseWaitMinutes(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "WaitMinutes")
        appendLog("wait for input: \(sender.tag) min")
        notify("Waiting for you: \(sender.tag) min",
               "With the lid closed, an agent that needs your answer keeps the Mac awake \(sender.tag) minutes, then it sleeps.")
    }

    @objc func choosePresetHotkey(_ sender: NSMenuItem) {
        useHotkey((sender.representedObject as? String).flatMap(Hotkey.parse))
    }

    @objc func recordHotkey() {
        recorder?.finish(nil)
        setGlobalHotkey(nil)                 // so pressing the current one records it instead of toggling
        let recorder = HotkeyRecorder(current: hotkey)
        recorder.onFinish = { [weak self] picked in
            guard let self else { return }
            self.recorder = nil
            if let picked { self.useHotkey(picked) } else { setGlobalHotkey(self.hotkey) }
        }
        self.recorder = recorder
        recorder.show()
    }

    func hotkeyMenuItem() -> NSMenuItem {
        let label = hotkey?.symbols ?? unavailableHotkey.map { "\($0.symbols) (unavailable)" } ?? "None"
        let item = NSMenuItem(title: "Hotkey: \(label)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        var specs = Hotkey.presets
        if let current = hotkey?.spec, !specs.contains(current) { specs.insert(current, at: 0) }
        for spec in specs {
            guard let preset = Hotkey.parse(spec) else { continue }
            let choice = NSMenuItem(title: preset.symbols + (spec == Hotkey.fallback ? "  (default)" : ""),
                                    action: #selector(choosePresetHotkey(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = spec
            choice.state = preset == hotkey ? .on : .off
            submenu.addItem(choice)
        }
        let none = NSMenuItem(title: "None", action: #selector(choosePresetHotkey(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = "none"
        none.state = hotkey == nil ? .on : .off
        submenu.addItem(none)
        submenu.addItem(.separator())
        let record = NSMenuItem(title: "Record New Hotkey…", action: #selector(recordHotkey), keyEquivalent: "")
        record.target = self
        submenu.addItem(record)
        item.submenu = submenu
        return item
    }

    @objc func installUpdate() {
        guard let version = availableUpdate, !updating else { return }
        updating = true
        notify("Updating Lid Agents to \(version)…", "It will reopen by itself in a few seconds.")
        Updater.install(version)
        // On success the installer quits this app; still being here means it failed
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            self?.updating = false
            self?.notify("Lid Agents couldn't update", "Details are in ~/.cache/lid-agents/update.log.")
        }
    }

    // Show banners even while the menu is open (the app counts as frontmost then)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: State

    func refresh() {
        reloadHotkeyIfChanged()
        DispatchQueue.global(qos: .utility).async {
            let next = Agents.state()
            DispatchQueue.main.async { self.apply(next) }
        }
    }

    // MARK: Menu bar placement

    static let cupName = "LidAgentsCup"
    static let cupPreferredPosition = 0.0   // distance from the right end; the system items stay right of it

    /// New menu bar items go to the left end of the right-hand group, which on a notched
    /// display with a busy menu bar is behind the notch, so the cup was hidden. Ask for a spot
    /// next to the system items instead; ⌘-dragging the cup later saves the user's own choice.
    /// macOS only saves a position (or hidden state) when the user ⌘-drags the item, so a spot
    /// chosen before 1.1.0, saved under the unnamed item's key, carries over; nothing is forced.
    func makeStatusItem() -> NSStatusItem {
        let defaults = UserDefaults.standard
        let positionKey = "NSStatusItem Preferred Position \(Self.cupName)"
        if defaults.object(forKey: positionKey) == nil {
            let chosenBefore = defaults.object(forKey: "NSStatusItem Preferred Position Item-0")
            defaults.set(chosenBefore ?? Self.cupPreferredPosition, forKey: positionKey)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.cupName
        return item
    }

    func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    func apply(_ next: AgentState) {
        if state.keeping && !next.keeping && !acting {
            notify("Agents paused", "Closing the lid sleeps the Mac again (\(Agents.lastAutoPauseReason() ?? "turned off elsewhere")).")
        }
        state = next
        let button = statusItem.button
        let symbol = next.keeping ? "cup.and.saucer.fill" : "cup.and.saucer"
        button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: next.keeping ? "Agents keep running" : "Agents pause")
        button?.image?.isTemplate = true
        button?.title = next.keeping ? " \(next.busy)" : ""
        button?.toolTip = next.keeping ? "Lid closed → agents keep running" : "Lid closed → Mac sleeps, agents pause"
    }

    func perform(_ args: [String]) {
        // A held hotkey auto-repeats; a second toggle before the first lands would undo it
        guard !acting else { return }
        acting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Agents.run(args)
            let snap = Agents.snapshot()
            let next = snap.state
            // Switching keep on is the moment before the lid closes: say which agents your phone can't reach
            let missing = next.keeping ? snap.offPhone : []
            DispatchQueue.main.async {
                if result.status != 0 {
                    let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.notify("Lid Agents couldn't change the setting", message.isEmpty ? "Run `agents install` in a terminal." : message)
                } else if next.keeping {
                    let always = args.contains("--always")
                    let remote = missing.isEmpty ? ""
                        : " Not on Remote Control: \(Agents.names(missing)). Run /remote-control in \(missing.count == 1 ? "it" : "each") to answer from your phone."
                    self.notify("Agents keep running",
                                (always ? "Lid closed won't sleep the Mac, busy or not (3h)."
                                    : next.busy == 0 ? "None busy yet: pauses in ~\(next.idleMinutes) min unless one starts."
                                    : "\(next.busy) busy. Close the lid whenever.") + remote)
                } else {
                    self.notify("Agents pause", "Closing the lid sleeps the Mac.")
                }
                self.apply(next)
                self.acting = false
            }
        }
    }

    @objc func toggle() { perform(state.keeping ? ["pause"] : ["keep"]) }
    // The three "When the lid closes" choices; picking the one already chosen changes nothing
    @objc func chooseSleep() { if state.keeping { perform(["pause"]) } }
    @objc func chooseKeep() { if !state.keeping || state.always { perform(["keep"]) } }
    @objc func chooseKeepAlways() { if !state.keeping || !state.always { perform(["keep", "--always", "3"]) } }

    // MARK: Menu
    //
    // Top to bottom: what's happening, what to do when the lid closes, which agents are running,
    // then everything you set once under Settings.

    func menuNeedsUpdate(_ menu: NSMenu) {
        let snap = Agents.snapshot()
        apply(snap.state)
        menu.removeAllItems()

        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func section(_ title: String) {
            if #available(macOS 14.0, *) {
                menu.addItem(.sectionHeader(title: title))
            } else {
                info(title.uppercased())
            }
        }
        let font = NSFont.menuFont(ofSize: 0)
        func text(_ string: String, bold: Bool = false, color: NSColor = .labelColor, small: Bool = false) -> NSAttributedString {
            var f = small ? NSFont.menuFont(ofSize: NSFont.smallSystemFontSize) : font
            if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            return NSAttributedString(string: string, attributes: [.font: f, .foregroundColor: color])
        }
        func choice(_ title: String, _ selector: Selector, chosen: Bool, hotkey: Hotkey? = nil, tip: String) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: hotkey?.menuKey ?? "")
            item.keyEquivalentModifierMask = hotkey?.menuModifiers ?? []
            item.target = self
            item.state = chosen ? .on : .off
            item.toolTip = tip
            menu.addItem(item)
        }

        if let version = availableUpdate {
            let item = NSMenuItem(title: updating ? "Updating to \(version)…" : "Update to \(version)",
                                  action: #selector(installUpdate), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // What's happening
        menu.addItem(displayItem(text(state.keeping ? "Agents keep running with the lid closed" : "Closing the lid sleeps the Mac",
                                      bold: true)))
        let waiting = snap.agents.filter(\.waiting).count
        var summary = [state.busy == 0 ? "None working" : "\(state.busy) working"]
        if waiting > 0 { summary.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        summary.append("battery \(state.battery)%\(state.onBattery ? "" : " (charging)")")
        menu.addItem(displayItem(text(summary.joined(separator: " · "))))
        if !state.setupOK {
            let item = NSMenuItem(title: "Finish Setup… (needs your password once)", action: #selector(finishSetup), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // What to do
        section("When the lid closes")
        choice("Sleep (normal)", #selector(chooseSleep), chosen: !state.keeping,
               tip: "Closing the lid sleeps the Mac and pauses your agents")
        choice("Keep running while agents work", #selector(chooseKeep), chosen: state.keeping && !state.always, hotkey: hotkey,
               tip: "The Mac stays on with the lid closed until your agents finish (8-hour cap), then sleeps")
        choice("Keep running for 3 hours", #selector(chooseKeepAlways), chosen: state.keeping && state.always,
               tip: "The Mac stays on with the lid closed for 3 hours, even when no agent is working")
        menu.addItem(.separator())

        // Which agents are running
        section("Agents")
        if snap.agents.isEmpty { menu.addItem(displayItem(text("None running right now", color: .secondaryLabelColor))) }
        for agent in snap.agents {
            let folder = agent.folder.isEmpty ? "" : (agent.folder as NSString).lastPathComponent
            let symbol: (String, NSColor)? = switch agent.onPhone {
            case true?: ("iphone", .secondaryLabelColor)
            case false?: ("exclamationmark.triangle.fill", .systemOrange)
            case nil: nil
            }
            menu.addItem(displayItem(text(folder.isEmpty ? agent.name : "\(agent.name)  \(folder)"), symbol: symbol,
                                     detail: text(agent.waiting ? "needs you" : "working",
                                                  color: agent.waiting ? .systemOrange : .secondaryLabelColor)))
        }
        let offPhone = snap.offPhone.count
        if offPhone > 0 {
            menu.addItem(displayItem(text("Not on your phone: run /remote-control in \(offPhone == 1 ? "that session" : "each of those sessions")",
                                          color: .secondaryLabelColor, small: true)))
        }
        menu.addItem(.separator())

        menu.addItem(settingsItem(remoteOn: snap.remoteOn))
        menu.addItem(.separator())
        info("Lid Agents \(Updater.current)")
        menu.addItem(withTitle: "Quit Lid Agents", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// A row that only shows something. A plain item that can't be clicked is greyed out, so this
    /// one is a view: full colour, no highlight under the pointer, lined up with the items' titles.
    /// symbol: an SF Symbol and its colour in front; detail: text at the right edge.
    func displayItem(_ title: NSAttributedString, symbol: (String, NSColor)? = nil, detail: NSAttributedString? = nil) -> NSMenuItem {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 3, left: 22, bottom: 3, right: 14)   // the items' title column
        if let (name, color) = symbol, let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let view = NSImageView(image: image)
            view.contentTintColor = color
            view.symbolConfiguration = .init(pointSize: NSFont.systemFontSize - 1, weight: .regular)
            row.addArrangedSubview(view)
        }
        row.addArrangedSubview(NSTextField(labelWithAttributedString: title))
        if let detail {
            let gap = NSView()
            gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(gap)
            row.addArrangedSubview(NSTextField(labelWithAttributedString: detail))
        }
        let size = row.fittingSize
        row.frame = NSRect(x: 0, y: 0, width: max(size.width, 300), height: size.height)
        row.autoresizingMask = [.width]          // grows with the menu, so the detail stays at the right
        let item = NSMenuItem()
        item.view = row
        return item
    }

    /// Everything you set once
    func settingsItem(remoteOn: Bool?) -> NSMenuItem {
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(waitMenuItem())
        if let on = remoteOn {
            let remote = NSMenuItem(title: "Connect new Claude sessions to your phone", action: #selector(toggleRemote(_:)), keyEquivalent: "")
            remote.target = self
            remote.state = on ? .on : .off
            remote.toolTip = "Claude Code's Remote Control: answer new sessions from claude.ai/code or the Claude app, which gets a push when one needs you"
            submenu.addItem(remote)
        }
        submenu.addItem(hotkeyMenuItem())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
        submenu.addItem(login)
        submenu.addItem(.separator())
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(manualUpdateCheck), keyEquivalent: "")
        check.target = self
        submenu.addItem(check)
        let log = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        submenu.addItem(log)
        item.submenu = submenu
        return item
    }

    @objc func openLog() {
        if !FileManager.default.fileExists(atPath: logPath) {
            try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc func toggleLogin() {
        setOpenAtLogin(!FileManager.default.fileExists(atPath: launchAgentPath))
    }

    // MARK: Remote Control
    //
    // Claude Code only connects a running session from inside it, so for one that isn't connected
    // the menu says where to run /remote-control rather than doing it.

    @objc func toggleRemote(_ sender: NSMenuItem) { setRemote(sender.state != .on) }

    /// Once, after setup: explain Remote Control and offer to turn it on, if Claude Code is here and
    /// you've never chosen either way (in /config, `agents remote`, or this prompt)
    func offerRemoteControlIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "RemoteControlOffered") else { return }
        DispatchQueue.global(qos: .utility).async {
            let snap = Agents.snapshot()
            DispatchQueue.main.async {
                guard snap.remoteOn != nil else { return }      // no Claude Code yet: ask once it's here
                defaults.set(true, forKey: "RemoteControlOffered")
                guard snap.remoteUnset else { return }
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Answer your agents from your phone?"
                alert.informativeText = """
                    Claude Code's Remote Control connects each new Claude Code session to the Claude app \
                    and claude.ai/code. With the lid closed you can answer a permission prompt or a question \
                    from anywhere, and the app sends you a push when an agent needs you.

                    Your code keeps running on this Mac, and sessions show only in your own Claude account. \
                    It needs a Claude Pro, Max, Team or Enterprise plan.

                    Change it any time: the cup → Settings → Connect new Claude sessions to your phone, \
                    or `agents remote on` / `off` in a terminal.
                    """
                alert.addButton(withTitle: "Turn On")
                alert.addButton(withTitle: "Not Now")
                if alert.runModal() == .alertFirstButtonReturn { self.setRemote(true) }
            }
        }
    }

    func setRemote(_ turnOn: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Agents.run(["remote", turnOn ? "on" : "off"])
            DispatchQueue.main.async {
                if result.status != 0 {
                    let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.notify("Couldn't change Remote Control", message.isEmpty ? "Run `agents remote` in a terminal." : message)
                } else if turnOn {
                    self.notify("Remote Control on for new Claude sessions",
                                "Answer them from claude.ai/code or the Claude app. Sessions already open: run /remote-control in them.")
                } else {
                    self.notify("Remote Control off for new Claude sessions",
                                "Connected sessions stay on until you run /remote-control in them.")
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

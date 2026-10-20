// Overflow Monitor: menu bar app showing internal disk free space, the overflow volume,
// and the weekly archive job. Lets you run the archive by hand.
import Cocoa
import ServiceManagement

let home = FileManager.default.homeDirectoryForCurrentUser.path
let support = "\(home)/Library/Application Support/Overflow"
let script = "\(support)/overflow-archive.sh"
let jobLabel = "com.overflow.archive"
let lowGB = 15.0, criticalGB = 8.0

/// Configuration as reported by the script itself (single source of truth).
struct Config { var dest = "/Volumes/Overflow"; var folderSources: [(path: String, days: Int)] = [] }
func loadConfig() -> Config {
    var c = Config()
    guard FileManager.default.fileExists(atPath: script) else { return c }
    for line in run(["/bin/zsh", script, "--print-config"]).1.split(separator: "\n") {
        if line.hasPrefix("DEST=") { c.dest = String(line.dropFirst(5)) }
        if line.hasPrefix("FOLDER=") {
            let spec = line.dropFirst(7).split(separator: "|", maxSplits: 1).map(String.init)
            c.folderSources.append((spec[0], Int(spec.count > 1 ? spec[1] : "14") ?? 14))
        }
    }
    return c
}

func gb(_ b: Int64) -> Double { Double(b) / 1e9 }
func fmt(_ g: Double) -> String { g >= 100 ? String(format: "%.0f GB", g) : String(format: "%.1f GB", g) }

struct Volume { let free: Double; let total: Double }
func volume(_ path: String) -> Volume? {
    let url = URL(fileURLWithPath: path)
    guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
          let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return nil }
    return Volume(free: gb(free), total: gb(Int64(total)))
}

@discardableResult
func run(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

struct LastRun { let when: String; let summary: String; let moved: Int }
func lastRun(_ stickLog: String) -> LastRun? {
    guard let text = try? String(contentsOfFile: stickLog, encoding: .utf8) else { return nil }
    let lines = text.split(separator: "\n").map(String.init)
    guard let doneIdx = lines.lastIndex(where: { $0.contains(" done. ") }) else { return nil }
    let startIdx = lines[..<doneIdx].lastIndex(where: { $0.contains("== archive run") }) ?? 0
    let moved = lines[startIdx...doneIdx].filter { $0.contains(" moved ") }.count
    let done = lines[doneIdx]
    let when = String(done.prefix(16))
    let summary = done.components(separatedBy: " done. ").last ?? done
    return LastRun(when: when, summary: summary, moved: moved)
}

func jobLoaded() -> Bool { run(["/bin/launchctl", "print", "gui/\(getuid())/\(jobLabel)"]).0 == 0 }

func folderCounts(_ acDir: String) -> (local: Int, archived: Int) {
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: acDir) else { return (0, 0) }
    var local = 0, archived = 0
    for name in items where !name.hasPrefix(".") {
        let p = "\(acDir)/\(name)"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p), let type = attrs[.type] as? FileAttributeType else { continue }
        if type == .typeSymbolicLink { archived += 1 } else if type == .typeDirectory { local += 1 }
    }
    return (local, archived)
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item: NSStatusItem = {
        // Ask macOS to place the item near the right end (next to the system icons) so the
        // MacBook notch cannot hide it. Only applies the first time; the user can cmd-drag it after.
        let key = "NSStatusItem Preferred Position OverflowMonitor"
        if UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(40, forKey: key) }
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        i.autosaveName = "OverflowMonitor"
        return i
    }()
    let menu = NSMenu()
    var busy = false
    var config = loadConfig()
    var overflow: String { config.dest }
    var marker: String { "\(overflow)/.overflow-stick" }
    var stickLog: String { "\(overflow)/_archive-log.txt" }

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        item.menu = menu
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(refreshSel), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(refreshSel), name: NSWorkspace.didUnmountNotification, object: nil)
    }
    @objc func refreshSel() { refresh() }
    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func refresh() {
        config = loadConfig()
        let root = volume("/")
        let stick = FileManager.default.fileExists(atPath: marker) ? volume(overflow) : nil
        let free = root?.free ?? 0
        // nil tint = template rendering, which follows the menu bar (white on dark, black on light)
        let symbol: String, tint: NSColor?
        if free < criticalGB { symbol = "exclamationmark.triangle.fill"; tint = .systemRed }
        else if free < lowGB { symbol = "externaldrive.fill.badge.exclamationmark"; tint = .systemOrange }
        else if stick == nil { symbol = "externaldrive.badge.xmark"; tint = nil }
        else { symbol = "externaldrive.fill"; tint = nil }
        if let b = item.button {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Overflow Monitor")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            img?.isTemplate = true
            b.image = img
            b.imagePosition = .imageLeading
            b.title = " " + fmt(free)
            b.contentTintColor = tint
            b.toolTip = "Internal disk: \(fmt(free)) free"
        }
        buildMenu(root: root, stick: stick)
    }

    func line(_ title: String, _ indent: Bool = false) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: nil, keyEquivalent: ""); m.isEnabled = false
        m.indentationLevel = indent ? 1 : 0
        return m
    }
    func action(_ title: String, _ sel: Selector, enabled: Bool = true) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: ""); m.target = self; m.isEnabled = enabled; return m
    }

    func buildMenu(root: Volume?, stick: Volume?) {
        menu.removeAllItems()
        if let r = root {
            let used = Int((1 - r.free / r.total) * 100)
            let state = r.free < criticalGB ? "  ⚠︎ critical" : r.free < lowGB ? "  ⚠︎ getting low" : ""
            menu.addItem(line("Internal disk: \(fmt(r.free)) free of \(fmt(r.total))  (\(used)% used)\(state)"))
        }
        if let s = stick {
            menu.addItem(line("Overflow stick: \(fmt(s.total - s.free)) used, \(fmt(s.free)) free"))
        } else {
            menu.addItem(line("Overflow stick: not connected"))
        }
        for src in config.folderSources {
            let c = folderCounts(src.path)
            let name = (src.path as NSString).lastPathComponent
            menu.addItem(line("\(name): \(c.local) folders local, \(c.archived) on stick  (idle \(src.days) d)"))
        }
        if !FileManager.default.fileExists(atPath: script) {
            menu.addItem(line("⚠︎ archive script missing: run install.sh"))
        }
        menu.addItem(.separator())
        if let lr = lastRun(stickLog) {
            menu.addItem(line("Last archive: \(lr.when)"))
            menu.addItem(line("\(lr.moved) items moved, \(lr.summary)", true))
        } else {
            menu.addItem(line(stick == nil ? "Last archive: unknown (stick not connected)" : "Last archive: never"))
        }
        menu.addItem(line(jobLoaded() ? "Weekly job: scheduled, Sundays 3:00 AM" : "Weekly job: NOT loaded"))
        menu.addItem(.separator())
        let can = stick != nil && !busy
        menu.addItem(action(busy ? "Archive running…" : "Preview archive (dry run)", #selector(dryRun), enabled: can))
        menu.addItem(action("Archive now", #selector(archiveNow), enabled: can))
        menu.addItem(action("Archive now, aggressive (7 days)", #selector(archiveAggressive), enabled: can))
        menu.addItem(.separator())
        menu.addItem(action("Open archive log", #selector(openLog), enabled: stick != nil))
        menu.addItem(action("Show Overflow in Finder", #selector(openStick), enabled: stick != nil))
        menu.addItem(action("Eject Overflow", #selector(eject), enabled: stick != nil))
        menu.addItem(.separator())
        let login = action("Start at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Quit Overflow Monitor", #selector(quit)))
    }

    func runScript(_ args: [String], env: [String: String] = [:], title: String) {
        busy = true; refresh()
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [script] + args
            var e = ProcessInfo.processInfo.environment; env.forEach { e[$0] = $1 }; p.environment = e
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            var out = ""
            do { try p.run(); out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit() }
            catch { out = "Could not start the script: \(error)" }
            DispatchQueue.main.async {
                self.busy = false; self.refresh()
                self.showOutput(title: title, text: out)
            }
        }
    }
    func showOutput(title: String, text: String) {
        let lines = text.split(separator: "\n")
        let summary = lines.last.map(String.init) ?? "(no output)"
        let moved = lines.filter { $0.contains("would move") || $0.hasPrefix("moved") }.count
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(moved) items. \(summary)"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false; tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.string = text.isEmpty ? "(no output)" : text
        scroll.documentView = tv; scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func dryRun() { runScript([], title: "Archive preview (nothing was moved)") }
    @objc func archiveNow() { runScript(["--run"], title: "Archive finished") }
    @objc func archiveAggressive() {
        let a = NSAlert(); a.messageText = "Archive with 7-day threshold?"
        a.informativeText = "Moves project folders whose small files are untouched for 7 days (instead of the configured threshold), plus the usual file sources. Folders stay reachable through symlinks while the stick is connected."
        a.addButton(withTitle: "Archive"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { runScript(["--run"], env: ["FOLDER_DAYS": "7"], title: "Archive finished (7-day)") }
    }
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: stickLog)) }
    @objc func openStick() { NSWorkspace.shared.open(URL(fileURLWithPath: overflow)) }
    @objc func eject() {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: overflow)) }
        catch {
            let a = NSAlert(); a.messageText = "Could not eject Overflow"; a.informativeText = "\(error.localizedDescription)\n\nSomething is probably using a file on it (a Finder window or a terminal inside an archived folder)."
            NSApp.activate(ignoringOtherApps: true); a.runModal()
        }
        refresh()
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Could not change login setting"; a.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true); a.runModal()
        }
        refresh()
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

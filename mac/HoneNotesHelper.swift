// Hone Notes — macOS helper (menu-bar agent)
//
// Mirrors the Windows tray helper: it opens the app page in Chrome/Edge "app mode", stays in the
// menu bar, and serves http://localhost:47831 so the page's "Copy report" button can:
//   1. put the screenshots on the pasteboard as real image FILES (what upload boxes accept), and
//   2. make the next Cmd+V paste the notes, then each screenshot as its own paste.
//
// Requires Accessibility permission (System Settings > Privacy & Security > Accessibility) to watch
// for your Cmd+V and to paste on your behalf. The app asks for this on first run.
//
// Build it with build.sh (produces "Hone Notes.app"). Don't run this .swift file directly.

import Cocoa
import ApplicationServices

let PORT: UInt16 = 47831
let STEP_DELAY: useconds_t = 400_000   // microseconds between pastes (matches Windows 400ms)

// MARK: - Logging

let logURL: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HoneNotes", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("helper.log")
}()

func log(_ line: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let text = "\(stamp)  \(line)\n"
    if let data = text.data(using: .utf8) {
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Minimal localhost HTTP server (POSIX sockets)

final class HTTPServer {
    typealias Handler = (_ method: String, _ path: String, _ headers: [String: String], _ body: Data) -> (Int, String)
    private let handler: Handler
    private var listenFD: Int32 = -1

    init(handler: @escaping Handler) { self.handler = handler }

    /// Returns false if the port is already taken (another Hone Notes is running).
    func start() -> Bool {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        if listenFD < 0 { return false }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = PORT.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 { close(listenFD); listenFD = -1; return false }
        if listen(listenFD, 16) != 0 { close(listenFD); listenFD = -1; return false }

        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        return true
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { continue }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func readAll(_ fd: Int32, until sentinel: Data, max: Int) -> Data {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buf.count < max {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            if buf.range(of: sentinel) != nil { break }
        }
        return buf
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        let headerEnd = Data("\r\n\r\n".utf8)
        var data = readAll(fd, until: headerEnd, max: 64 * 1024)
        guard let sep = data.range(of: headerEnd) else { return }

        let headerData = data.subdata(in: 0..<sep.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return }
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return }
        let method = requestLine[0]
        let path = requestLine[1]

        var headers: [String: String] = [:]
        for line in lines {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        var body = data.subdata(in: sep.upperBound..<data.count)
        if let lenStr = headers["content-length"], let len = Int(lenStr) {
            var chunk = [UInt8](repeating: 0, count: 4096)
            while body.count < len {
                let n = read(fd, &chunk, min(chunk.count, len - body.count))
                if n <= 0 { break }
                body.append(contentsOf: chunk[0..<n])
            }
        }

        let (status, jsonBody) = handler(method, path, headers, body)
        var response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "ERR")\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Access-Control-Allow-Headers: Content-Type\r\n"
        response += "Access-Control-Allow-Private-Network: true\r\n"
        response += "Content-Type: application/json\r\n"
        let bodyData = Data(jsonBody.utf8)
        response += "Content-Length: \(bodyData.count)\r\n\r\n"
        var out = Data(response.utf8); out.append(bodyData)
        out.withUnsafeBytes { _ = write(fd, $0.baseAddress, out.count) }
    }
}

// MARK: - Helper app

final class HoneNotes: NSObject, NSApplicationDelegate {
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var statusItem: NSStatusItem!
    var server: HTTPServer!

    // Armed state for the one-shot Cmd+V takeover
    var pendingText: String = ""
    var pendingFiles: [URL] = []
    var eventTap: CFMachPort?
    var expiry: Timer?
    var injecting = false   // true while WE post Cmd+V, so our own events pass through the tap

    func applicationDidFinishLaunching(_ note: Notification) {
        server = HTTPServer(handler: { [weak self] m, p, h, b in self?.handle(m, p, h, b) ?? (500, "{}") })
        if !server.start() {
            // Another Hone Notes already owns the port: ask it to open its window, then quit.
            pingOpen()
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "HN"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Hone Notes", action: #selector(openApp), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        // Prompt for Accessibility so Copy report can watch Cmd+V and paste for you.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        log("Helper started")
        openApp()
    }

    // MARK: Browser

    var pageURL: String {
        let page = Bundle.main.resourcePath! + "/index.html"
        let encoded = page.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? page
        return "file://\(encoded)#k=\(token)"
    }

    @objc func openApp() {
        let browsers = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        ]
        for exe in browsers where FileManager.default.fileExists(atPath: exe) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: exe)
            task.arguments = ["--app=\(pageURL)"]
            try? task.run()
            return
        }
        // No Chrome/Edge: open in the default browser (works, but not its own window)
        if let url = URL(string: pageURL) { NSWorkspace.shared.open(url) }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func pingOpen() {
        guard let url = URL(string: "http://localhost:\(PORT)/open") else { return }
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 2)
    }

    // MARK: HTTP handling

    func handle(_ method: String, _ path: String, _ headers: [String: String], _ body: Data) -> (Int, String) {
        if method == "OPTIONS" { return (204, "") }
        if path == "/open" {
            DispatchQueue.main.async { self.openApp() }
            return (200, "{\"ok\":true}")
        }
        if path == "/copy", method == "POST" {
            let origin = headers["origin"]
            if let o = origin, o != "null" { return (403, "{\"ok\":false,\"error\":\"origin\"}") }
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let tok = obj["token"] as? String, tok == token else {
                return (403, "{\"ok\":false,\"error\":\"token\"}")
            }
            let text = (obj["text"] as? String) ?? ""
            let images = (obj["images"] as? [[String: Any]]) ?? []
            if images.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (400, "{\"ok\":false,\"error\":\"empty\"}")
            }
            let files = writeImages(images)
            var both = false
            DispatchQueue.main.sync { both = self.arm(text: text, files: files) }
            return (200, "{\"ok\":true,\"images\":\(files.count),\"both\":\(both ? "true" : "false")}")
        }
        return (404, "{\"ok\":false,\"error\":\"not found\"}")
    }

    func writeImages(_ images: [[String: Any]]) -> [URL] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HoneNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Clear old batches
        if let old = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for u in old where u.hasDirectoryPath { try? FileManager.default.removeItem(at: u) }
        }
        let dir = root.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var urls: [URL] = []
        for (i, img) in images.enumerated() {
            guard let name = img["name"] as? String, let b64 = img["data"] as? String,
                  let data = Data(base64Encoded: b64) else { continue }
            let ext = safeExt(name)
            let file = dir.appendingPathComponent("screenshot-\(i + 1)\(ext)")
            try? data.write(to: file)
            urls.append(file)
        }
        return urls
    }

    func safeExt(_ name: String) -> String {
        let ext = "." + (name as NSString).pathExtension.lowercased()
        return [".png", ".jpg", ".gif", ".webp", ".bmp"].contains(ext) ? ext : ".png"
    }

    // MARK: Clipboard + one-shot Cmd+V

    func writeFilesToPasteboard(_ files: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(files as [NSURL])
    }

    func writeTextToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Returns true when the next Cmd+V will paste notes (if any) + each screenshot separately.
    func arm(text: String, files: [URL]) -> Bool {
        disarm()
        if files.isEmpty { writeTextToPasteboard(text); return false }
        writeFilesToPasteboard(files)

        guard installEventTap() else {
            log("Copy report: no Accessibility permission — can't take over Cmd+V")
            return false
        }
        pendingText = text
        pendingFiles = files
        log("Copy report: armed with \(files.count) screenshot(s)\(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ", no notes" : " + notes")")
        expiry = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in self?.disarm() }
        return true
    }

    func disarm() {
        pendingText = ""
        pendingFiles = []
        expiry?.invalidate(); expiry = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    func installEventTap() -> Bool {
        if eventTap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<HoneNotes>.fromOpaque(refcon!).takeUnretainedValue()
            return me.onKeyDown(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        return true
    }

    let userDataMarker: Int64 = 0x484F4E45  // "HONE" — marks our own synthetic events

    func onKeyDown(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Let our own injected Cmd+V pass straight through
        if injecting || event.getIntegerValueField(.eventSourceUserData) == userDataMarker {
            return Unmanaged.passUnretained(event)
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let isV = keycode == 9
        let cmd = event.flags.contains(.maskCommand)
        if isV && cmd && !pendingFiles.isEmpty {
            let text = pendingText
            let files = pendingFiles
            disarm()
            DispatchQueue.main.async { self.performPaste(text: text, files: files) }
            return nil   // swallow this Cmd+V; we'll do the pasting
        }
        return Unmanaged.passUnretained(event)
    }

    func performPaste(text: String, files: [URL]) {
        let front = frontmostWindowTitle()
        log("Cmd+V caught in '\(front)': pasting \(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "notes + ")\(files.count) screenshot(s)")
        DispatchQueue.global(qos: .userInitiated).async {
            self.waitForKeysReleased()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.sync { self.writeTextToPasteboard(text) }
                usleep(100_000)
                self.sendCmdV()
                log("  notes pasted")
            }
            for file in files {
                usleep(STEP_DELAY)
                DispatchQueue.main.sync { self.writeFilesToPasteboard([file]) }
                usleep(100_000)
                self.sendCmdV()
                log("  pasted \(file.lastPathComponent)")
            }
            usleep(STEP_DELAY)
            DispatchQueue.main.sync { self.writeFilesToPasteboard(files) }  // leave all on clipboard
            log("  done")
        }
    }

    func waitForKeysReleased() {
        for _ in 0..<60 {  // up to 3s
            let cmd = CGEventSource.keyState(.combinedSessionState, key: 0x37)   // Command
            let v = CGEventSource.keyState(.combinedSessionState, key: 0x09)     // V
            if !cmd && !v { return }
            usleep(50_000)
        }
    }

    func sendCmdV() {
        injecting = true
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        down?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: userDataMarker)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        up?.flags = .maskCommand
        up?.setIntegerValueField(.eventSourceUserData, value: userDataMarker)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
        usleep(30_000)
        injecting = false
    }

    func frontmostWindowTitle() -> String {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return "" }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        for info in infoList {
            if let pid = info[kCGWindowOwnerPID as String] as? Int, pid == Int(frontPID),
               let name = info[kCGWindowName as String] as? String, !name.isEmpty {
                return name
            }
        }
        return ""
    }
}

let app = NSApplication.shared
let delegate = HoneNotes()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon
app.run()

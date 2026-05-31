import SwiftUI
import AppKit
import AVFoundation

// MARK: - Defaults

enum Config {
    static let defaultEndpoint = "http://localhost:8000/v1/chat/completions"
    static let defaultModel    = "Qwen/Qwen3-ASR-0.6B"
}

extension Notification.Name {
    /// ContentView → AppDelegate request to resize the panel.
    /// userInfo["height"] : Double — desired window height.
    static let asrbarRequestResize = Notification.Name("asrbarRequestResize")
}

// Brand palette
enum Palette {
    static let idleTop    = Color(red: 1.00, green: 0.72, blue: 0.22)  // light orange
    static let idleBottom = Color(red: 1.00, green: 0.46, blue: 0.06)  // deep orange
    static let recTop     = Color(red: 1.00, green: 0.40, blue: 0.28)  // warm red
    static let recBottom  = Color(red: 0.94, green: 0.18, blue: 0.12)
    static let glowIdle   = Color.orange
    static let glowRec    = Color(red: 1.00, green: 0.30, blue: 0.20)
}

/// NSHostingView aggressively propagates SwiftUI's intrinsicContentSize to
/// the containing NSWindow, overwriting contentMinSize/Max and resizing the
/// panel back to its "ideal" size after our explicit setFrame. Returning
/// `noIntrinsicMetric` removes that channel — the panel is then sized
/// strictly by our resize handler.
final class NonSizingHostingView<Root: View>: NSHostingView<Root> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

// MARK: - App entry

@main
struct ASRBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    private var resizeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 140),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentMinSize = NSSize(width: 280, height: 130)
        panel.contentMaxSize = NSSize(width: 520, height: 4000)
        // Disable macOS Resume so a previous, possibly oversized, frame
        // can't be restored on launch and fight our computed size.
        panel.isRestorable = false
        // .nonactivatingPanel keeps the app's other windows alive when this
        // floats, but it also blocks the TextField inside from grabbing
        // keyboard focus. Becoming key only on demand fixes that.
        panel.becomesKeyOnlyIfNeeded = true
        self.panel = panel

        // SwiftUI requests panel resize via NotificationCenter; we animate
        // the change while keeping the top edge fixed so the title bar
        // doesn't jump. We also lock contentMin/Max height to the target —
        // otherwise NSHostingView's intrinsicContentSize will resize the
        // panel back to whatever SwiftUI thinks is "ideal".
        self.resizeObserver = NotificationCenter.default.addObserver(
            forName: .asrbarRequestResize, object: nil, queue: .main
        ) { [weak panel] note in
            guard
                let panel = panel,
                let h = note.userInfo?["height"] as? Double
            else { return }
            let H = CGFloat(h)
            // Lock content height so NSHostingView / macOS can't push the
            // panel away from the size we just computed.
            panel.contentMinSize = NSSize(width: 280, height: H)
            panel.contentMaxSize = NSSize(width: 520, height: H)
            var f = panel.frame
            let dy = H - f.size.height
            f.size.height = H
            f.origin.y -= dy                              // keep top edge fixed
            panel.setFrame(f, display: true, animate: true)
        }

        let host = NonSizingHostingView(rootView: ContentView())
        if #available(macOS 13.0, *) {
            host.sizingOptions = []
        }
        panel.contentView = host
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    // SwiftUI popovers are backed by their own NSWindow; when one closes
    // while our panel is a `.nonactivatingPanel`, AppKit may treat it as
    // "last window closed" and quit the app. So we never auto-terminate on
    // window close — the X button is wired explicitly via `windowShouldClose`
    // below.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

// MARK: - Recorder

final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var level: Float = 0
    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var fileURL: URL?

    func start() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("asrbar-\(Int(Date().timeIntervalSince1970)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { return }
            recorder = r
            fileURL = url
            isRecording = true
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                guard let self = self, let r = self.recorder else { return }
                r.updateMeters()
                let db = r.averagePower(forChannel: 0)
                self.level = max(0, min(1, (db + 50) / 50))
            }
        } catch {
            NSLog("recorder start failed: \(error)")
        }
    }

    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        levelTimer?.invalidate(); levelTimer = nil
        isRecording = false
        level = 0
        return fileURL
    }
}

// MARK: - ASR client

enum ASRError: LocalizedError {
    case http(Int, String)
    case parse(String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(160))"
        case .parse(let msg):           return "parse failed: \(msg)"
        }
    }
}

struct ASRClient {
    /// Always uses Qwen3-ASR's built-in auto language detection (no system prompt).
    static func transcribe(fileURL: URL, endpoint: String, model: String) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw ASRError.parse("invalid URL: \(endpoint)")
        }
        let data = try Data(contentsOf: fileURL)
        let b64 = data.base64EncodedString()
        let dataURL = "data:audio/wav;base64,\(b64)"

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.01,           // vLLM rejects temperature < 0.01
            "messages": [[
                "role": "user",
                "content": [["type": "audio_url", "audio_url": ["url": dataURL]]],
            ]],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 120

        let (respData, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code != 200 {
            throw ASRError.http(code, String(data: respData, encoding: .utf8) ?? "")
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let msg = choices.first?["message"] as? [String: Any],
            let text = msg["content"] as? String
        else { throw ASRError.parse("unexpected response shape") }
        return stripWrapper(text)
    }

    private static func stripWrapper(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^language\s+\S+\s*<asr_text>([\s\S]*?)(?:</asr_text>)?$"#
        if let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let m = rx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let r = Range(m.range(at: 1), in: t) {
            return String(t[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}

// MARK: - UI

struct ContentView: View {
    @AppStorage("vllmEndpoint") private var endpoint: String = Config.defaultEndpoint
    @AppStorage("vllmModel")    private var model:    String = Config.defaultModel

    @StateObject private var recorder = AudioRecorder()
    @State private var status: String = "Click mic or hold ␣ to talk"
    @State private var lastText: String = ""
    @State private var busy = false
    @State private var copiedFlash = false
    @State private var showSettings = false
    // Captures which button started the current recording so the stop path
    // knows whether to append or replace.
    @State private var appendMode = false

    // Layout overhead = everything in the window EXCEPT the result-card's
    // text content. Titlebar is NOT counted: with `.fullSizeContentView` it
    // overlays the SwiftUI content, it does not add height.
    //   top pad 6 + mic 60 + spacing 6 + status 14 + spacing 6
    //   + card vertical padding 16 + bottom pad 10 = 118
    private static let chrome: Double = 118
    // Single-line text height at size-12 (ceil of system line height).
    private static let lineHeight: Double = 17
    // Layout offset that subtracts everything left/right of the text in the
    // result card: outer pad 10*2 + gear 22 + HStack spacing 6
    //              + inner pad 10*2 + inner spacing 6 + copy 20 = 94
    private static let cardSideChrome: CGFloat = 94
    private static let minHeight: Double = 140

    private static var maxHeight: Double {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(400, screen - 80)
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 1.00, green: 0.86, blue: 0.36).opacity(0.94),
                    Color(red: 1.00, green: 0.68, blue: 0.22).opacity(0.82),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 6) {
                HStack(spacing: 24) {
                    RecordButton(
                        isActive: recorder.isRecording && !appendMode,
                        isEnabled: !busy && (!recorder.isRecording || !appendMode),
                        busy: busy,
                        level: recorder.level,
                        idleIcon: "mic.fill",
                        onTap: { toggle(append: false) }
                    )
                    RecordButton(
                        isActive: recorder.isRecording && appendMode,
                        isEnabled: !busy
                            && (recorder.isRecording ? appendMode : !lastText.isEmpty),
                        busy: busy,
                        level: recorder.level,
                        idleIcon: "mic.badge.plus",
                        onTap: { toggle(append: true) }
                    )
                }

                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .multilineTextAlignment(.center)

                HStack(alignment: .top, spacing: 6) {
                    Button { showSettings.toggle() } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.secondary.opacity(0.85))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Server settings")
                    .popover(isPresented: $showSettings, arrowEdge: .top) {
                        SettingsView(endpoint: $endpoint,
                                     model: $model,
                                     onDone: { showSettings = false })
                    }

                    LastResultView(text: $lastText,
                                   copiedFlash: copiedFlash,
                                   onCopy: copyLast)
                }
                .padding(.horizontal, 10)
            }
            .padding(.top, 6)
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            installHotKey()
            resizeWindow(for: lastText)
        }
        .onChange(of: lastText) { newText in
            resizeWindow(for: newText)
        }
    }

    /// Measure the rendered height of the result text at the card's actual
    /// width and drive the panel to grow downward so every character fits.
    /// Top edge stays pinned (handled in AppDelegate).
    private func resizeWindow(for text: String) {
        let panelWidth = NSApp.windows.first(where: { $0 is NSPanel })?.frame.width ?? 300
        let textWidth = max(80, panelWidth - Self.cardSideChrome)
        let textHeight: Double
        if text.isEmpty {
            textHeight = Self.lineHeight
        } else {
            let attr = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 12)])
            let rect = attr.boundingRect(
                with: CGSize(width: textWidth,
                             height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            textHeight = max(Self.lineHeight, ceil(rect.height))
        }
        let target = min(Self.maxHeight,
                         max(Self.minHeight, Self.chrome + textHeight))
        NotificationCenter.default.post(
            name: .asrbarRequestResize, object: nil,
            userInfo: ["height": target])
    }

    // MARK: actions

    /// `append` is consulted only when starting a new recording; the stop path
    /// uses the `appendMode` captured at start-time.
    private func toggle(append: Bool) {
        if busy { return }
        if recorder.isRecording {
            guard let url = recorder.stop() else { return }
            busy = true; status = "Transcribing…"
            let shouldAppend = appendMode
            Task {
                do {
                    let text = try await ASRClient.transcribe(
                        fileURL: url, endpoint: endpoint, model: model)
                    await MainActor.run {
                        let combined = shouldAppend ? lastText + text : text
                        lastText = combined
                        copyToPasteboard(combined)
                        status = combined.isEmpty ? "(empty result)" : "✓ Copied · \(combined.count) chars"
                        flashCopied()
                    }
                } catch {
                    await MainActor.run { status = "✗ \(error.localizedDescription)" }
                }
                await MainActor.run { busy = false }
            }
        } else {
            appendMode = append
            status = append ? "Appending…" : "Recording…"
            recorder.start()
        }
    }

    private func copyLast() {
        guard !lastText.isEmpty else { return }
        copyToPasteboard(lastText)
        status = "✓ Copied"
        flashCopied()
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func flashCopied() {
        copiedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedFlash = false }
    }

    private func installHotKey() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // Don't intercept Space while user is typing in the settings popover.
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSText || responder is NSTextView {
                return event
            }
            if event.keyCode == 49 {  // space
                // Smart default: continue on top of the last result if there's
                // something to continue from, otherwise start a new take.
                if event.type == .keyDown, !event.isARepeat, !recorder.isRecording {
                    toggle(append: !lastText.isEmpty)
                }
                if event.type == .keyUp, recorder.isRecording {
                    toggle(append: false)   // ignored on the stop branch
                }
                return nil
            }
            return event
        }
    }
}

struct RecordButton: View {
    let isActive: Bool          // this button owns the in-flight recording
    let isEnabled: Bool
    let busy: Bool
    let level: Float
    let idleIcon: String        // SF Symbol shown when idle
    let onTap: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if isActive {
                    Circle()
                        .fill(Palette.glowRec.opacity(0.22))
                        .frame(width: 70 + CGFloat(level) * 40,
                               height: 70 + CGFloat(level) * 40)
                        .blur(radius: 4)
                        .animation(.easeOut(duration: 0.1), value: level)
                    Circle()
                        .stroke(Palette.glowRec.opacity(pulse ? 0.05 : 0.40), lineWidth: 1.5)
                        .frame(width: pulse ? 92 : 66, height: pulse ? 92 : 66)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: isActive
                                ? [Palette.recTop, Palette.recBottom]
                                : [Palette.idleTop, Palette.idleBottom],
                            startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 60, height: 60)
                    .shadow(color: (isActive ? Palette.glowRec : Palette.glowIdle).opacity(0.45),
                            radius: 10, x: 0, y: 2)

                Group {
                    if busy && isActive {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: isActive ? "stop.fill" : idleIcon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            // Pin the row to the main circle's footprint so the recording
            // glow / pulse rings can overflow visually without pushing
            // surrounding rows.
            .frame(width: 60, height: 60)
            .opacity(isEnabled ? 1.0 : 0.4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onAppear { pulse = true }
        .accessibilityLabel(isActive ? "Stop recording" : "Start recording")
    }
}

/// NSTextView whose intrinsic height tracks rendered content, so SwiftUI
/// can size the row to fit every wrapped line.
final class GrowingNSTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 17)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).size
        let h = ceil(used.height) + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: max(17, h))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }
}

struct EditableText: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> GrowingNSTextView {
        let tv = GrowingNSTextView()
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textColor = NSColor.labelColor
        tv.font = NSFont.systemFont(ofSize: 12)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.delegate = context.coordinator
        tv.string = text
        return tv
    }

    func updateNSView(_ tv: GrowingNSTextView, context: Context) {
        if tv.string != text {
            tv.string = text
            tv.invalidateIntrinsicContentSize()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: EditableText
        init(_ parent: EditableText) { self.parent = parent }
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? GrowingNSTextView else { return }
            tv.invalidateIntrinsicContentSize()
            if parent.text != tv.string { parent.text = tv.string }
        }
    }
}

struct LastResultView: View {
    @Binding var text: String
    let copiedFlash: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("No transcript yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                EditableText(text: $text)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Button(action: onCopy) {
                Image(systemName: copiedFlash ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copiedFlash ? Palette.idleBottom
                                     : (text.isEmpty ? Color.secondary.opacity(0.35) : Color.secondary))
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .help("Copy")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.orange.opacity(0.26), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Settings popover

struct SettingsView: View {
    @Binding var endpoint: String
    @Binding var model: String
    /// Use a caller-supplied closer instead of `@Environment(\.dismiss)`.
    /// SwiftUI's `dismiss` walks up to the nearest dismissable host; when this
    /// view is shown from a `.popover` whose owning `ContentView` is mounted
    /// via `NSHostingView` (not inside a SwiftUI Scene), `dismiss()` resolves
    /// to the host NSWindow — the panel — and closing it triggers
    /// `applicationShouldTerminateAfterLastWindowClosed`, killing the app.
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ASR Server")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Endpoint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("http://host:port/v1/chat/completions", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Qwen/Qwen3-ASR-0.6B", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            HStack {
                Button("Reset to defaults") {
                    endpoint = Config.defaultEndpoint
                    model    = Config.defaultModel
                }
                .buttonStyle(.link)
                .font(.caption)
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: - NSVisualEffectView bridge

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

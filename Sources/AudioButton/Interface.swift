import AppKit
import SwiftUI

struct MicrophoneChoice: Identifiable {
    let id: String
    let name: String
}

@MainActor final class AppViewModel: ObservableObject {
    enum Phase { case idle, starting, recording, saving }
    @Published var phase: Phase = .idle
    @Published var elapsed = "00:00"
    @Published var recordings: [RecentRecording] = []
    @Published var folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recordings/Audio Button")
    @Published var transcribingPath: String?
    @Published var progress = ""
    @Published var error: String?
    @Published var needsPermission = false
    @Published var canRetry = false
    @Published var recoveryCount = 0
    @Published var copied = ""
    @Published var keyConfigured = false
    @Published var autoTranscribe = true
    @Published var launchAtLogin = false
    @Published var canChangeFolder = true
    @Published var microphoneEnabled = true
    @Published var macAudioEnabled = true
    @Published var microphoneDevice = ""
    @Published var microphones: [MicrophoneChoice] = []
    @Published var microphoneLevel = 0.0
    @Published var macAudioLevel = 0.0
    @Published var microphoneSignal = "Ready"
    @Published var macAudioSignal = "Ready"
    @Published var panelHeight: CGFloat = 580
    var selectMicrophone: (String) -> Void = { _ in }
    var changeSources: (Bool, Bool) -> Void = { _, _ in }
    var pinPanel: () -> Void = {}
    var record: () -> Void = {}
    var settings: () -> Void = {}
    var openFolder: () -> Void = {}
    var changeFolder: () -> Void = {}
    var retry: () -> Void = {}
    var recover: () -> Void = {}
    var permissions: () -> Void = {}
    var toggleLogin: () -> Void = {}
    var quit: () -> Void = {}
    var saveKey: (String, @escaping (Result<Void, Error>) -> Void) -> Void = { _, _ in }
    var saveAutoTranscribe: (Bool) -> Void = { _ in }
    var finishSetup: () -> Void = {}
    private var copySequence = 0

    func copyAgentPrompt(_ transcript: URL) {
        copyToClipboard(AgentHandoffPrompt.make(for: transcript), feedback: "Agent prompt copied")
    }

    private func copyToClipboard(_ text: String, feedback: String) {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(text, forType: .string) ? feedback : "Could not copy. Try again."
        copySequence += 1
        let sequence = copySequence
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.copySequence == sequence else { return }
            self.copied = ""
        }
    }
}

struct RecordingPanel: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Text("Audio Button").font(.system(size: 17, weight: .semibold))
                Spacer()
                Menu {
                    Button("Settings…", action: model.settings)
                    Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { _ in model.toggleLogin() }))
                    Button("macOS Permissions…", action: model.permissions)
                    if model.recoveryCount > 0 {
                        Button("Recover \(model.recoveryCount) recording(s)", action: model.recover)
                    }
                    Divider()
                    Button("Quit Audio Button", action: model.quit)
                } label: { Image(systemName: "gearshape").font(.system(size: 15)) }
                .menuStyle(.borderlessButton).fixedSize().help("Settings and more")
                .accessibilityLabel("Settings and more")
            }

            Button(action: model.record) {
                HStack(spacing: 9) {
                    Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                    Text(recordLabel).fontWeight(.semibold)
                    Spacer()
                    if model.phase == .recording {
                        Text(model.elapsed).monospacedDigit()
                    } else if model.phase == .starting || model.phase == .saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(model.microphoneEnabled && model.macAudioEnabled ? "Mic + Mac audio"
                            : model.microphoneEnabled ? "Microphone" : "Mac audio")
                            .font(.system(size: 11)).opacity(0.8)
                    }
                }.font(.system(size: 14)).padding(.horizontal, 16).frame(height: 48)
                .foregroundStyle(.white)
                .background(model.phase == .recording ? Color.red : Color.indigo,
                    in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
                .disabled(model.phase == .starting || model.phase == .saving)
                .accessibilityLabel(recordLabel)

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Microphone", isOn: Binding(get: { model.microphoneEnabled },
                        set: { model.changeSources($0, model.macAudioEnabled) }))
                        .toggleStyle(.checkbox).font(.system(size: 12, weight: .medium))
                        .disabled(model.phase != .idle || !model.macAudioEnabled)
                    Menu {
                        Button("System default") { model.selectMicrophone("") }
                        Divider()
                        ForEach(model.microphones) { device in
                            Button(device.name) { model.selectMicrophone(device.id) }
                        }
                    } label: {
                        Text(model.microphones.first(where: { $0.id == model.microphoneDevice })?.name ?? "System default")
                            .font(.system(size: 10)).lineLimit(1)
                    }.menuStyle(.borderlessButton)
                        .disabled(model.phase != .idle || !model.microphoneEnabled)
                        .accessibilityLabel("Microphone device")
                    LevelMeter(level: model.microphoneLevel, color: .indigo)
                        .accessibilityLabel("Microphone level")
                        .accessibilityValue(String(Int(model.microphoneLevel * 100)) + " percent")
                    Text(model.microphoneEnabled ? model.microphoneSignal : "Off")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Mac audio", isOn: Binding(get: { model.macAudioEnabled },
                        set: { model.changeSources(model.microphoneEnabled, $0) }))
                        .toggleStyle(.checkbox).font(.system(size: 12, weight: .medium))
                        .disabled(model.phase != .idle || !model.microphoneEnabled)
                    Text("System sound").font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(height: 15)
                    LevelMeter(level: model.macAudioLevel, color: .mint)
                        .accessibilityLabel("Mac audio level")
                        .accessibilityValue(String(Int(model.macAudioLevel * 100)) + " percent")
                    Text(model.macAudioEnabled ? model.macAudioSignal : "Off")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 12)).lineLimit(3)
                    Spacer(minLength: 0)
                    if model.needsPermission {
                        Button("Open Settings", action: model.permissions).font(.system(size: 12))
                    } else if model.canRetry { Button("Retry", action: model.retry).font(.system(size: 12)) }
                }.padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }

            VStack(spacing: 9) {
                HStack {
                    Text("Recent recordings").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if model.transcribingPath != nil {
                        ProgressView().controlSize(.mini)
                        Text("Transcribing").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if model.recordings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("Your first recording goes here.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.recordings) { recording in
                                RecordingRow(recording: recording, model: model)
                            }
                        }
                    }.frame(maxHeight: .infinity)
                }
            }.frame(maxHeight: .infinity).layoutPriority(-1)
            Divider()
            HStack {
                Button(action: model.openFolder) {
                    Label("Open folder", systemImage: "folder")
                }.buttonStyle(.plain).font(.system(size: 12)).help(model.folder.path)
                Spacer()
                if !model.copied.isEmpty {
                    Text(model.copied).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.padding(18).frame(width: 430, height: model.panelHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            .simultaneousGesture(TapGesture().onEnded { model.pinPanel() })
    }

    private var recordLabel: String {
        switch model.phase {
        case .idle: "Start recording"
        case .starting: "Getting ready…"
        case .recording: "Stop & save"
        case .saving: "Saving…"
        }
    }
}

private struct LevelMeter: View {
    let level: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Double(index) / 20 < level
                            ? index >= 18 ? Color.orange : color
                            : Color.primary.opacity(0.09))
                        .frame(width: max(1, (geometry.size.width - 57) / 20))
                }
            }
        }.frame(height: 18).animation(.linear(duration: 0.1), value: level)
    }
}

private struct RecordingRow: View {
    let recording: RecentRecording
    @ObservedObject var model: AppViewModel
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(timestamp)
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                Text(recordingDate)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if model.transcribingPath == recording.audio.path {
                    Text("Transcribing…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    if let transcript = recording.transcript { model.copyAgentPrompt(transcript) }
                } label: {
                    Label("Share with agent", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                }.buttonStyle(.borderedProminent).controlSize(.small).tint(.indigo)
                    .disabled(recording.transcript == nil)
                    .help(recording.transcript == nil ? "Available when the transcript is ready"
                        : "Copy agent prompt with transcript file link")
                    .accessibilityLabel("Share with agent")
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [recording.audio, recording.transcript].compactMap { $0 })
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("Reveal the audio and transcript in their folder")
                    .accessibilityLabel("Show in Finder")
            }
        }.padding(.horizontal, 14).frame(height: 82)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .help(recording.audio.lastPathComponent)
    }
    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: recording.date)
    }
    private var recordingDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEE, d MMM yyyy"
        return formatter.string(from: recording.date)
    }
}

@MainActor final class SetupWindowController: NSWindowController {
    init(model: AppViewModel, firstRun: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = firstRun ? "Welcome to Audio Button" : "Audio Button Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SetupView(model: model, firstRun: firstRun))
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SetupView: View {
    @ObservedObject var model: AppViewModel
    let firstRun: Bool
    @State private var step = 0
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Spacer()
                Text("\(step + 1) / 2").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(step == 0 ? "Turn audio into text." : "Choose a home for your files.")
                    .font(.system(size: 23, weight: .semibold))
                Text(step == 0 ? "Connect your Groq account to transcribe recordings."
                    : "Audio and transcripts stay together in this folder.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if step == 0 {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://console.groq.com/keys")!)
                    } label: { Label("Get a free Groq key", systemImage: "arrow.up.right") }
                        .buttonStyle(.link)
                    Text("Sign up → Create API key → paste below.").font(.system(size: 12)).foregroundStyle(.secondary)
                    SecureField(model.keyConfigured ? "Key saved — paste to replace" : "Paste your Groq API key", text: $key)
                        .textFieldStyle(.roundedBorder).controlSize(.large)
                        .accessibilityLabel("Groq API key")
                    HStack(spacing: 5) {
                        if model.keyConfigured { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        Text(model.keyConfigured ? "Your key is saved on this Mac." : "Free plan available. Usage limits apply.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !firstRun {
                        Toggle("Transcribe automatically", isOn: Binding(get: { model.autoTranscribe },
                            set: { model.saveAutoTranscribe($0) })).font(.system(size: 12))
                    }
                    Text("Audio is sent to Groq for transcription.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill").font(.system(size: 26)).foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.folder.lastPathComponent).font(.system(size: 14, weight: .medium))
                            Text(model.folder.deletingLastPathComponent().path.replacingOccurrences(
                                of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    Button("Choose folder…", action: model.changeFolder).disabled(!model.canChangeFolder)
                    Text("Your first recording asks for microphone and Mac audio access.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if step > 0 { Button("Back") { step = 0; error = nil }.buttonStyle(.plain) }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(step == 0 ? "Continue" : firstRun ? "Ready to record" : "Done") {
                    if step == 1 { model.finishSetup(); return }
                    if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.keyConfigured {
                        step = 1; error = nil; return
                    }
                    saving = true; error = nil
                    model.saveKey(key) { result in
                        saving = false
                        switch result {
                        case .success: key = ""; step = 1
                        case .failure(let failure): error = failure.localizedDescription
                        }
                    }
                }.buttonStyle(.borderedProminent).tint(.indigo).controlSize(.large)
                    .disabled(saving || step == 0 && key.isEmpty && !model.keyConfigured)
            }
        }.padding(28).frame(width: 460, height: 440)
    }
}

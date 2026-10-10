import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@main
enum AudioButtonMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State { case idle, starting, recording, saving }
    private var state: State = .idle
    private var status: NSStatusItem!
    private var timer: Timer?
    private var meterTimer: Timer?
    private var hoverGeneration = 0
    private var hoverPanel = false
    private var recordingOptions = CaptureOptions()
    private var startedAt: Date?
    private var engine = CaptureEngine()
    private var lastFile: URL?
    private var quitting = false
    private var saveError: String?
    private var captureError: String?
    private var transcribing: URL?
    private var transcriptionProgress = ""
    private var lastTranscript: URL?
    private var transcriptionError: String?
    private var attemptedJobs = Set<String>()
    private let model = AppViewModel()
    private let popover = NSPopover()
    private var panelController: NSHostingController<RecordingPanel>!
    private var setupWindow: SetupWindowController?
    private var pendingJobs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "transcriptionJobs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "transcriptionJobs") }
    }
    private var root: URL {
        if let path = UserDefaults.standard.string(forKey: "recordingsFolder") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Recordings/Audio Button", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        installApplicationMenu()
        configureInterface()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self
        status.button?.action = #selector(clicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if let button = status.button {
            button.addTrackingArea(NSTrackingArea(rect: button.bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }
        if let path = UserDefaults.standard.string(forKey: "lastFile") {
            lastFile = URL(fileURLWithPath: path)
        }
        if let path = UserDefaults.standard.string(forKey: "lastTranscript") {
            lastTranscript = URL(fileURLWithPath: path)
        }
        engine.onFailure = { [weak self] error in self?.captureFailed(error) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick),
            userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        meterTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(updateMeters),
            userInfo: nil, repeats: true)
        RunLoop.main.add(meterTimer!, forMode: .common)
        updateIcon()
        processTranscriptions()
        // Existing users keep their setup; upgrading never asks for the key again.
        if !UserDefaults.standard.bool(forKey: "setupCompleted"),
           UserDefaults.standard.string(forKey: "recordingsFolder") != nil, model.keyConfigured {
            UserDefaults.standard.set(true, forKey: "setupCompleted")
        }
        refreshRecordings()
        if !UserDefaults.standard.bool(forKey: "setupCompleted") {
            DispatchQueue.main.async { self.configureGroq() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if setupWindow?.window?.isVisible == true { setupWindow?.present(); return true }
        if UserDefaults.standard.bool(forKey: "setupCompleted") { showPanel() }
        else { configureGroq() }
        return true
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let application = NSMenu()
        let settings = NSMenuItem(title: "Groq Settings…", action: #selector(configureGroq), keyEquivalent: ",")
        settings.target = self
        application.addItem(settings)
        application.addItem(.separator())
        application.addItem(NSMenuItem(title: "Quit Audio Button", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationItem.submenu = application
        main.addItem(applicationItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (name, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: name, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        if popover.isShown && hoverPanel { hoverPanel = false; NSApp.activate(ignoringOtherApps: true) }
        else if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }

    private func configureInterface() {
        model.pinPanel = { [weak self] in self?.hoverPanel = false }
        popover.behavior = .transient
        panelController = NSHostingController(rootView: RecordingPanel(model: model))
        // Size before showing: asynchronous SwiftUI intrinsic-size updates can
        // otherwise expand an already-positioned popover beyond the screen edge.
        panelController.sizingOptions = []
        popover.contentViewController = panelController
        model.keyConfigured = GroqKeyStore.exists()
        model.autoTranscribe = UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool != false
        model.microphoneEnabled = UserDefaults.standard.object(forKey: "microphoneEnabled") as? Bool != false
        model.macAudioEnabled = UserDefaults.standard.object(forKey: "macAudioEnabled") as? Bool != false
        if !model.microphoneEnabled && !model.macAudioEnabled { model.microphoneEnabled = true; model.macAudioEnabled = true }
        model.microphoneDevice = UserDefaults.standard.string(forKey: "microphoneDevice") ?? ""
        model.selectMicrophone = { [weak self] device in
            guard let self, self.state == .idle else { return }
            self.model.microphoneDevice = device
            UserDefaults.standard.set(device, forKey: "microphoneDevice")
        }
        model.changeSources = { [weak self] microphone, system in
            guard let self, self.state == .idle, microphone || system else { return }
            self.model.microphoneEnabled = microphone
            self.model.macAudioEnabled = system
            UserDefaults.standard.set(microphone, forKey: "microphoneEnabled")
            UserDefaults.standard.set(system, forKey: "macAudioEnabled")
        }
        model.record = { [weak self] in
            guard let self else { return }
            guard UserDefaults.standard.bool(forKey: "setupCompleted") else { self.configureGroq(); return }
            self.toggleFromMenu()
        }
        model.settings = { [weak self] in self?.configureGroq() }
        model.openFolder = { [weak self] in self?.openFolder() }
        model.changeFolder = { [weak self] in self?.chooseFolder() }
        model.retry = { [weak self] in self?.retryTranscriptions() }
        model.recover = { [weak self] in self?.recover() }
        model.permissions = { [weak self] in self?.openPermissions() }
        model.toggleLogin = { [weak self] in self?.toggleLogin() }
        model.quit = { [weak self] in self?.quit() }
        model.saveAutoTranscribe = { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: "autoTranscribe")
            self?.model.autoTranscribe = enabled
        }
        model.saveKey = { [weak self] key, completion in
            Task { @MainActor in
                do {
                    try await GroqTranscriber().verifyKey(key)
                    try await Task.detached { try GroqKeyStore.save(key) }.value
                    guard let self else { return }
                    self.model.keyConfigured = true
                    self.transcriptionError = nil
                    self.attemptedJobs.removeAll()
                    self.processTranscriptions()
                    self.updateIcon()
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }
        }
        model.finishSetup = { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
                guard FileManager.default.isWritableFile(atPath: self.root.path) else {
                    throw RecorderError.message("Choose a folder you can save files to.")
                }
                UserDefaults.standard.set(self.root.path, forKey: "recordingsFolder")
                UserDefaults.standard.set(true, forKey: "setupCompleted")
                self.setupWindow?.close()
                self.refreshRecordings()
                self.showPanel()
            } catch { self.showAlert(title: "Choose another folder", message: error.localizedDescription) }
        }
    }

    private func showPanel(activate: Bool = true) {
        guard let button = status?.button else { return }
        refreshRecordings()
        model.microphones = CaptureEngine.microphones().map { MicrophoneChoice(id: $0.uniqueID, name: $0.localizedName) }
        updateIcon()
        guard !popover.isShown else { return }
        sizePanel(for: button)
        hoverPanel = !activate
        if activate { NSApp.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if activate { popover.contentViewController?.view.window?.makeKey() }
    }

    private func sizePanel(for button: NSStatusBarButton) {
        let screen = button.window?.screen ?? NSScreen.main
        let anchor = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        let availableHeight = screen.map {
            min(anchor?.minY ?? $0.visibleFrame.maxY, $0.visibleFrame.maxY)
                - $0.visibleFrame.minY - 24 // Room for the arrow and window edges.
        } ?? 580
        model.panelHeight = max(1, min(model.recordings.isEmpty ? 440 : 580, availableHeight))
        let size = NSSize(width: 430, height: model.panelHeight)
        panelController.preferredContentSize = size
        panelController.view.setFrameSize(size)
        popover.contentSize = size
        panelController.view.layoutSubtreeIfNeeded()
    }

    @objc private func screenParametersChanged() {
        guard popover.isShown else { return }
        let activate = !hoverPanel
        popover.performClose(nil)
        showPanel(activate: activate)
    }

    private func refreshRecordings() {
        model.folder = root
        model.recordings = RecordingLibrary.recent(in: root)
        model.recoveryCount = AudioExporter.pending(in: root).count
    }

    private func startRecording() {
        recordingOptions = CaptureOptions(microphone: model.microphoneEnabled, systemAudio: model.macAudioEnabled,
            microphoneDeviceID: model.microphoneDevice.isEmpty ? nil : model.microphoneDevice)
        state = .starting
        saveError = nil
        captureError = nil
        updateIcon()
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let disk = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                if let bytes = disk.volumeAvailableCapacityForImportantUsage, bytes < 500_000_000 {
                    throw RecorderError.message("Less than 500 MB of disk space remains. Free some space before recording.")
                }
                try await engine.start(root: root, options: recordingOptions)
                startedAt = Date()
                state = .recording
                updateIcon()
                if quitting { stopRecording() }
            } catch {
                state = .idle
                captureError = error.localizedDescription
                updateIcon()
                showPanel()
                if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
    }

    private func stopRecording(reason: String? = nil) {
        guard state == .recording else { return }
        state = .saving
        updateIcon()
        let destinationRoot = root
        Task { @MainActor in
            do {
                if let directory = try await engine.stop() {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try AudioExporter.export(directory: directory, root: destinationRoot)
                    }.value
                    lastFile = result.url
                    UserDefaults.standard.set(result.url.path, forKey: "lastFile")
                    enqueueTranscription(result.url)
                    state = .idle
                    refreshRecordings()
                    updateIcon()
                    if let reason {
                        showAlert(title: "Recording saved", message: reason + "\n\n" + result.url.path)
                    } else if recordingOptions.microphone && !result.hasMicrophone {
                        showAlert(title: "Only system audio was recorded", message:
                            "The microphone did not provide audio. Check permissions and the selected input device in macOS settings.\n\n" + result.url.path)
                    }
                } else { state = .idle; updateIcon() }
            } catch {
                state = .idle
                saveError = error.localizedDescription
                updateIcon()
                showAlert(title: "Could not save the finished file", message:
                    error.localizedDescription + "\n\nThe original audio remains in .in-progress. Right-click the button → Recover Recordings.")
            }
            startedAt = nil
            if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    private func captureFailed(_ error: Error) {
        if state == .recording {
            stopRecording(reason: "macOS interrupted the recording. Audio captured before the interruption has been saved.\n" + error.localizedDescription)
        }
    }

    @objc private func tick() {
        guard state == .recording else { return }
        updateIcon()
        if recordingOptions.microphone, let startedAt, Date().timeIntervalSince(startedAt) > 5 {
            let health = engine.health()
            if health.microphoneBuffers == 0 {
                stopRecording(reason: "The microphone is not providing audio. Check its permission and the macOS input device.")
            } else if health.microphoneAge > 10 {
                stopRecording(reason: "The microphone stopped providing audio. Your recording is saved. Check the microphone connection and start a new recording.")
            }
        }
    }

    @objc private func updateMeters() {
        guard state == .recording else {
            if model.microphoneLevel != 0 { model.microphoneLevel = 0 }
            if model.macAudioLevel != 0 { model.macAudioLevel = 0 }
            if model.microphoneSignal != "Ready" { model.microphoneSignal = "Ready" }
            if model.macAudioSignal != "Ready" { model.macAudioSignal = "Ready" }
            return
        }
        let health = engine.health()
        model.microphoneLevel = RecordingLibrary.meterLevel(health.microphoneLevel)
        model.macAudioLevel = RecordingLibrary.meterLevel(health.systemLevel)
        model.microphoneSignal = health.microphoneBuffers == 0 ? "Waiting for audio"
            : health.microphoneAge > 0.5 ? "No signal" : health.microphoneLevel > 0.002 ? "Live" : "Silent"
        model.macAudioSignal = health.systemBuffers == 0 ? "Waiting for audio"
            : health.systemAge > 0.5 ? "No signal" : health.systemLevel > 0.002 ? "Live" : "Silent"
    }

    @objc func mouseEntered(with event: NSEvent) {
        hoverGeneration += 1
        let generation = hoverGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.hoverGeneration == generation,
                  UserDefaults.standard.bool(forKey: "setupCompleted"), self.setupWindow?.window?.isVisible != true else { return }
            self.showPanel(activate: false)
        }
    }

    @objc func mouseExited(with event: NSEvent) {
        hoverGeneration += 1
        closeHoverPanelWhenOutside(generation: hoverGeneration)
    }

    private func closeHoverPanelWhenOutside(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.hoverGeneration == generation, self.hoverPanel, self.popover.isShown else { return }
            if self.popover.contentViewController?.view.window?.frame.contains(NSEvent.mouseLocation) == true {
                self.closeHoverPanelWhenOutside(generation: generation)
            } else { self.popover.performClose(nil) }
        }
    }

    private func updateIcon() {
        guard let button = status?.button else { return }
        switch state {
        case .idle: model.phase = .idle
        case .starting: model.phase = .starting
        case .recording: model.phase = .recording
        case .saving: model.phase = .saving
        }
        model.elapsed = String(format: "%02d:%02d", Int(Date().timeIntervalSince(startedAt ?? Date())) / 60,
            Int(Date().timeIntervalSince(startedAt ?? Date())) % 60)
        model.transcribingPath = transcribing?.path
        model.progress = transcriptionProgress
        model.needsPermission = captureError?.hasPrefix("Allow Audio Button") == true
        model.error = captureError ?? (saveError != nil ? "Audio couldn't be saved. Recover it from Settings."
            : transcriptionError != nil ? "Audio saved. Transcription needs attention." : nil
        )
        model.canRetry = !pendingJobs.isEmpty && transcribing == nil
        model.canChangeFolder = state == .idle
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        let symbol: String
        switch state {
        case .idle:
            symbol = captureError != nil || saveError != nil || transcriptionError != nil ? "exclamationmark.circle"
                : transcribing != nil ? "text.bubble" : "mic.circle"
            button.title = ""
            button.contentTintColor = captureError != nil || saveError != nil || transcriptionError != nil ? .systemOrange
                : transcribing != nil ? .systemBlue : nil
            button.toolTip = "Audio Button — recordings and transcripts"
            if transcribing != nil { button.toolTip = "Transcribing with Groq. Click to view recordings." }
            if let transcriptionError { button.toolTip = transcriptionError + " Right-click to retry." }
        case .starting:
            symbol = "hourglass"
            button.title = ""
            button.contentTintColor = .systemOrange
            button.toolTip = "Preparing to record…"
        case .recording:
            symbol = "stop.circle.fill"
            let seconds = Int(Date().timeIntervalSince(startedAt ?? Date()))
            button.title = String(format: " %02d:%02d", seconds / 60, seconds % 60)
            button.contentTintColor = .systemRed
            button.toolTip = "Recording microphone and Mac audio. Click for Stop & save."
        case .saving:
            symbol = "arrow.down.circle"
            button.title = ""
            button.contentTintColor = .systemOrange
            button.toolTip = "Saving audio…"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.toolTip)
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel("Audio Button")
    }

    private func showMenu() {
        let menu = NSMenu()
        if state == .recording {
            let health = engine.health()
            let mic = health.microphoneBuffers > 0 ? "connected" : "waiting for audio"
            let system = health.systemBuffers > 0 ? "connected" : "waiting for audio"
            add("Microphone: \(mic) · Mac audio: \(system)", to: menu, action: nil)
        }
        add(state == .recording ? "Stop and Save" : "Start Recording", to: menu, action: #selector(toggleFromMenu))
            .isEnabled = state == .idle || state == .recording
        menu.addItem(.separator())
        add("Open Recordings Folder", to: menu, action: #selector(openFolder))
        if let lastFile {
            add("Last recording: \(lastFile.lastPathComponent)", to: menu, action: #selector(revealLast))
            add("Transcribe Last Recording", to: menu, action: #selector(transcribeLast))
                .isEnabled = transcribing?.path != lastFile.path
        }
        if let lastTranscript {
            add("Open Transcript", to: menu, action: #selector(openTranscript))
                .toolTip = lastTranscript.lastPathComponent
        }
        if transcribing != nil {
            add("Groq: transcribing \(transcriptionProgress)", to: menu, action: nil)
        }
        if !pendingJobs.isEmpty, transcribing == nil {
            add("Retry Transcription (\(pendingJobs.count))", to: menu, action: #selector(retryTranscriptions))
        }
        let pending = AudioExporter.pending(in: root).count
        if pending > 0, state == .idle {
            add("Recover Recordings (\(pending))", to: menu, action: #selector(recover))
        }
        menu.addItem(.separator())
        add("Choose Folder…", to: menu, action: #selector(chooseFolder)).isEnabled = state == .idle
        add("Groq Settings…", to: menu, action: #selector(configureGroq))
        let launch = add("Launch at Login", to: menu, action: #selector(toggleLogin))
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        add("macOS Permissions…", to: menu, action: #selector(openPermissions))
        add("How to Use", to: menu, action: #selector(help))
        menu.addItem(.separator())
        add("Quit Audio Button", to: menu, action: #selector(quit))
        status.menu = menu
        status.button?.performClick(nil)
        status.menu = nil
    }

    @discardableResult private func add(_ title: String, to menu: NSMenu, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleFromMenu() {
        guard UserDefaults.standard.bool(forKey: "setupCompleted") else { configureGroq(); return }
        if state == .idle { startRecording() } else if state == .recording { stopRecording() }
    }
    @objc private func openFolder() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
        } catch { showAlert(title: "Could not open the folder", message: error.localizedDescription) }
    }
    @objc private func revealLast() {
        if let lastFile { NSWorkspace.shared.activateFileViewerSelecting([lastFile]) }
    }
    @objc private func chooseFolder() {
        guard state == .idle else { return }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "recordingsFolder")
            refreshRecordings()
        }
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showAlert(title: "Launch at Login", message: error.localizedDescription) }
        updateIcon()
    }
    @objc private func openPermissions() {
        let section = captureError?.contains("microphone") == true ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section)!)
    }
    @objc private func help() {
        showAlert(title: "Audio Button", message:
            "Click the microphone in your menu bar, then Start recording.\nStop & save saves audio and automatically creates a transcript.\n\nShare with agent copies a prompt with the transcript file link. Show in Finder reveals the audio and transcript together.\n\nUse headphones for a cleaner recording.")
    }
    @objc private func recover() {
        guard state == .idle else { return }
        let directories = AudioExporter.pending(in: root)
        let destinationRoot = root
        state = .saving
        updateIcon()
        Task { @MainActor in
            var recovered = 0
            var failures: [String] = []
            for directory in directories {
                do {
                    let result = try await Task.detached {
                        try AudioExporter.export(directory: directory, root: destinationRoot)
                    }.value
                    lastFile = result.url
                    UserDefaults.standard.set(result.url.path, forKey: "lastFile")
                    enqueueTranscription(result.url)
                    recovered += 1
                } catch { failures.append(directory.lastPathComponent + ": " + error.localizedDescription) }
            }
            state = .idle
            refreshRecordings()
            saveError = failures.isEmpty ? nil : failures.joined(separator: "\n")
            updateIcon()
            showAlert(title: "Recordings recovered: \(recovered)",
                message: failures.isEmpty ? destinationRoot.path : failures.joined(separator: "\n\n"))
            if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }
    @objc private func willSleep() {
        stopRecording(reason: "Your Mac is going to sleep. The recording has been stopped and saved.")
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state == .idle { return .terminateNow }
        quitting = true
        if state == .recording { stopRecording() }
        return .terminateLater
    }
    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func configureGroq() {
        popover.performClose(nil)
        if setupWindow?.window?.isVisible == true {
            setupWindow?.present()
            return
        }
        model.keyConfigured = GroqKeyStore.exists()
        model.folder = root
        setupWindow = SetupWindowController(model: model,
            firstRun: !UserDefaults.standard.bool(forKey: "setupCompleted"))
        setupWindow?.present()
    }

    private func enqueueTranscription(_ file: URL, force: Bool = false) {
        guard force || UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool != false else { return }
        // Queue before contacting the API so a restart can resume the work.
        if !pendingJobs.contains(file.path) { pendingJobs.append(file.path) }
        attemptedJobs.remove(file.path)
        processTranscriptions()
    }

    private func processTranscriptions() {
        guard transcribing == nil else { return }
        guard let path = pendingJobs.first(where: { !attemptedJobs.contains($0) }) else { return }
        let file = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            pendingJobs.removeAll { $0 == path }
            processTranscriptions()
            return
        }
        attemptedJobs.insert(path)
        transcribing = file
        transcriptionProgress = "preparing"
        updateIcon()
        Task { @MainActor in
            do {
                // Local credential I/O stays away from the recording interface.
                guard let key = try await Task.detached(priority: .userInitiated, operation: {
                    try GroqKeyStore.read()
                }).value else {
                    throw RecorderError.message("No Groq API key is saved. Right-click → Groq Settings to add it, then retry transcription.")
                }
                let transcript = try await GroqTranscriber().transcribe(file: file, key: key) { current, total in
                    DispatchQueue.main.async {
                        self.transcriptionProgress = "\(current)/\(total)"
                        self.updateIcon()
                    }
                }
                lastTranscript = transcript
                UserDefaults.standard.set(transcript.path, forKey: "lastTranscript")
                pendingJobs.removeAll { $0 == path }
                transcriptionError = nil
            } catch {
                transcriptionError = error.localizedDescription
            }
            transcribing = nil
            refreshRecordings()
            updateIcon()
            processTranscriptions()
        }
    }

    @objc private func transcribeLast() {
        if let lastFile { enqueueTranscription(lastFile, force: true) }
    }
    @objc private func retryTranscriptions() {
        attemptedJobs.removeAll()
        transcriptionError = nil
        processTranscriptions()
        updateIcon()
    }
    @objc private func openTranscript() { if let lastTranscript { NSWorkspace.shared.open(lastTranscript) } }
}

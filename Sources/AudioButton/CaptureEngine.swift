import AVFoundation
import CoreMedia
import ScreenCaptureKit

struct CaptureHealth {
    var systemBuffers: Int
    var microphoneBuffers: Int
    var systemLevel: Float
    var microphoneLevel: Float
    var microphoneAge: TimeInterval
    var systemAge: TimeInterval
}

struct CaptureOptions {
    var microphone = true
    var systemAudio = true
    var microphoneDeviceID: String?
}

// Capture data belongs to `queue`; stream lifecycle is coordinated by the app's main thread.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
    }
    private let queue = DispatchQueue(label: "local.AudioButton.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var session: RecordingSession?
    private var stopping = false
    private var failed = false
    private var lastMicrophoneBuffer: Date?
    private var lastSystemBuffer: Date?
    var onFailure: (@MainActor (Error) -> Void)?

    func start(root: URL, options: CaptureOptions = CaptureOptions()) async throws {
        guard options.microphone || options.systemAudio else {
            throw RecorderError.message("Choose at least one audio source.")
        }
        if options.microphone {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CapturePermission.microphone }
            default: throw CapturePermission.microphone
            }
        }
        if let deviceID = options.microphoneDeviceID, options.microphone,
           !Self.microphones().contains(where: { $0.uniqueID == deviceID }) {
            throw RecorderError.message("This microphone isn't connected. Choose System default or another microphone.")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if CapturePermission.isSystemAudioDenial(error) { throw CapturePermission.systemAudio }
            throw RecorderError.message("Could not access Mac audio: " + error.localizedDescription)
        }
        guard let display = content.displays.first else {
            throw RecorderError.message("macOS could not provide system audio access: no active display was found.")
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = options.systemAudio
        configuration.captureMicrophone = options.microphone
        configuration.microphoneCaptureDeviceID = options.microphoneDeviceID
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // No screen output is attached, and no image or video is written.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        let newSession = try RecordingSession(root: root)
        queue.sync {
            session = newSession
            stopping = false
            failed = false
            lastMicrophoneBuffer = nil
            lastSystemBuffer = nil
        }
        stream = capture
        do {
            if options.systemAudio { try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            if options.microphone { try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
            try await capture.startCapture()
            if queue.sync(execute: { failed }) {
                throw RecorderError.message("macOS could not start delivering audio. Check permissions and try again.")
            }
        } catch {
            queue.sync { stopping = true }
            try? await capture.stopCapture()
            stream = nil
            queue.sync {
                newSession.system.close()
                newSession.microphone.close()
                if newSession.system.buffers == 0 && newSession.microphone.buffers == 0 {
                    try? FileManager.default.removeItem(at: newSession.directory)
                }
                session = nil
            }
            if CapturePermission.isSystemAudioDenial(error) { throw CapturePermission.systemAudio }
            throw error
        }
    }

    func stop() async throws -> URL? {
        queue.sync { stopping = true }
        let capture = stream
        stream = nil
        var stopError: Error?
        do { try await capture?.stopCapture() } catch { stopError = error }
        // Queue barrier drains callbacks and closes files before export begins.
        let directory = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            queue.async {
                guard let session = self.session else { continuation.resume(returning: nil); return }
                defer { self.session = nil }
                do {
                    try session.finish(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                    continuation.resume(returning: session.directory)
                } catch { continuation.resume(throwing: error) }
            }
        }
        // Even if macOS already stopped the stream, its recorded audio is saved.
        if directory == nil, let stopError { throw stopError }
        return directory
    }

    func health() -> CaptureHealth {
        queue.sync {
            CaptureHealth(systemBuffers: session?.system.buffers ?? 0,
                microphoneBuffers: session?.microphone.buffers ?? 0,
                systemLevel: lastSystemBuffer.map { Date().timeIntervalSince($0) < 0.3 ? session?.system.level ?? 0 : 0 } ?? 0,
                microphoneLevel: lastMicrophoneBuffer.map { Date().timeIntervalSince($0) < 0.3 ? session?.microphone.level ?? 0 : 0 } ?? 0,
                microphoneAge: lastMicrophoneBuffer.map { Date().timeIntervalSince($0) } ?? .infinity,
                systemAge: lastSystemBuffer.map { Date().timeIntervalSince($0) } ?? .infinity)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !failed, let session, CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer), type == .audio || type == .microphone else { return }
        do {
            let buffer = try Self.pcm(sampleBuffer)
            try session.append(buffer, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds,
                microphone: type == .microphone)
            if type == .microphone { lastMicrophoneBuffer = Date() }
            else { lastSystemBuffer = Date() }
        } catch {
            failed = true
            DispatchQueue.main.async { self.onFailure?(error) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard !self.stopping, !self.failed else { return }
            self.failed = true
            DispatchQueue.main.async { self.onFailure?(error) }
        }
    }

    static func pcm(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else {
            throw RecorderError.message("macOS provided an unknown audio format.")
        }
        buffer.frameLength = buffer.frameCapacity
        var retained: CMBlockBuffer?
        let size = MemoryLayout<AudioBufferList>.size +
            (max(1, Int(format.channelCount)) - 1) * MemoryLayout<AudioBuffer>.size
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size,
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
            bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retained)
        guard status == noErr else { throw RecorderError.message("Could not read audio: \(status)") }
        let source = UnsafeMutableAudioBufferListPointer(list)
        let target = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard source.count == target.count else { throw RecorderError.message("The number of audio channels changed.") }
        for index in source.indices {
            guard let from = source[index].mData, let to = target[index].mData,
                source[index].mDataByteSize <= target[index].mDataByteSize else {
                throw RecorderError.message("The audio buffer is incomplete.")
            }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return buffer
    }
}

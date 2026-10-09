import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct SessionManifest: Codable {
    var name: String
    var createdAt: Date
    var systemStart: Double?
    var microphoneStart: Double?
    var duration: Double?
}

/// Capture writes recoverable PCM first. A failed export never removes these files.
final class RecordingSession {
    static let sampleRate = 48_000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let directory: URL
    private(set) var manifest: SessionManifest
    let system: SourceTrack
    let microphone: SourceTrack

    init(root: URL, now: Date = Date()) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = formatter.string(from: now) + "_" + UUID().uuidString.prefix(6)
        directory = root.appendingPathComponent(".in-progress", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manifest = SessionManifest(name: name, createdAt: now)
        system = try SourceTrack(url: directory.appendingPathComponent("system.caf"))
        microphone = try SourceTrack(url: directory.appendingPathComponent("microphone.caf"))
        try saveManifest()
    }

    func append(_ buffer: AVAudioPCMBuffer, timestamp: Double, microphone isMic: Bool) throws {
        let track = isMic ? microphone : system
        let isFirst = track.firstTimestamp == nil
        try track.append(buffer, timestamp: timestamp)
        if isFirst {
            if isMic { manifest.microphoneStart = timestamp }
            else { manifest.systemStart = timestamp }
            try saveManifest()
        }
    }

    func finish(at timestamp: Double) throws {
        let starts = [manifest.systemStart, manifest.microphoneStart].compactMap { $0 }
        if let start = starts.min() { manifest.duration = max(0, timestamp - start) }
        system.close()
        microphone.close()
        try saveManifest()
    }

    private func saveManifest() throws {
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
}

/// Each source retains its own timestamps, including silence during gaps.
/// Input format changes (for example a Bluetooth mic) rebuild the converter.
final class SourceTrack {
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private(set) var firstTimestamp: Double?
    private(set) var frames: Int64 = 0
    private(set) var buffers = 0
    private(set) var level: Float = 0

    init(url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: RecordingSession.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ input: AVAudioPCMBuffer, timestamp: Double) throws {
        guard timestamp.isFinite, input.frameLength > 0 else {
            throw RecorderError.message("Received an invalid audio buffer.")
        }
        guard let file else { throw RecorderError.message("The recording has already stopped.") }
        let buffer = try convert(input)
        if firstTimestamp == nil { firstTimestamp = timestamp }
        let desired = Int64(((timestamp - firstTimestamp!) * RecordingSession.sampleRate).rounded())
        let difference = desired - frames
        // Ignore sub-millisecond timestamp jitter; larger gaps remain as silence.
        if difference > 48 { try writeSilence(frames: difference) }
        if difference < -48 {
            let skip = min(Int64(buffer.frameLength), -difference)
            if skip == Int64(buffer.frameLength) { return }
            let remaining = AVAudioFrameCount(Int64(buffer.frameLength) - skip)
            for channel in 0..<2 {
                let data = buffer.floatChannelData![channel]
                memmove(data, data.advanced(by: Int(skip)), Int(remaining) * MemoryLayout<Float>.size)
            }
            buffer.frameLength = remaining
        }
        var peak: Float = 0
        for channel in 0..<2 {
            for index in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(buffer.floatChannelData![channel][index]))
            }
        }
        level = peak
        try file.write(from: buffer)
        frames += Int64(buffer.frameLength)
        buffers += 1
    }

    func close() { file = nil; converter = nil }

    private func writeSilence(frames count: Int64) throws {
        let zero = AVAudioPCMBuffer(pcmFormat: RecordingSession.format, frameCapacity: 4096)!
        memset(zero.floatChannelData![0], 0, 4096 * MemoryLayout<Float>.size)
        memset(zero.floatChannelData![1], 0, 4096 * MemoryLayout<Float>.size)
        var remaining = count
        while remaining > 0 {
            zero.frameLength = AVAudioFrameCount(min(4096, remaining))
            try file!.write(from: zero)
            frames += Int64(zero.frameLength)
            remaining -= Int64(zero.frameLength)
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format == RecordingSession.format { return input }
        if inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: RecordingSession.format)
            converter?.primeMethod = .none
            inputFormat = input.format
        }
        guard let converter else { throw RecorderError.message("Could not convert the microphone format.") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) *
            RecordingSession.sampleRate / input.format.sampleRate) + 128)
        let output = AVAudioPCMBuffer(pcmFormat: RecordingSession.format, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error else { throw RecorderError.message("Could not convert the audio.") }
        return output
    }
}

struct ExportResult {
    let url: URL
    let hasSystem: Bool
    let hasMicrophone: Bool
}

enum AudioExporter {
    static func pending(in root: URL) -> [URL] {
        let directory = root.appendingPathComponent(".in-progress", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []).filter {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("session.json").path)
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Fixed-size buffers keep memory usage independent of meeting duration.
    static func export(directory: URL, root: URL) throws -> ExportResult {
        let manifest = try JSONDecoder().decode(SessionManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        let sources = [("system.caf", manifest.systemStart), ("microphone.caf", manifest.microphoneStart)]
        let tracks: [(file: AVAudioFile, start: Double)] = try sources.compactMap { name, start in
            guard let start else { return nil }
            let file = try AVAudioFile(forReading: directory.appendingPathComponent(name),
                commonFormat: .pcmFormatFloat32, interleaved: false)
            return file.length > 0 ? (file, start) : nil
        }
        guard let origin = tracks.map(\.start).min() else {
            throw RecorderError.message("No audio was received. Check microphone and system audio recording permissions.")
        }
        let offsets = tracks.map { Int64((($0.start - origin) * RecordingSession.sampleRate).rounded()) }
        let recordedLength = zip(tracks, offsets).map { $0.file.length + $1 }.max()!
        let requestedLength = manifest.duration.map { Int64(($0 * RecordingSession.sampleRate).rounded()) } ?? 0
        // A crashed or interrupted stream must not synthesize hours of missing sound.
        let length = max(recordedLength, min(requestedLength, recordedLength + 48_000))
        let destination = root.appendingPathComponent(manifest.name).appendingPathExtension("m4a")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RecorderError.message("The file already exists: \(destination.lastPathComponent)")
        }
        let staging = directory.appendingPathComponent("export.m4a")
        // Only this regenerable export is replaced; captured PCM is preserved.
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        var output: AVAudioFile? = try AVAudioFile(forWriting: staging, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: RecordingSession.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let mixed = AVAudioPCMBuffer(pcmFormat: RecordingSession.format, frameCapacity: 4096)!
        let inputs = tracks.map { _ in AVAudioPCMBuffer(pcmFormat: RecordingSession.format, frameCapacity: 4096)! }
        var cursor: Int64 = 0
        while cursor < length {
            let count = Int(min(4096, length - cursor))
            mixed.frameLength = AVAudioFrameCount(count)
            for channel in 0..<2 { memset(mixed.floatChannelData![channel], 0, count * MemoryLayout<Float>.size) }
            for index in tracks.indices {
                let position = cursor - offsets[index]
                let leading = Int(max(0, min(Int64(count), -position)))
                let available = min(Int64(count - leading), tracks[index].file.length - max(0, position))
                if available <= 0 { continue }
                try tracks[index].file.read(into: inputs[index], frameCount: AVAudioFrameCount(available))
                for channel in 0..<2 {
                    for frame in 0..<Int(inputs[index].frameLength) {
                        // Averaging prevents clipping when the two sources overlap.
                        mixed.floatChannelData![channel][frame + leading] +=
                            inputs[index].floatChannelData![channel][frame] / Float(tracks.count)
                    }
                }
            }
            try output!.write(from: mixed)
            cursor += Int64(count)
        }
        output = nil // Finalize AAC before verifying or moving it.
        let check = try AVAudioFile(forReading: staging)
        guard check.length > 0 else { throw RecorderError.message("Could not save the audio file.") }
        try FileManager.default.moveItem(at: staging, to: destination)
        // Cleanup happens only after the finished recording exists outside the session.
        try? FileManager.default.removeItem(at: directory)
        return ExportResult(url: destination,
            hasSystem: manifest.systemStart != nil, hasMicrophone: manifest.microphoneStart != nil)
    }
}

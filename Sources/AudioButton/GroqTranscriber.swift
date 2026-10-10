import AVFoundation
import Accelerate
import Foundation
import Darwin

enum GroqKeyStore {
    static var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.pasha.AudioButton", isDirectory: true)
            .appendingPathComponent("groq-key")
    }

    static func exists(at url: URL = storageURL) -> Bool {
        (try? read(at: url)) != nil
    }

    static func read(at url: URL = storageURL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let key = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
                throw RecorderError.message("The saved Groq key is invalid. Paste it again in Settings.")
            }
            return key
        } catch {
            throw RecorderError.message("Could not read the saved Groq key. Paste it again in Settings.")
        }
    }

    static func save(_ value: String, to url: URL = storageURL) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
            throw RecorderError.message("Paste your Groq API key without spaces.")
        }
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".groq-key-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            // Create with private permissions before writing any credential bytes.
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
            guard descriptor >= 0 else { throw RecorderError.message("Could not create the key file.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: Data(key.utf8))
                try handle.synchronize()
                try handle.close()
            } catch { try? handle.close(); throw error }
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw RecorderError.message("Could not replace the key file.")
            }
        } catch {
            throw RecorderError.message("Could not save the Groq key on this Mac. Please try again.")
        }
    }
}

struct TranscriptSegment: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
    var avg_logprob: Double? = nil
    var no_speech_prob: Double? = nil
    var compression_ratio: Double? = nil
}
struct TranscriptWord: Codable {
    var start: Double
    var end: Double
    var word: String
}
struct GroqResponse: Codable {
    var text: String
    var segments: [TranscriptSegment]?
    var words: [TranscriptWord]?
}
struct SavedTranscript: Codable {
    var model: String
    var audioFile: String
    var text: String
    var segments: [TranscriptSegment]
    var isPartial: Bool? = nil
}

struct TranscriptionWindow: Equatable {
    var start: Double
    var end: Double
    var coreStart: Double
    var coreEnd: Double
}

private struct AudioActivity {
    var start: Double
    var end: Double
    var seconds: Double
}

final class GroqTranscriber {
    static let model = "whisper-large-v3"
    private let network: URLSession
    init(network: URLSession = .shared) { self.network = network }

    func verifyKey(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
            throw RecorderError.message("Paste the full API key without spaces.")
        }
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        request.timeoutInterval = 20
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let response: URLResponse
        do { (_, response) = try await network.data(for: request) }
        catch { throw RecorderError.message("Couldn't connect to Groq. Check your connection and try again.") }
        guard let http = response as? HTTPURLResponse else {
            throw RecorderError.message("Couldn't connect to Groq. Try again.")
        }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw RecorderError.message("Groq didn't accept this key. Create a new key and paste it here.")
        case 429: throw RecorderError.message("Groq is busy. Please try again in a moment.")
        default: throw RecorderError.message("Groq is unavailable right now. Please try again later.")
        }
    }

    static func request(audio: Data, key: String, boundary: String) -> URLRequest {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in [("model", model), ("response_format", "verbose_json"),
                              ("timestamp_granularities[]", "segment"),
                              ("timestamp_granularities[]", "word")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    func upload(audio: Data, key: String) async throws -> GroqResponse {
        guard audio.count < 24_000_000 else { throw RecorderError.message("The audio chunk exceeds the Groq upload limit.") }
        let request = Self.request(audio: audio, key: key, boundary: UUID().uuidString)
        for attempt in 0..<3 {
            do {
                let (data, response) = try await network.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw RecorderError.message("Groq did not respond. Your audio is saved; you can retry transcription.")
                }
                if response.statusCode == 200 {
                    return try JSONDecoder().decode(GroqResponse.self, from: data)
                }
                if response.statusCode == 401 || response.statusCode == 403 {
                    throw RecorderError.message("Groq rejected the API key. Check it in the app settings.")
                }
                if response.statusCode == 429 || response.statusCode >= 500 {
                    let retry = Double(response.value(forHTTPHeaderField: "retry-after") ?? "") ?? Double(2 << attempt)
                    if attempt < 2, retry <= 30 {
                        try await Task.sleep(nanoseconds: UInt64(max(1, retry) * 1_000_000_000))
                        continue
                    }
                    throw RecorderError.message(response.statusCode == 429
                        ? "Groq rate limit reached. Audio and completed chunks are saved. Retry transcription later."
                        : "Groq is temporarily unavailable. Your audio is saved. Retry transcription later.")
                }
                // Do not print server bodies: a proxy or error can echo credentials.
                throw RecorderError.message("Groq error (HTTP \(response.statusCode)). Your audio is saved.")
            } catch let error as URLError where attempt < 2 &&
                [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                try await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000)
            }
        }
        throw RecorderError.message("Could not connect to Groq. Retry transcription later.")
    }

    func transcribe(file: URL, key: String,
                    progress: @escaping (Int, Int) -> Void) async throws -> URL {
        let work = file.deletingLastPathComponent().appendingPathComponent(
            "." + file.deletingPathExtension().lastPathComponent + ".transcription", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let input = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = input.processingFormat.sampleRate
        let duration = Double(input.length) / rate
        let total = max(1, Int(ceil(duration / 600)))
        var all: [TranscriptSegment] = []
        for index in 0..<total {
            progress(index + 1, total)
            let coreStart = Double(index) * 600
            let coreEnd = min(duration, Double(index + 1) * 600)
            let start = max(0, coreStart - 2)
            let end = min(duration, coreEnd + 2)
            let response = try await cachedResponse(file: file, key: key, start: start, end: end,
                work: work, name: "\(index)")
            all += Self.segments(response, offset: start, coreStart: coreStart, coreEnd: coreEnd)
        }
        // A multilingual model can omit a quieter language in a mixed recording.
        // Recheck audible gaps independently, without a fixed language or source split.
        let primary = all
        let recovery = try await Task.detached(priority: .utility) {
            try Self.recoveryWindows(file: file, segments: primary, duration: duration)
        }.value
        var result = try Self.save(all, for: file, partial: !recovery.isEmpty)
        for (index, window) in recovery.enumerated() {
            progress(total + index + 1, total + recovery.count)
            do {
                let name = "recovery-\(Int64((window.start * rate).rounded()))-\(Int64((window.end * rate).rounded()))"
                var response = try await cachedResponse(file: file, key: key, start: window.start,
                    end: window.end, work: work, name: name)
                // Extra passes over noise must not turn low-confidence guesses into text.
                response.segments = response.segments?.filter {
                    ($0.no_speech_prob ?? 0) < 0.6 && ($0.avg_logprob ?? 0) >= -1 &&
                        ($0.compression_ratio ?? 0) <= 2.4
                }
                let proposed = Self.segments(response, offset: window.start,
                    coreStart: window.coreStart, coreEnd: window.coreEnd)
                all += try await Task.detached(priority: .utility) {
                    try Self.audibleSegments(proposed, file: file)
                }.value
                result = try Self.save(all, for: file, partial: index + 1 < recovery.count)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw RecorderError.message("Audio and a partial transcript are saved. Retry transcription to finish checking missing speech.\n" + error.localizedDescription)
            }
        }
        try? FileManager.default.removeItem(at: work)
        return result
    }

    private func cachedResponse(file: URL, key: String, start: Double, end: Double,
                                work: URL, name: String) async throws -> GroqResponse {
        let responseFile = work.appendingPathComponent(name + ".json")
        if FileManager.default.fileExists(atPath: responseFile.path) {
            return try JSONDecoder().decode(GroqResponse.self, from: Data(contentsOf: responseFile))
        }
        let audio = try await Task.detached(priority: .utility) {
            try Self.chunk(file: file, start: start, end: end,
                destination: work.appendingPathComponent("chunk.m4a"))
        }.value
        let response = try await upload(audio: audio, key: key)
        try JSONEncoder().encode(response).write(to: responseFile, options: .atomic)
        return response
    }

    private static func save(_ segments: [TranscriptSegment], for file: URL, partial: Bool) throws -> URL {
        let all = segments.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        let text = all.map { "[\(Self.timestamp($0.start))] \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
        let result = file.deletingPathExtension().appendingPathExtension("txt")
        let final = SavedTranscript(model: Self.model, audioFile: file.lastPathComponent,
            text: text, segments: all, isPartial: partial ? true : nil)
        try JSONEncoder().encode(final).write(
            to: file.deletingPathExtension().appendingPathExtension("transcript.json"), options: .atomic)
        let notice = partial ? "[Transcription incomplete — retry in Audio Button.]\n\n" : ""
        try (notice + (text.isEmpty ? (partial ? "" : "No speech detected.\n") : text + "\n"))
            .write(to: result, atomically: true, encoding: .utf8)
        return result
    }

    static func recoveryWindows(file: URL, segments: [TranscriptSegment], duration: Double) throws -> [TranscriptionWindow] {
        let covered = segments.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start &&
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { $0.start < $1.start }
        var gaps: [(Double, Double)] = []
        var cursor = 0.0
        for segment in covered {
            let start = max(0, min(duration, segment.start))
            let end = max(0, min(duration, segment.end))
            if start - cursor >= 5 { gaps.append((cursor, start)) }
            cursor = max(cursor, end)
        }
        if duration - cursor >= 5 { gaps.append((cursor, duration)) }
        guard !gaps.isEmpty else { return [] }
        let input = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        var windows: [TranscriptionWindow] = []
        for (gapStart, gapEnd) in gaps {
            var coreStart = gapStart
            while coreStart < gapEnd {
                let coreEnd = min(coreStart + 30, gapEnd)
                if let activity = try audioActivity(input, start: coreStart, end: coreEnd),
                   activity.seconds >= min(1, (coreEnd - coreStart) / 2) {
                    // Keep context, but avoid uploading a long silent lead-in or tail.
                    windows.append(TranscriptionWindow(start: max(max(gapStart, coreStart - 1), activity.start - 1),
                        end: min(min(gapEnd, coreEnd + 1), activity.end + 1), coreStart: coreStart, coreEnd: coreEnd))
                }
                coreStart = coreEnd
            }
        }
        return windows
    }

    private static func audibleSegments(_ segments: [TranscriptSegment], file: URL) throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }
        let input = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        return try segments.filter { segment in
            guard let activity = try audioActivity(input, start: segment.start, end: segment.end) else { return false }
            return activity.seconds >= min(1, (segment.end - segment.start) / 2)
        }
    }

    private static func audioActivity(_ input: AVAudioFile, start: Double, end: Double) throws -> AudioActivity? {
        let rate = input.processingFormat.sampleRate
        input.framePosition = min(input.length, Int64((start * rate).rounded()))
        var remaining = min(input.length - input.framePosition, Int64(((end - start) * rate).rounded()))
        let capacity = AVAudioFrameCount((rate * 0.1).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity)!
        var audibleSeconds = 0.0
        var first: Double?
        var last = start
        while remaining > 0 {
            let position = Double(input.framePosition) / rate
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), remaining)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            var level: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                var rms: Float = 0
                vDSP_rmsqv(channels[channel], 1, &rms, vDSP_Length(buffer.frameLength))
                level = max(level, rms)
            }
            // -55 dBFS is an audio-presence gate, not a claim of voice detection.
            if level >= 0.00177828 {
                if first == nil { first = position }
                last = position + Double(buffer.frameLength) / rate
                audibleSeconds += Double(buffer.frameLength) / rate
            }
            remaining -= Int64(buffer.frameLength)
        }
        guard let first else { return nil }
        return AudioActivity(start: first, end: last, seconds: audibleSeconds)
    }

    static func chunk(file: URL, start: Double, end: Double, destination: URL) throws -> Data {
        let input = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = input.processingFormat.sampleRate
        input.framePosition = Int64((start * rate).rounded())
        var remaining = min(input.length - input.framePosition, Int64(((end - start) * rate).rounded()))
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        var output: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: input.processingFormat.channelCount, AVEncoderBitRateKey: 128_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
        while remaining > 0 {
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, remaining)))
            guard buffer.frameLength > 0 else { break }
            try output!.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
        output = nil
        return try Data(contentsOf: destination)
    }

    static func segments(_ response: GroqResponse, offset: Double,
                         coreStart: Double, coreEnd: Double) -> [TranscriptSegment] {
        let segments = response.segments ?? [TranscriptSegment(start: 0, end: coreEnd - offset, text: response.text)]
        return segments.compactMap { segment in
            guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let start = segment.start + offset
            let end = segment.end + offset
            if end <= coreStart || start >= coreEnd { return nil }
            if start >= coreStart && end <= coreEnd {
                var shifted = segment
                shifted.start = start
                shifted.end = end
                return shifted
            }
            if let words = response.words {
                let kept = words.filter { word in
                    let middle = (word.start + word.end) / 2
                    return middle >= segment.start && middle < segment.end &&
                        middle + offset >= coreStart && middle + offset < coreEnd
                }
                guard let first = kept.first, let last = kept.last else { return nil }
                return TranscriptSegment(start: max(coreStart, first.start + offset),
                    end: min(coreEnd, last.end + offset), text: kept.map(\.word).joined(separator: " "))
            }
            guard (start + end) / 2 >= coreStart && (start + end) / 2 < coreEnd else { return nil }
            return TranscriptSegment(start: max(coreStart, start), end: min(coreEnd, end), text: segment.text)
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

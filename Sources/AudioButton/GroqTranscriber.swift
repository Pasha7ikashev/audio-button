import AVFoundation
import Foundation
import Security
import LocalAuthentication

enum GroqKeyStore {
    private static let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "local.pasha.AudioButton") + ".Groq",
        kSecAttrAccount as String: "api-key"
    ]

    static func exists() -> Bool {
        var query = identity
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func read() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw RecorderError.message("Could not read the Groq API key from Keychain (\(status)).")
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
            throw RecorderError.message("Paste your Groq API key without spaces.")
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Audio Button — Groq API key"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw RecorderError.message("Could not save the API key in Keychain (\(status)).")
        }
    }
}

struct TranscriptSegment: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
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
            let responseFile = work.appendingPathComponent("\(index).json")
            let response: GroqResponse
            if FileManager.default.fileExists(atPath: responseFile.path) {
                response = try JSONDecoder().decode(GroqResponse.self, from: Data(contentsOf: responseFile))
            } else {
                let audio = try await Task.detached(priority: .utility) {
                    try Self.chunk(file: file, start: start, end: end,
                        destination: work.appendingPathComponent("chunk.m4a"))
                }.value
                response = try await upload(audio: audio, key: key)
                try JSONEncoder().encode(response).write(to: responseFile, options: .atomic)
            }
            all += Self.segments(response, offset: start, coreStart: coreStart, coreEnd: coreEnd)
        }
        let text = all.map { "[\(Self.timestamp($0.start))] \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
        let result = file.deletingPathExtension().appendingPathExtension("txt")
        let final = SavedTranscript(model: Self.model, audioFile: file.lastPathComponent, text: text, segments: all)
        try JSONEncoder().encode(final).write(
            to: file.deletingPathExtension().appendingPathExtension("transcript.json"), options: .atomic)
        try (text.isEmpty ? "No speech detected.\n" : text + "\n").write(to: result, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: work)
        return result
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
            let start = segment.start + offset
            let end = segment.end + offset
            if end <= coreStart || start >= coreEnd { return nil }
            if start >= coreStart && end <= coreEnd {
                return TranscriptSegment(start: start, end: end, text: segment.text)
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

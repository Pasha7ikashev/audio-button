import AVFoundation
// A standalone harness works with Command Line Tools; full Xcode is not required.
import Foundation

private var assertionFailures = 0
func XCTFail(_ message: String, file: StaticString = #file, line: UInt = #line) {
    assertionFailures += 1
    print("FAIL \(file):\(line) — \(message)")
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) rethrows {
    if try !value() { XCTFail("Expected true", file: file, line: line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) rethrows {
    if try value() { XCTFail("Expected false", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T,
                                 file: StaticString = #file, line: UInt = #line) rethrows {
    let value = try actual()
    if value != expected { XCTFail("\(value) != \(expected)", file: file, line: line) }
}
func XCTAssertEqual(_ actual: Double, _ expected: Double, accuracy: Double,
                    file: StaticString = #file, line: UInt = #line) {
    if abs(actual - expected) > accuracy { XCTFail("\(actual) != \(expected) ± \(accuracy)", file: file, line: line) }
}
func XCTAssertGreaterThan<T: Comparable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual <= expected { XCTFail("\(actual) is not greater than \(expected)", file: file, line: line) }
}
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual < expected { XCTFail("\(actual) is less than \(expected)", file: file, line: line) }
}
func XCTAssertLessThan<T: Comparable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual >= expected { XCTFail("\(actual) is not less than \(expected)", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression(); XCTFail("Expected an error", file: file, line: line) } catch {}
}
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}

final class AudioButtonTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AudioButtonTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func tone(_ frequency: Double, seconds: Double, rate: Double = 48_000,
                      channels: AVAudioChannelCount = 2) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let length = AVAudioFrameCount((rate * seconds).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length)!
        buffer.frameLength = length
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(length) {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * frequency / rate)) * 0.5
            }
        }
        return buffer
    }

    private func sampleFile(seconds: Double = 1) throws -> URL {
        let session = try RecordingSession(root: root)
        try session.append(tone(440, seconds: seconds), timestamp: 100, microphone: false)
        try session.append(tone(880, seconds: seconds), timestamp: 100, microphone: true)
        try session.finish(at: 100 + seconds)
        return try AudioExporter.export(directory: session.directory, root: root).url
    }

    func testMixPreservesDelayedMicrophoneAndSystem() throws {
        let session = try RecordingSession(root: root)
        try session.append(tone(440, seconds: 2), timestamp: 100, microphone: false)
        try session.append(tone(880, seconds: 1), timestamp: 101, microphone: true)
        try session.finish(at: 102)
        let result = try AudioExporter.export(directory: session.directory, root: root)
        XCTAssertTrue(result.hasSystem && result.hasMicrophone)
        let file = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 2, accuracy: 0.06)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        func amplitude(_ hz: Double, start: Int, count: Int) -> Double {
            var real = 0.0; var imaginary = 0.0
            for i in start..<(start + count) {
                let phase = Double(i) * 2 * .pi * hz / 48_000
                let value = Double(buffer.floatChannelData![0][i])
                real += value * cos(phase); imaginary += value * sin(phase)
            }
            return hypot(real, imaginary) * 2 / Double(count)
        }
        XCTAssertGreaterThan(amplitude(440, start: 12000, count: 12000), 0.20)
        XCTAssertLessThan(amplitude(880, start: 12000, count: 12000), 0.02)
        XCTAssertGreaterThan(amplitude(880, start: 60000, count: 12000), 0.20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.path))
    }

    func testGapsRemainSilentAndOverlapsDoNotDuplicateTime() throws {
        let track = try SourceTrack(url: root.appendingPathComponent("test.caf"))
        try track.append(tone(440, seconds: 0.1), timestamp: 10)
        try track.append(tone(440, seconds: 0.1), timestamp: 10.3)
        try track.append(tone(440, seconds: 0.1), timestamp: 10.35)
        XCTAssertEqual(track.frames, 21600)
        track.close()
        let file = try AVAudioFile(forReading: root.appendingPathComponent("test.caf"))
        file.framePosition = 6000
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 6000)!
        try file.read(into: buffer)
        for i in 0..<6000 { XCTAssertEqual(buffer.floatChannelData![0][i], 0) }
    }

    func testInputSampleRateAndChannelChange() throws {
        let track = try SourceTrack(url: root.appendingPathComponent("test.caf"))
        try track.append(tone(440, seconds: 0.5, rate: 44_100, channels: 1), timestamp: 1)
        try track.append(tone(440, seconds: 0.5, rate: 48_000, channels: 2), timestamp: 1.5)
        XCTAssertEqual(Double(track.frames) / 48_000, 1, accuracy: 0.003)
        track.close()
    }

    func testCrashRecoveryWithoutExplicitFinish() throws {
        var session: RecordingSession? = try RecordingSession(root: root)
        let directory = session!.directory
        try session!.append(tone(440, seconds: 0.5), timestamp: 100, microphone: true)
        session = nil
        XCTAssertEqual(AudioExporter.pending(in: root).map { $0.resolvingSymlinksInPath() },
                       [directory.resolvingSymlinksInPath()])
        let result = try AudioExporter.export(directory: directory, root: root)
        XCTAssertTrue(result.hasMicrophone)
        XCTAssertFalse(result.hasSystem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
    }

    func testExistingFileAndExportFailurePreserveRawAudio() throws {
        let session = try RecordingSession(root: root)
        try session.append(tone(440, seconds: 0.1), timestamp: 100, microphone: true)
        try session.finish(at: 100.1)
        let destination = root.appendingPathComponent(session.manifest.name + ".m4a")
        try Data("existing".utf8).write(to: destination)
        XCTAssertThrowsError(try AudioExporter.export(directory: session.directory, root: root))
        try XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("microphone.caf").path))
    }

    func testNoAudioFailsWithoutDeletingSession() throws {
        let session = try RecordingSession(root: root)
        try session.finish(at: 100)
        XCTAssertThrowsError(try AudioExporter.export(directory: session.directory, root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
    }

    func testMultipartContainsAudioAndAutomaticLanguageDetection() {
        let request = GroqTranscriber.request(audio: Data([0, 1, 2]), key: "fake-test-key", boundary: "test-boundary")
        XCTAssertEqual(request.url?.host, "api.groq.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-test-key")
        let text = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(text.contains("whisper-large-v3"))
        XCTAssertTrue(text.contains("verbose_json"))
        XCTAssertTrue(text.contains("name=\"file\""))
        XCTAssertFalse(text.contains("name=\"language\""))
        XCTAssertFalse(text.contains("fake-test-key"))
    }

    func testChunkIsAudioOnlyAndKeepsDuration() throws {
        let file = try sampleFile(seconds: 3)
        let destination = root.appendingPathComponent("chunk.m4a")
        let bytes = try GroqTranscriber.chunk(file: file, start: 1, end: 2.5, destination: destination)
        XCTAssertGreaterThan(bytes.count, 1000)
        let result = try AVAudioFile(forReading: destination)
        XCTAssertEqual(Double(result.length) / result.processingFormat.sampleRate, 1.5, accuracy: 0.06)
    }

    func testOverlappingChunksKeepEachBoundaryWordOnce() {
        let first = GroqResponse(text: "hello world", segments: [.init(start: 598, end: 602, text: "hello world")],
            words: [.init(start: 598, end: 599, word: "hello"), .init(start: 600.2, end: 601, word: "world")])
        let next = GroqResponse(text: "hello world", segments: [.init(start: 0, end: 4, text: "hello world")],
            words: [.init(start: 0, end: 1, word: "hello"), .init(start: 2.2, end: 3, word: "world")])
        let result = GroqTranscriber.segments(first, offset: 0, coreStart: 0, coreEnd: 600) +
            GroqTranscriber.segments(next, offset: 598, coreStart: 600, coreEnd: 1200)
        XCTAssertEqual(result.map(\.text), ["hello", "world"])
        XCTAssertGreaterThanOrEqual(result[1].start, 600)
    }

    func testGroqSuccessSavesTextAndResumeCache() async throws {
        let file = try sampleFile()
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [MockGroqProtocol.self]
        MockGroqProtocol.status = 200
        MockGroqProtocol.body = Data(#"{"text":"Проверка записи.","segments":[{"start":0,"end":0.9,"text":"Проверка записи."}]}"#.utf8)
        let transcriber = GroqTranscriber(network: URLSession(configuration: network))
        let result = try await transcriber.transcribe(file: file, key: "fake-test-key") { _, _ in }
        try XCTAssertTrue(try String(contentsOf: result, encoding: .utf8).contains("[00:00:00] Проверка записи."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("transcript.json").path))
    }

    func testInvalidKeyDoesNotLeakKeyAndPreservesAudio() async throws {
        let file = try sampleFile()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGroqProtocol.self]
        MockGroqProtocol.status = 401
        MockGroqProtocol.body = Data(#"{"error":{"message":"secret-test-key"}}"#.utf8)
        do {
            _ = try await GroqTranscriber(network: URLSession(configuration: configuration))
                .transcribe(file: file, key: "secret-test-key") { _, _ in }
            XCTFail("Expected invalid-key error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("secret-test-key"))
            XCTAssertTrue(error.localizedDescription.contains("API key"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testResumeUsesSavedResponseWithoutUploadingAgain() async throws {
        let file = try sampleFile()
        let work = file.deletingLastPathComponent().appendingPathComponent(
            "." + file.deletingPathExtension().lastPathComponent + ".transcription")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let cached = GroqResponse(text: "Уже готово.", segments: [.init(start: 0, end: 0.9, text: "Уже готово.")])
        try JSONEncoder().encode(cached).write(to: work.appendingPathComponent("0.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGroqProtocol.self]
        MockGroqProtocol.requests = 0
        MockGroqProtocol.status = 401
        let result = try await GroqTranscriber(network: URLSession(configuration: configuration))
            .transcribe(file: file, key: "fake-test-key") { _, _ in }
        XCTAssertEqual(MockGroqProtocol.requests, 0)
        try XCTAssertTrue(try String(contentsOf: result, encoding: .utf8).contains("Уже готово."))
    }

    func testRecentRecordingsAreLimitedAndPairedWithText() throws {
        for index in 0..<12 {
            let file = root.appendingPathComponent(String(format: "recording-%02d.m4a", index))
            try Data([0]).write(to: file)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))],
                ofItemAtPath: file.path)
        }
        try Data("text".utf8).write(to: root.appendingPathComponent("recording-11.txt"))
        try Data([0]).write(to: root.appendingPathComponent(".hidden.m4a"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory.m4a"), withIntermediateDirectories: true)
        let recordings = RecordingLibrary.recent(in: root)
        XCTAssertEqual(recordings.count, 10)
        XCTAssertEqual(recordings.first?.audio.lastPathComponent, "recording-11.m4a")
        XCTAssertEqual(recordings.first?.transcript?.lastPathComponent, "recording-11.txt")
        XCTAssertEqual(recordings.last?.audio.lastPathComponent, "recording-02.m4a")
        XCTAssertTrue(recordings.dropFirst().allSatisfy { $0.transcript == nil })
        try FileManager.default.removeItem(at: root.appendingPathComponent("recording-11.txt"))
        XCTAssertTrue(RecordingLibrary.recent(in: root).first?.transcript == nil)
        XCTAssertTrue(RecordingLibrary.recent(in: root.appendingPathComponent("missing")).isEmpty)
    }

    func testKeyVerificationUsesAuthenticationAndFriendlyErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGroqProtocol.self]
        let transcriber = GroqTranscriber(network: URLSession(configuration: configuration))
        MockGroqProtocol.status = 200
        MockGroqProtocol.body = Data("{}".utf8)
        try await transcriber.verifyKey(" fake-verification-key ")
        XCTAssertEqual(MockGroqProtocol.lastRequest?.url?.path, "/openai/v1/models")
        XCTAssertEqual(MockGroqProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(MockGroqProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer fake-verification-key")
        XCTAssertTrue(MockGroqProtocol.lastRequest?.httpBody == nil)
        for status in [401, 429, 503] {
            MockGroqProtocol.status = status
            MockGroqProtocol.body = Data("fake-verification-key".utf8)
            do { try await transcriber.verifyKey("fake-verification-key"); XCTFail("Expected verification error") }
            catch {
                XCTAssertFalse(error.localizedDescription.contains("fake-verification-key"))
                XCTAssertFalse(error.localizedDescription.contains(String(status)))
            }
        }
        MockGroqProtocol.requests = 0
        do { try await transcriber.verifyKey("key with spaces"); XCTFail("Expected invalid key error") }
        catch { XCTAssertEqual(MockGroqProtocol.requests, 0) }
    }

    func testMetersUseSeparateRealSourceLevels() throws {
        let session = try RecordingSession(root: root)
        try session.append(tone(440, seconds: 0.1), timestamp: 1, microphone: true)
        try session.append(tone(0, seconds: 0.1), timestamp: 1, microphone: false)
        XCTAssertGreaterThan(RecordingLibrary.meterLevel(session.microphone.level), 0.85)
        XCTAssertEqual(RecordingLibrary.meterLevel(session.system.level), 0)
        XCTAssertEqual(RecordingLibrary.meterLevel(0), 0)
        XCTAssertEqual(RecordingLibrary.meterLevel(.nan), 0)
        XCTAssertEqual(RecordingLibrary.meterLevel(2), 1)
        XCTAssertGreaterThan(RecordingLibrary.meterLevel(0.2), RecordingLibrary.meterLevel(0.02))
        try session.finish(at: 1.1)
    }
}

final class MockGroqProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var body = Data()
    static var requests = 0
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct TestRunner {
    static func main() async {
        let tests = AudioButtonTests()
        let cases: [(String, () async throws -> Void)] = [
            ("delayed microphone mix", { try tests.testMixPreservesDelayedMicrophoneAndSystem() }),
            ("gaps and overlaps", { try tests.testGapsRemainSilentAndOverlapsDoNotDuplicateTime() }),
            ("input format change", { try tests.testInputSampleRateAndChannelChange() }),
            ("crash recovery", { try tests.testCrashRecoveryWithoutExplicitFinish() }),
            ("safe export failure", { try tests.testExistingFileAndExportFailurePreserveRawAudio() }),
            ("empty capture", { try tests.testNoAudioFailsWithoutDeletingSession() }),
            ("API request", { tests.testMultipartContainsAudioAndAutomaticLanguageDetection() }),
            ("audio chunks", { try tests.testChunkIsAudioOnlyAndKeepsDuration() }),
            ("chunk overlap", { tests.testOverlappingChunksKeepEachBoundaryWordOnce() }),
            ("Groq success", { try await tests.testGroqSuccessSavesTextAndResumeCache() }),
            ("invalid API key", { try await tests.testInvalidKeyDoesNotLeakKeyAndPreservesAudio() }),
            ("resume without duplicate upload", { try await tests.testResumeUsesSavedResponseWithoutUploadingAgain() }),
            ("latest ten recordings and transcripts", { try tests.testRecentRecordingsAreLimitedAndPairedWithText() }),
            ("key verification and errors", { try await tests.testKeyVerificationUsesAuthenticationAndFriendlyErrors() }),
            ("independent microphone and Mac audio meters", { try tests.testMetersUseSeparateRealSourceLevels() })
        ]
        for (name, run) in cases {
            let before = assertionFailures
            do { try tests.setUpWithError(); try await run() }
            catch { XCTFail(name + ": " + error.localizedDescription) }
            do { try tests.tearDownWithError() } catch { XCTFail(error.localizedDescription) }
            print("\(assertionFailures == before ? "PASS" : "FAIL") \(name)")
        }
        print("\(cases.count) checks; \(assertionFailures) failures")
        exit(assertionFailures == 0 ? 0 : 1)
    }
}

import AVFoundation
// A standalone harness works with Command Line Tools; full Xcode is not required.
import Foundation
import ScreenCaptureKit

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
        MockGroqProtocol.responses = []
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

    private let mixedBaseline = Data(#"{"text":"Так, проверка. Мне выключить.","segments":[{"start":0,"end":4.38,"text":"Так, проверка."},{"start":30,"end":32.02,"text":"Мне выключить."}]}"#.utf8)
    private let mixedRecovery = Data(#"{"text":"A year ago. Це теж важливо.","segments":[{"start":1,"end":10,"text":"A year ago.","avg_logprob":-0.28,"no_speech_prob":0.09},{"start":11,"end":20,"text":"Це теж важливо.","avg_logprob":-0.3,"no_speech_prob":0.1}]}"#.utf8)

    private func mixedFixture(silentGap: Bool = false, silentTail: Bool = false) throws -> URL {
        let buffer = tone(440, seconds: 34.5)
        if silentGap {
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in Int(4.38 * 48_000)..<Int(30 * 48_000) {
                    buffer.floatChannelData![channel][frame] = 0
                }
            }
        }
        if silentTail {
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in Int(26 * 48_000)..<Int(30 * 48_000) {
                    buffer.floatChannelData![channel][frame] = 0
                }
            }
        }
        let file = root.appendingPathComponent("mixed.m4a")
        var output: AVAudioFile? = try AVAudioFile(forWriting: file, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
        ])
        try output!.write(from: buffer)
        output = nil
        return file
    }

    private func mockedTranscriber() -> GroqTranscriber {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGroqProtocol.self]
        MockGroqProtocol.requests = 0
        return GroqTranscriber(network: URLSession(configuration: configuration))
    }

    func testAudibleGapRecoversOtherLanguagesWithoutSplittingRecording() async throws {
        let file = try mixedFixture()
        let original = try Data(contentsOf: file)
        let transcriber = mockedTranscriber()
        MockGroqProtocol.responses = [(200, mixedBaseline), (200, mixedRecovery)]
        let result = try await transcriber.transcribe(file: file, key: "fake-test-key") { _, _ in }
        XCTAssertEqual(MockGroqProtocol.requests, 2)
        let saved = try JSONDecoder().decode(SavedTranscript.self,
            from: Data(contentsOf: file.deletingPathExtension().appendingPathExtension("transcript.json")))
        XCTAssertEqual(saved.segments.map(\.text), ["Так, проверка.", "A year ago.", "Це теж важливо.", "Мне выключить."])
        XCTAssertEqual(saved.segments[1].start, 5.38, accuracy: 0.01)
        XCTAssertEqual(saved.segments[2].start, 15.38, accuracy: 0.01)
        XCTAssertTrue(saved.isPartial != true)
        try XCTAssertTrue(try String(contentsOf: result, encoding: .utf8).contains("[00:00:15] Це теж важливо."))
        try XCTAssertEqual(try Data(contentsOf: file), original)
        try XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            ["mixed.m4a", "mixed.transcript.json", "mixed.txt"])
    }

    func testSilentGapDoesNotTriggerAnotherUpload() async throws {
        let file = try mixedFixture(silentGap: true)
        let transcriber = mockedTranscriber()
        MockGroqProtocol.responses = [(200, mixedBaseline)]
        _ = try await transcriber.transcribe(file: file, key: "fake-test-key") { _, _ in }
        XCTAssertEqual(MockGroqProtocol.requests, 1)
    }

    func testRecoveryFailureKeepsPartialTextAndResumesCachedPrimary() async throws {
        let file = try mixedFixture()
        let transcriber = mockedTranscriber()
        MockGroqProtocol.responses = [(200, mixedBaseline), (401, Data("private-error-body".utf8))]
        do {
            _ = try await transcriber.transcribe(file: file, key: "fake-test-key") { _, _ in }
            XCTFail("Expected recovery failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("partial transcript"))
            XCTAssertFalse(error.localizedDescription.contains("private-error-body"))
        }
        let text = file.deletingPathExtension().appendingPathExtension("txt")
        let partial = try String(contentsOf: text, encoding: .utf8)
        XCTAssertTrue(partial.contains("Transcription incomplete"))
        XCTAssertTrue(partial.contains("Так, проверка."))
        XCTAssertTrue(partial.contains("Мне выключить."))
        XCTAssertEqual(MockGroqProtocol.requests, 2)
        MockGroqProtocol.responses = [(200, mixedRecovery)]
        _ = try await transcriber.transcribe(file: file, key: "fake-test-key") { _, _ in }
        XCTAssertEqual(MockGroqProtocol.requests, 3)
        let complete = try String(contentsOf: text, encoding: .utf8)
        XCTAssertFalse(complete.contains("Transcription incomplete"))
        XCTAssertTrue(complete.contains("A year ago."))
    }

    func testNoiseRecoveryRejectsLowConfidenceGuesses() async throws {
        let file = try mixedFixture()
        let transcriber = mockedTranscriber()
        let guesses = Data(#"{"text":"Invented speech.","segments":[{"start":0,"end":4,"text":"Noise guess","no_speech_prob":0.95},{"start":5,"end":9,"text":"Low confidence guess","avg_logprob":-1.5},{"start":10,"end":15,"text":"Repetitive guess","compression_ratio":3.1}]}"#.utf8)
        MockGroqProtocol.responses = [(200, mixedBaseline), (200, guesses)]
        let result = try await transcriber.transcribe(file: file, key: "fake-test-key") { _, _ in }
        let text = try String(contentsOf: result, encoding: .utf8)
        XCTAssertFalse(text.contains("guess"))
        XCTAssertTrue(text.contains("Так, проверка."))
    }

    func testRecoveryDropsWordsInSilentTailEvenWithHighConfidence() async throws {
        let file = try mixedFixture(silentTail: true)
        let transcriber = mockedTranscriber()
        let recovery = Data(#"{"text":"English. Okay.","segments":[{"start":1,"end":10,"text":"English."},{"start":21.62,"end":25.62,"text":"Okay.","avg_logprob":-0.2,"no_speech_prob":0.01}]}"#.utf8)
        MockGroqProtocol.responses = [(200, mixedBaseline), (200, recovery)]
        let result = try await transcriber.transcribe(file: file, key: "fake-test-key") { _, _ in }
        let text = try String(contentsOf: result, encoding: .utf8)
        XCTAssertTrue(text.contains("English."))
        XCTAssertFalse(text.contains("Okay."))
        let windows = try GroqTranscriber.recoveryWindows(file: file,
            segments: [.init(start: 0, end: 4.38, text: "RU"), .init(start: 30, end: 32.02, text: "RU")], duration: 34.5)
        XCTAssertEqual(windows.count, 1)
        XCTAssertLessThan(windows[0].end, 27.3)
    }

    func testLongGapUsesShortOverlappingWindowsAndCachesRecovery() async throws {
        let file = try sampleFile(seconds: 70)
        let windows = try GroqTranscriber.recoveryWindows(file: file,
            segments: [.init(start: 0, end: 5, text: "Beginning"), .init(start: 65, end: 70, text: "End")], duration: 70)
        XCTAssertEqual(windows, [TranscriptionWindow(start: 5, end: 36, coreStart: 5, coreEnd: 35),
            TranscriptionWindow(start: 34, end: 65, coreStart: 35, coreEnd: 65)])
        let transcriber = mockedTranscriber()
        let baseline = Data(#"{"text":"Beginning End","segments":[{"start":0,"end":5,"text":"Beginning"},{"start":65,"end":70,"text":"End"}]}"#.utf8)
        MockGroqProtocol.responses = [(200, baseline), (200, mixedRecovery), (401, Data())]
        do { _ = try await transcriber.transcribe(file: file, key: "fake-test-key") { _, _ in }; XCTFail("Expected recovery failure") }
        catch {}
        XCTAssertEqual(MockGroqProtocol.requests, 3)
        MockGroqProtocol.responses = [(200, Data(#"{"text":"Later","segments":[{"start":2,"end":10,"text":"Later"}]}"#.utf8))]
        let result = try await transcriber.transcribe(file: file, key: "fake-test-key") { _, _ in }
        XCTAssertEqual(MockGroqProtocol.requests, 4)
        let text = try String(contentsOf: result, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "A year ago.").count, 2)
        XCTAssertTrue(text.contains("[00:00:36] Later"))
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

    func testLocalKeyPersistsWithPrivatePermissions() throws {
        let url = root.appendingPathComponent("app-data/groq-key")
        XCTAssertFalse(GroqKeyStore.exists(at: url))
        try XCTAssertTrue(try GroqKeyStore.read(at: url) == nil)
        try GroqKeyStore.save(" fake-local-key-one \n", to: url)
        XCTAssertTrue(GroqKeyStore.exists(at: url))
        try XCTAssertEqual(try GroqKeyStore.read(at: url), "fake-local-key-one")
        let manager = FileManager.default
        let fileAttributes = try manager.attributesOfItem(atPath: url.path)
        let folderAttributes = try manager.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try GroqKeyStore.save("fake-local-key-two", to: url)
        try XCTAssertEqual(try GroqKeyStore.read(at: url), "fake-local-key-two")
        XCTAssertThrowsError(try GroqKeyStore.save("invalid key", to: url))
        try XCTAssertEqual(try GroqKeyStore.read(at: url), "fake-local-key-two")
        try XCTAssertEqual(try manager.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["groq-key"])
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

    func testOnlyScreenCaptureDenialRequestsPermissions() {
        let denial = SCStreamError.Code.userDeclined.rawValue
        XCTAssertTrue(CapturePermission.isSystemAudioDenial(NSError(domain: SCStreamErrorDomain, code: denial)))
        XCTAssertFalse(CapturePermission.isSystemAudioDenial(NSError(domain: SCStreamErrorDomain, code: -3802)))
        XCTAssertFalse(CapturePermission.isSystemAudioDenial(NSError(domain: NSOSStatusErrorDomain, code: denial)))
    }
}

final class MockGroqProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var body = Data()
    static var requests = 0
    static var lastRequest: URLRequest?
    static var responses: [(Int, Data)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.lastRequest = request
        let (status, body) = Self.responses.isEmpty ? (Self.status, Self.body) : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
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
            ("recover omitted languages in one recording", { try await tests.testAudibleGapRecoversOtherLanguagesWithoutSplittingRecording() }),
            ("silent gaps do not use extra API requests", { try await tests.testSilentGapDoesNotTriggerAnotherUpload() }),
            ("recovery failure preserves partial transcript and resumes", { try await tests.testRecoveryFailureKeepsPartialTextAndResumesCachedPrimary() }),
            ("noise recovery rejects low-confidence text", { try await tests.testNoiseRecoveryRejectsLowConfidenceGuesses() }),
            ("recovery rejects invented words in a silent tail", { try await tests.testRecoveryDropsWordsInSilentTailEvenWithHighConfidence() }),
            ("long gaps use short windows and reuse completed recovery", { try await tests.testLongGapUsesShortOverlappingWindowsAndCachesRecovery() }),
            ("latest ten recordings and transcripts", { try tests.testRecentRecordingsAreLimitedAndPairedWithText() }),
            ("key verification and errors", { try await tests.testKeyVerificationUsesAuthenticationAndFriendlyErrors() }),
            ("independent microphone and Mac audio meters", { try tests.testMetersUseSeparateRealSourceLevels() }),
            ("persistent private key file without system prompts", { try tests.testLocalKeyPersistsWithPrivatePermissions() }),
            ("capture failures distinguish denied access from other errors", { tests.testOnlyScreenCaptureDenialRequestsPermissions() })
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

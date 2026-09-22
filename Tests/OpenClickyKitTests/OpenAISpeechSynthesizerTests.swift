import Testing
import Foundation
@testable import OpenClickyKit

/// The wire and the queue, which is the half of this class no state-machine test can
/// reach — `VoiceSession` never sees a network or a speaker, by design.
///
/// Playback itself is left alone: asserting that real audio came out of a real device is
/// not a claim a unit test can make honestly, and this project's own tests already draw
/// that line — `SystemSpeechSynthesizer` has none either. What is tested here is
/// everything *around* the sound: the request that would produce it, and that a sentence
/// this class cannot turn into audio is dropped rather than left stuck in front of every
/// sentence said after it — see `JevClient`'s own "every failure lands in the same place"
/// rule, applied to output instead of input.
@Suite("OpenAI speech synthesizer", .serialized)
struct OpenAISpeechSynthesizerTests {

    /// Answers whatever it is told to, and keeps the request it was given. The same
    /// shape `JevClientTests.Stub` uses, for the same reason: `URLProtocol` is
    /// instantiated by the loading system itself, so there is no per-session handle to
    /// hang state off.
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var seen: Data?
        nonisolated(unsafe) static var seenAuthorization: String?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    data.append(contentsOf: buffer[0..<read])
                }
                stream.close()
                Stub.seen = data
            } else {
                Stub.seen = request.httpBody
            }
            Stub.seenAuthorization = request.value(forHTTPHeaderField: "Authorization")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: Stub.status,
                httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// Waits for `onFinished` to fire, or fails after a short timeout rather than
    /// hanging the suite. Every path through `advance()` reaches it eventually — a
    /// successful play, a failed decode, or a failed request all drain the queue the
    /// same way — so this is the one thing every test here can wait on.
    private final class FinishedSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var onFinished: @Sendable () -> Void {
            { [self] in lock.lock(); count += 1; lock.unlock() }
        }
        var currentCount: Int { lock.lock(); defer { lock.unlock() }; return count }
        func waitForFinish(timeout: TimeInterval = 2) async -> Bool {
            await waitForCount(atLeast: 1, timeout: timeout)
        }
        /// Waits for at least `target` calls, rather than merely "one so far" — needed
        /// wherever a test cares about a *specific* call finishing rather than any call
        /// having finished, since a racing earlier sentence could satisfy "any" without
        /// the one the test is actually about ever having run.
        func waitForCount(atLeast target: Int, timeout: TimeInterval = 2) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if currentCount >= target { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
    }

    private func synthesizer(
        status: Int = 200, body: Data = Data("not valid audio".utf8),
        onFinished: @escaping @Sendable () -> Void = {}
    ) -> OpenAISpeechSynthesizer {
        Stub.status = status
        Stub.body = body
        Stub.seen = nil
        Stub.seenAuthorization = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return OpenAISpeechSynthesizer(
            apiKey: "sk-test-tts-123456789",
            session: URLSession(configuration: configuration),
            onFinished: onFinished
        )
    }

    // MARK: - The request

    @Test("A spoken sentence reaches the service with the model, voice and text")
    func theRequestCarriesTheSentence() async throws {
        let spy = FinishedSpy()
        let voice = synthesizer(onFinished: spy.onFinished)
        voice.speak("Bringing that to the front.")
        _ = await spy.waitForFinish()

        let body = try #require(Stub.seen)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["model"] as? String == OpenAISpeechSynthesizer.defaultModel)
        #expect(json["input"] as? String == "Bringing that to the front.")
        #expect(json["voice"] as? String == OpenAISpeechSynthesizer.defaultVoice)
        #expect(json["response_format"] as? String == "wav")
        #expect(Stub.seenAuthorization == "Bearer sk-test-tts-123456789")
    }

    @Test("An empty sentence is never sent")
    func emptySentencesAreDropped() async {
        let voice = synthesizer()
        voice.speak("   ")
        // Nothing to wait on — no request should have been made at all.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(Stub.seen == nil)
        #expect(!voice.isSpeaking)
    }

    @Test("The style instruction travels with every sentence by default")
    func instructionsTravelByDefault() async throws {
        let spy = FinishedSpy()
        let voice = synthesizer(onFinished: spy.onFinished)
        voice.speak("Done.")
        _ = await spy.waitForFinish()

        let body = try #require(Stub.seen)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["instructions"] as? String == OpenAISpeechSynthesizer.defaultInstructions)
    }

    // MARK: - What a sentence that cannot become audio does to the ones after it

    /// The whole reason `advance()` treats a failed decode as a dropped sentence rather
    /// than a stuck queue: a network TTS voice missing one line is recoverable, and
    /// stalling everything said after it on one bad response is a worse failure than
    /// losing that line.
    @Test("A response that is not audio still drains the queue and reports finished")
    func unplayableAudioStillFinishes() async {
        let spy = FinishedSpy()
        let voice = synthesizer(body: Data("<html>not audio</html>".utf8), onFinished: spy.onFinished)
        voice.speak("This cannot be played.")
        let finished = await spy.waitForFinish()
        #expect(finished, "a sentence that could not become audio left the queue stuck")
        #expect(!voice.isSpeaking)
    }

    @Test("A rejected request still drains the queue and reports finished")
    func aRejectedRequestStillFinishes() async {
        let spy = FinishedSpy()
        let voice = synthesizer(status: 401, onFinished: spy.onFinished)
        voice.speak("This will be refused.")
        let finished = await spy.waitForFinish()
        #expect(finished, "a rejected request left the queue stuck ahead of every sentence after it")
    }

    // MARK: - Stopping

    @Test("Stopping empties the queue and reports not speaking")
    func stopEmptiesTheQueue() {
        let voice = synthesizer(status: 500)
        voice.speak("First.")
        voice.speak("Second.")
        voice.speak("Third.")
        voice.stop()
        #expect(!voice.isSpeaking)
    }

    @Test("The same session accepts new speech after being stopped")
    func stoppingDoesNotWedgeTheQueue() async {
        let spy = FinishedSpy()
        let voice = synthesizer(status: 500, onFinished: spy.onFinished)
        voice.speak("Interrupted mid-sentence.")
        voice.stop()
        #expect(!voice.isSpeaking)
        // Not asserted either way: `stop()` cancelling before the first request lands
        // is the ordinary case, but a stray completion racing ahead of it is the exact,
        // documented imperfection `TTSProvider.openai.detail` already tells the user
        // about — "a beat slower to cut off". Either outcome is fine; what matters is
        // what happens next.
        let before = spy.currentCount

        // A fresh sentence on the same instance, now answered normally rather than
        // refused — `isProcessing` must not still read true from the turn `stop()`
        // just cut off, or this would sit in the queue forever behind a flag `stop()`
        // failed to clear.
        Stub.status = 200
        Stub.body = Data("not valid audio".utf8)
        voice.speak("A fresh turn.")
        let finished = await spy.waitForCount(atLeast: before + 1)
        #expect(finished, "a session that had been stopped once could not speak again")
    }
}

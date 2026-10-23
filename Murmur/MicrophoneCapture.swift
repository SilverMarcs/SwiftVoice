import AVFoundation
import DictationCore

@MainActor
final class MicrophoneCapture {
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    private var configurationObserver: NSObjectProtocol?

    func start() throws -> AsyncThrowingStream<[Float], Error> {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw RecognitionError.message("No usable microphone is available.")
        }
        // Bound queued audio. If inference falls behind, report the error instead of silently losing words.
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        self.engine = engine
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / inputFormat.sampleRate + 1024)
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                continuation.finish(throwing: RecognitionError.message("Couldn't allocate microphone audio."))
                return
            }
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if let error { continuation.finish(throwing: error); return }
            guard converted.frameLength > 0, let channel = converted.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            if case .dropped = continuation.yield(samples) {
                continuation.finish(throwing: RecognitionError.message("Transcription couldn't keep up. Please start a new recording."))
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { @Sendable _ in
            continuation.finish(throwing: RecognitionError.message("The microphone changed. Please start a new recording."))
        }
        do {
            engine.prepare()
            try engine.start()
            return stream
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        continuation?.finish()
        continuation = nil
    }
}

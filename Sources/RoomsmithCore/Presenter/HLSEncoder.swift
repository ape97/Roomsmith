import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import UniformTypeIdentifiers

/// Encodes a steady stream of pixel buffers to fragmented MP4 segments (HLS profile) and feeds an `HLSSegmentStore`.
///
/// Frames are submitted whenever the picture changes; a fixed-rate clock re-appends the newest frame so the stream
/// keeps flowing for a static plan. When the writer cannot keep up, frames are dropped, never queued.
public final class HLSEncoder: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    // Safe: writer, input, adaptor, timer and `latest` are only touched on `queue`; counters sit behind `Locked`.

    public struct Configuration: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var frameRate: Int
        /// Segment length = key frame interval, seconds.
        public var segmentInterval: Double
        public var bitRate: Int

        public init(width: Int, height: Int, frameRate: Int = 30, segmentInterval: Double = 0.5, bitRate: Int? = nil) {
            self.width = width
            self.height = height
            self.frameRate = max(1, frameRate)
            self.segmentInterval = max(0.1, segmentInterval)
            self.bitRate = bitRate ?? Self.defaultBitRate(width: width, height: height)
        }

        /// About 8 Mbit/s at 1920x1080, scaled by pixel count, never below 2 Mbit/s.
        public static func defaultBitRate(width: Int, height: Int) -> Int {
            max(2_000_000, Int(8_000_000 * Double(width * height) / (1920 * 1080)))
        }
    }

    public struct Statistics: Sendable, Equatable {
        public var framesAppended = 0
        public var framesDropped = 0
        public var segments = 0
    }

    public enum EncoderError: Error, LocalizedError {
        case cannotStart(String)
        public var errorDescription: String? {
            switch self { case .cannotStart(let d): d }
        }
    }

    public let configuration: Configuration
    public let store: HLSSegmentStore
    private let queue = DispatchQueue(label: "roomsmith.presenter.encoder")
    private let stats = Locked(Statistics())
    private let errorBox = Locked<String?>(nil)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: DispatchSourceTimer?
    private var latest: CVPixelBuffer?
    private var startTime: UInt64 = 0
    private var lastPTS = CMTime.invalid
    private var onFailure: (@Sendable (String) -> Void)?

    public init(configuration: Configuration, store: HLSSegmentStore) {
        self.configuration = configuration
        self.store = store
    }

    public var statistics: Statistics { stats.withLock { $0 } }
    /// Set when the writer failed.
    public var failureMessage: String? { errorBox.withLock { $0 } }

    /// Starts the writer and the frame clock. `onFailure` is called once if the writer fails later.
    public func start(onFailure: (@Sendable (String) -> Void)? = nil) throws {
        let c = configuration
        let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: c.segmentInterval, preferredTimescale: 1000)
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: c.bitRate,
            AVVideoMaxKeyFrameIntervalDurationKey: c.segmentInterval,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoExpectedSourceFrameRateKey: c.frameRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: c.width,
            AVVideoHeightKey: c.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: c.width,
            kCVPixelBufferHeightKey as String: c.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(input) else { throw EncoderError.cannotStart("The video settings were rejected") }
        writer.add(input)
        guard writer.startWriting() else {
            throw EncoderError.cannotStart(writer.error?.localizedDescription ?? "The writer did not start")
        }
        writer.startSession(atSourceTime: .zero)

        store.reset()
        errorBox.withLock { $0 = nil }
        stats.withLock { $0 = Statistics() }
        queue.sync {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.onFailure = onFailure
            self.latest = nil
            self.lastPTS = .invalid
            self.startTime = DispatchTime.now().uptimeNanoseconds
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / c.frameRate), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    /// Replaces the picture the clock keeps sending. Any thread.
    public func submit(_ frame: PresenterFrame) {
        queue.async { self.latest = frame.pixelBuffer }
    }

    /// Stops the clock, finishes the last segment and marks the playlist as ended.
    public func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.timer?.cancel()
                self.timer = nil
                self.latest = nil
                let w = self.writer, i = self.input
                self.writer = nil; self.input = nil; self.adaptor = nil
                guard let w, let i, w.status == .writing else { cont.resume(); return }
                i.markAsFinished()
                w.finishWriting { cont.resume() }
            }
        }
        store.markEnded()
    }

    // MARK: Frame clock (on `queue`)

    private func tick() {
        guard let writer, let input, let adaptor, let frame = latest else { return }
        guard writer.status == .writing else {
            fail(writer.error?.localizedDescription ?? "The writer stopped (status \(writer.status.rawValue))")
            return
        }
        guard input.isReadyForMoreMediaData else {
            stats.withLock { $0.framesDropped += 1 }
            return
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime
        var pts = CMTime(value: CMTimeValue(elapsed / 1_000_000), timescale: 1000)
        let tick = CMTime(value: max(1, 1000 / CMTimeValue(max(1, configuration.frameRate)) / 2), timescale: 1000)
        // Strictly increasing timestamps even when the timer fires early.
        if lastPTS.isValid, pts <= lastPTS { pts = lastPTS + tick }
        if adaptor.append(frame, withPresentationTime: pts) {
            lastPTS = pts
            stats.withLock { $0.framesAppended += 1 }
        } else {
            fail(writer.error?.localizedDescription ?? "Appending a frame failed")
        }
    }

    private func fail(_ message: String) {
        guard errorBox.withLock({ e in if e == nil { e = message; return true } else { return false } }) else { return }
        timer?.cancel()
        timer = nil
        let callback = onFailure
        onFailure = nil
        callback?(message)
    }

    // MARK: AVAssetWriterDelegate (any queue)

    public func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                            segmentReport: AVAssetSegmentReport?) {
        switch segmentType {
        case .initialization:
            store.setInit(segmentData)
        case .separable:
            let reported = segmentReport?.trackReports.first?.duration.seconds
            let duration = (reported?.isFinite == true && reported! > 0) ? reported! : configuration.segmentInterval
            store.append(duration: duration, data: segmentData)
            stats.withLock { $0.segments += 1 }
        @unknown default:
            break
        }
    }
}

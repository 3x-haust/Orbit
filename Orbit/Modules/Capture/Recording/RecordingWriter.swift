import AVFoundation
import ScreenCaptureKit

/// Writes a recording from ScreenCaptureKit's samples: HEVC video plus an AAC track for app sound
/// and one for the microphone. Writing it ourselves (instead of SCRecordingOutput) is what lets the
/// sound be switched off and on mid-recording without the file losing its tracks, and keeps a busy
/// moment (a window zooming across a Retina screen) from stalling the whole pipeline: a frame the
/// encoder can't take yet is dropped, never queued up behind.
///
/// Everything here runs on `queue`, which is also the streams' sample handler queue.
final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.lyu.orbit.recording.writer", qos: .userInteractive)

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput
    private let mic: AVAssetWriterInput?
    private var started = false
    private var startTime = CMTime.zero
    private let frameDuration: CMTime
    private var lastVideoTime = CMTime.invalid
    private(set) var droppedFrames = 0
    private(set) var writtenFrames = 0

    /// Window recordings: click rings painted into the frames, written through `adaptor`.
    private let painter: ClickPainter?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    /// The newest frame and where the window sat in it, to repaint while a ring plays over a still window
    /// (ScreenCaptureKit sends no frame while nothing changes).
    private var lastPixels: CVPixelBuffer?
    private var lastContent = CGRect.zero
    private var lastScale: CGFloat = 1
    private var ticker: DispatchSourceTimer?

    /// App sound is captured all along and written as silence while it's switched off, so the
    /// track is there to switch back on to.
    private var _systemAudioOn: Bool
    var systemAudioOn: Bool {
        get { queue.sync { _systemAudioOn } }
        set { queue.async { self._systemAudioOn = newValue } }
    }

    var failure: Error? { writer.status == .failed ? writer.error : nil }

    init(url: URL, size: CGSize, fps: Int, systemAudioOn: Bool, mic: Bool, paintsClicks: Bool = false) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        let pixels = Double(size.width * size.height)
        // About 0.07 bits per pixel per frame: crisp text without 50 Mbit/s files.
        let bitrate = min(45_000_000, max(6_000_000, pixels * Double(fps) * 0.07))
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        if paintsClicks {
            painter = ClickPainter()
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        } else {
            painter = nil
            adaptor = nil
        }

        systemAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 2))
        systemAudio.expectsMediaDataInRealTime = true
        writer.add(systemAudio)
        _systemAudioOn = systemAudioOn

        if mic {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 1))
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            self.mic = input
        } else {
            self.mic = nil
        }
        super.init()
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func aac(channels: Int) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }

    // MARK: Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid, writer.status == .writing else { return }
        switch type {
        case .screen: appendVideo(buffer)
        case .audio: appendAudio(buffer, to: systemAudio, silent: !_systemAudioOn)
        case .microphone: if let mic { appendAudio(buffer, to: mic, silent: false) }
        @unknown default: break
        }
    }

    private func appendVideo(_ buffer: CMSampleBuffer) {
        // Only frames with new content; idle and blank ones carry no picture.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let time = buffer.presentationTimeStamp
        if !started {
            writer.startSession(atSourceTime: time)
            startTime = time
            started = true
        }
        guard !lastVideoTime.isValid || time > lastVideoTime else { return }
        guard video.isReadyForMoreMediaData else { droppedFrames += 1; return }
        if let painter, let adaptor {
            let info = attachments.first ?? [:]
            if let rect = info[.contentRect] as! CFDictionary?, let content = CGRect(dictionaryRepresentation: rect) { lastContent = content }
            if let scale = info[.scaleFactor] as? CGFloat { lastScale = scale }
            lastPixels = pixels
            let painted = painter.hasRings(at: time) ? painter.paint(pixels, at: time, content: lastContent, scale: lastScale) : nil
            if adaptor.append(painted ?? pixels, withPresentationTime: time) {
                lastVideoTime = time
                writtenFrames += 1
            }
            return
        }
        if video.append(buffer) {
            lastVideoTime = time
            writtenFrames += 1
        }
    }

    // MARK: Click rings (window recordings)

    /// A click at `point` (global, top-left origin) on the window, then at `windowBounds`.
    func addClick(at point: CGPoint, windowBounds: CGRect, secondary: Bool) {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async {
            guard let painter = self.painter else { return }
            painter.add(at: point, in: windowBounds, secondary: secondary, time: time)
            self.startTicking()
        }
    }

    /// Repaints the last frame at the frame rate while a ring is playing, so it animates over a window
    /// that isn't changing; real frames, when they come, take over.
    private func startTicking() {
        guard ticker == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: CMTimeGetSeconds(frameDuration), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        ticker = timer
        timer.resume()
    }

    private func tick() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard let painter, painter.hasRings(at: now) else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard started, writer.status == .writing, let adaptor, let pixels = lastPixels,
              CMTimeGetSeconds(CMTimeSubtract(now, lastVideoTime)) >= CMTimeGetSeconds(frameDuration) * 0.9,
              video.isReadyForMoreMediaData,
              let painted = painter.paint(pixels, at: now, content: lastContent, scale: lastScale) else { return }
        if adaptor.append(painted, withPresentationTime: now) {
            lastVideoTime = now
            writtenFrames += 1
        }
    }

    private func appendAudio(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput, silent: Bool) {
        // Sound from before the first frame would start the video late.
        guard started, buffer.presentationTimeStamp >= startTime, input.isReadyForMoreMediaData else { return }
        if silent, let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            if CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) != noErr { return }
        }
        input.append(buffer)
    }

    /// Closes the file. Call after the stream has stopped.
    func finish() async -> Error? {
        await withCheckedContinuation { (done: CheckedContinuation<Error?, Never>) in
            queue.async {
                self.ticker?.cancel()
                self.ticker = nil
                guard self.writer.status == .writing, self.started else {
                    self.writer.cancelWriting()
                    done.resume(returning: self.writer.error)
                    return
                }
                self.video.markAsFinished()
                self.systemAudio.markAsFinished()
                self.mic?.markAsFinished()
                // The last picture stays up for a frame instead of vanishing at once.
                self.writer.endSession(atSourceTime: CMTimeAdd(self.lastVideoTime, self.frameDuration))
                self.writer.finishWriting {
                    done.resume(returning: self.writer.status == .failed ? self.writer.error : nil)
                }
            }
        }
    }
}

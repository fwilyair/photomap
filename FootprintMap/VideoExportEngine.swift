import SwiftUI
import AVFoundation
import CoreImage
import Photos

@MainActor
@Observable
class VideoExportEngine {
    enum ExportStatus: Equatable {
        case idle
        case preparing
        case exporting(progress: Double)
        case completed(url: URL)
        case failed(Error)
        
        var isExporting: Bool {
            if case .exporting = self { return true }
            if case .preparing = self { return true }
            return false
        }
        
        static func == (lhs: ExportStatus, rhs: ExportStatus) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.preparing, .preparing): return true
            case (.exporting(let a), .exporting(let b)): return a == b
            case (.completed(let a), .completed(let b)): return a == b
            case (.failed, .failed): return true
            default: return false
            }
        }
    }
    
    var status: ExportStatus = .idle
    
    struct ExportConfig {
        var resolution: CGSize = UIScreen.main.nativeBounds.size
        var fps: Int = 30  // 30fps is sufficient for export, reduces CPU load
        var includeMusic: Bool = true
        var includeWatermark: Bool = true
        var watermarkText: String = ""
    }
    
    // AVAssetWriter components
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var displayLink: CADisplayLink?
    private var frameCount: Int = 0
    private var exportStartTime: CFTimeInterval = 0
    
    // References during export
    private weak var captureView: UIView?
    private var exportConfig: ExportConfig?
    private var outputURL: URL?
    
    // Completion tracking
    private var totalDuration: TimeInterval = 0
    private weak var playbackController: PlaybackController?
    
    /// Start live export — captures frames from the visible view during playback.
    func startLiveExport(
        config: ExportConfig,
        captureView: UIView,
        playbackController: PlaybackController,
        thumbnailLoader: ThumbnailLoader,
        waypoints: [Waypoint]
    ) {
        status = .preparing
        self.captureView = captureView
        self.exportConfig = config
        self.playbackController = playbackController
        self.totalDuration = playbackController.duration + playbackController.montageDuration
        self.frameCount = 0
        
        // Pre-load all thumbnails before starting
        let allPhotoIDs = waypoints.flatMap { $0.photoIDs }
        thumbnailLoader.loadThumbnails(for: allPhotoIDs, size: CGSize(width: 1200, height: 1200))
        
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("PhotoTrail_\(UUID().uuidString).mp4")
        self.outputURL = url
        
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            
            // Use native screen pixel dimensions for video
            let pixelWidth = Int(config.resolution.width)
            let pixelHeight = Int(config.resolution.height)
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: pixelWidth,
                AVVideoHeightKey: pixelHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 20_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: config.fps
                ]
            ]
            
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true  // We're writing in real-time from display link
            
            let bufferAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: pixelWidth,
                kCVPixelBufferHeightKey as String: pixelHeight
            ]
            
            let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: bufferAttrs
            )
            
            if writer.canAdd(input) { writer.add(input) }
            
            guard writer.startWriting() else {
                status = .failed(writer.error ?? NSError(domain: "VideoExport", code: 1))
                return
            }
            
            writer.startSession(atSourceTime: .zero)
            
            self.assetWriter = writer
            self.videoInput = input
            self.adaptor = pixelBufferAdaptor
            
            // Recording is now driven by the view.
            // We just start our internal capture loop.
            // Start display link for frame capture
            exportStartTime = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(captureFrame(_:)))
            // Set preferred frame rate
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(config.fps), maximum: Float(config.fps))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
            
            status = .exporting(progress: 0)
            
        } catch {
            status = .failed(error)
        }
    }
    
    @objc private func captureFrame(_ link: CADisplayLink) {
        guard let view = captureView,
              let input = videoInput,
              let adaptor = adaptor,
              let config = exportConfig,
              input.isReadyForMoreMediaData else { return }
        
        let elapsed = CACurrentMediaTime() - exportStartTime
        let presentationTime = CMTime(seconds: elapsed, preferredTimescale: 600)
        
        // Capture current view state
        if let buffer = FrameCaptureUtility.captureView(view, size: config.resolution) {
            if !adaptor.append(buffer, withPresentationTime: presentationTime) {
                print("❌ Failed to append frame at \(elapsed)s")
            }
        }
        
        frameCount += 1
        
        // Update progress
        if totalDuration > 0 {
            let progress = min(1.0, elapsed / totalDuration)
            status = .exporting(progress: progress)
        }
        
        // Check if we've reached the end of the desired duration
        if elapsed >= totalDuration {
            finishExport()
        }
    }
    
    private func finishExport() {
        // Stop capturing
        displayLink?.invalidate()
        displayLink = nil
        
        guard let writer = assetWriter, let input = videoInput else {
            status = .failed(NSError(domain: "VideoExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Writer not initialized"]))
            return
        }
        
        input.markAsFinished()
        
        Task {
            await writer.finishWriting()
            
            if let url = outputURL {
                status = .completed(url: url)
            } else {
                status = .failed(NSError(domain: "VideoExport", code: 3, userInfo: [NSLocalizedDescriptionKey: "No output URL"]))
            }
            
            // Cleanup
            assetWriter = nil
            videoInput = nil
            adaptor = nil
            captureView = nil
            exportConfig = nil
            playbackController = nil
        }
    }
    
    func cancelExport() {
        displayLink?.invalidate()
        displayLink = nil
        playbackController?.stop()
        // Handle mid-export cancellation if playback stops?
        // For now, let it finish or wait for duration
        assetWriter?.cancelWriting()
        assetWriter = nil
        videoInput = nil
        adaptor = nil
        status = .idle
    }
}

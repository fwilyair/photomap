import SwiftUI
import MapKit
import AVFoundation
import CoreImage

@MainActor
@Observable
class BackgroundVideoSynthesizer {
    enum SynthesisStatus: Equatable {
        case idle
        case preparing
        case synthesizing(progress: Double)
        case completed(url: URL)
        case failed(String)
        
        var isActive: Bool {
            switch self {
            case .preparing, .synthesizing: return true
            default: return false
            }
        }
        
        static func == (lhs: SynthesisStatus, rhs: SynthesisStatus) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.preparing, .preparing): return true
            case (.synthesizing(let a), .synthesizing(let b)): return a == b
            case (.completed(let a), .completed(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }
    
    var status: SynthesisStatus = .idle
    
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    private let queue = DispatchQueue(label: "com.phototrail.synthesis", qos: .userInitiated)
    
    /// Entry point for background video synthesis
    func startSynthesis(
        waypoints: [Waypoint],
        photos: [PhotoAsset],
        style: MapStyleOption,
        duration: TimeInterval,
        montageDuration: TimeInterval
    ) {
        guard !waypoints.isEmpty else { 
            status = .failed("没有有效的足迹点")
            return 
        }
        
        status = .preparing
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoTrail_Export_\(UUID().uuidString).mp4")
        
        Task {
            do {
                // 1. Initialize Writer
                try setupWriter(outputURL: outputURL)
                
                // 2. Synthesis Loop
                try await performSynthesis(
                    waypoints: waypoints,
                    photos: photos,
                    style: style,
                    totalDuration: duration + montageDuration
                )
                
                // 3. Finish
                try await finishWriter()
                status = .completed(url: outputURL)
                
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
    
    private func setupWriter(outputURL: URL) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        // 1080p Export
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1920, // Vertical video for social sharing
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1920
            ]
        )
        
        if writer.canAdd(input) { writer.add(input) }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        self.assetWriter = writer
        self.videoInput = input
        self.adaptor = adaptor
    }
    
    private func performSynthesis(
        waypoints: [Waypoint],
        photos: [PhotoAsset],
        style: MapStyleOption,
        totalDuration: TimeInterval
    ) async throws {
        let fps = 30
        let totalFrames = Int(totalDuration * Double(fps))
        
        // Build the same spline as the playback
        let splineCoords = SplineRouteBuilder.buildSmoothSpline(waypoints: waypoints, isGCJ02Required: style.isGCJ02Required)
        
        for frame in 0..<totalFrames {
            if Task.isCancelled { throw NSError(domain: "Synthesis", code: -1, userInfo: [NSLocalizedDescriptionKey: "已取消"]) }
            
            let currentTime = Double(frame) / Double(fps)
            let progress = currentTime / totalDuration
            
            // Update Status
            await MainActor.run {
                self.status = .synthesizing(progress: progress)
            }
            
            // Create Frame
            let image = try await generateFrameImage(
                progress: progress,
                splineCoords: splineCoords,
                style: style,
                size: CGSize(width: 1080, height: 1920)
            )
            
            // Write Frame
            let presentationTime = CMTime(value: Int64(frame), timescale: Int32(fps))
            try await writeFrame(image: image, at: presentationTime)
        }
    }
    
    private func generateFrameImage(
        progress: Double,
        splineCoords: [CLLocationCoordinate2D],
        style: MapStyleOption,
        size: CGSize
    ) async throws -> UIImage {
        // Here we'd use MKMapSnapshotter or Mapbox Snapshotter
        // For standard plan: MapKit implementation
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = 2.0 // High DPI
        options.mapType = style == .appleSatellite ? .satellite : .standard
        
        // Calculate region based on progress (mirroring PlaybackController logic)
        // Simplified for now: center on current spline point
        let idx = min(splineCoords.count - 1, Int(progress * Double(splineCoords.count - 1)))
        let center = splineCoords[idx]
        options.region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
        
        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try await snapshotter.start()
        let mapImage = snapshot.image
        
        // Draw Overlay (Trajectory + Watermark)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            // 1. Draw Map
            mapImage.draw(in: CGRect(origin: .zero, size: size))
            
            // 2. Draw Polyline (Trajectory up to now)
            let path = UIBezierPath()
            let partialCoords = Array(splineCoords.prefix(idx + 1))
            if let first = partialCoords.first {
                let p = snapshot.point(for: first)
                path.move(to: p)
                for i in 1..<partialCoords.count {
                    path.addLine(to: snapshot.point(for: partialCoords[i]))
                }
            }
            UIColor.systemOrange.setStroke()
            path.lineWidth = 6.0
            path.lineCapStyle = .round
            path.stroke()
            
            // 3. Draw Active Flashback / Montage Photo
            // Use same logic as PlaybackController: we need to know WHICH photo is active at this progress.
            // For simplicity, we can pass the currently active image data if we have it, 
            // but in background, we'll need a different way to determine the active asset.
            
            // 4. Draw Watermark
            let watermark = "PhotoTrail"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5),
                .strokeColor: UIColor.black.withAlphaComponent(0.2),
                .strokeWidth: -1.0
            ]
            watermark.draw(at: CGPoint(x: 50, y: size.height - 120), withAttributes: attrs)
        }
    }
    
    private func writeFrame(image: UIImage, at time: CMTime) async throws {
        guard let adaptor = adaptor, let input = videoInput else { return }
        
        while !input.isReadyForMoreMediaData {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        
        let buffer = try createPixelBuffer(from: image)
        adaptor.append(buffer, withPresentationTime: time)
    }
    
    private func createPixelBuffer(from image: UIImage) throws -> CVPixelBuffer {
        let size = CGSize(width: 1080, height: 1920)
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        
        guard let buffer = pixelBuffer else { 
            throw NSError(domain: "Synthesis", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法创建位图缓冲区"])
        }
        
        CVPixelBufferLockBaseAddress(buffer, .init(rawValue: 0))
        let data = CVPixelBufferGetBaseAddress(buffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: data, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        context?.draw(image.cgImage!, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(buffer, .init(rawValue: 0))
        
        return buffer
    }
    
    private func finishWriter() async throws {
        videoInput?.markAsFinished()
        await assetWriter?.finishWriting()
        assetWriter = nil
        videoInput = nil
        adaptor = nil
    }
    
    func reset() {
        status = .idle
    }
}

import Foundation
import AVFoundation
import CoreLocation
import MapKit
import UIKit
import Photos

/// BackgroundVideoSynthesizer (V5.1 - Stability Patch)
/// 修复了主线程 Actor 冲突导致的崩溃，优化了关键路径耗时操作。
final class BackgroundVideoSynthesizer: ObservableObject {
    enum Status: Equatable {
        case idle
        case preparing
        case synthesizing(progress: Double)
        case completed(url: URL)
        case failed(String)
        
        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.preparing, .preparing): return true
            case (.synthesizing(let p1), .synthesizing(let p2)): return p1 == p2
            case (.completed(let u1), .completed(let u2)): return u1 == u2
            case (.failed(let e1), .failed(let e2)): return e1 == e2
            default: return false
            }
        }
    }
    
    @Published var status: Status = .idle
    
    // Core data (Pass-through to avoid Actor isolation issues during synthesis)
    private var imageManager = PHCachingImageManager()
    
    func startSynthesis(
        waypoints: [Waypoint],
        splineCoords: [CLLocationCoordinate2D],
        photos: [PhotoAsset],
        mapStyle: MapStyleOption,
        duration: TimeInterval,
        resolution: CGSize
    ) {
        // Ensure we handle status update on main thread
        updateStatus(.preparing)
        
        // 1. 预加载图片 (异步)
        preloadPhotos(photos) { [weak self] photoThumbnails in
            guard let self = self else { return }
            
            // 2. 获取底图
            self.fetchLargeMapSnapshot(
                splineCoords: splineCoords,
                mapStyle: mapStyle,
                duration: duration,
                resolution: resolution,
                photos: photos,
                photoThumbnails: photoThumbnails
            )
        }
    }
    
    private func updateStatus(_ newStatus: Status) {
        DispatchQueue.main.async {
            self.status = newStatus
        }
    }
    
    private func preloadPhotos(_ photos: [PhotoAsset], completion: @escaping ([String: UIImage]) -> Void) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        
        let assetsWithIDs = photos.compactMap { photo -> (String, PHAsset)? in
            guard let ph = photo.phAsset else { return nil }
            return (photo.id, ph)
        }
        
        var results: [String: UIImage] = [:]
        let group = DispatchGroup()
        let lock = NSLock()
        
        for (id, asset) in assetsWithIDs {
            group.enter()
            imageManager.requestImage(for: asset, targetSize: CGSize(width: 800, height: 800), contentMode: .aspectFill, options: options) { image, _ in
                if let image = image {
                    lock.lock()
                    results[id] = image
                    lock.unlock()
                }
                group.leave()
            }
        }
        
        group.notify(queue: .global()) {
            completion(results)
        }
    }
    
    private func fetchLargeMapSnapshot(
        splineCoords: [CLLocationCoordinate2D],
        mapStyle: MapStyleOption,
        duration: TimeInterval,
        resolution: CGSize,
        photos: [PhotoAsset],
        photoThumbnails: [String: UIImage]
    ) {
        guard !splineCoords.isEmpty else {
            updateStatus(.failed("No coordinates found for route."))
            return
        }
        
        // 计算 Bounding Box
        var minLat = splineCoords[0].latitude
        var maxLat = splineCoords[0].latitude
        var minLon = splineCoords[0].longitude
        var maxLon = splineCoords[0].longitude
        
        for coord in splineCoords {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }
        
        let latDelta = maxLat - minLat
        let lonDelta = maxLon - minLon
        let padding = 0.2
        
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.005, latDelta * (1 + 2 * padding)), longitudeDelta: max(0.005, lonDelta * (1 + 2 * padding)))
        )
        
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: 2048, height: 2048)
        options.scale = 2.0
        options.mapType = (mapStyle == .appleSatellite) ? .satellite : .standard
        
        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start(with: .global(qos: .userInitiated)) { [weak self] snapshot, error in
            guard let self = self, let snapshot = snapshot else {
                self?.updateStatus(.failed("Map snapshot failed: \(error?.localizedDescription ?? "unknown")"))
                return
            }
            
            // 3. 构建渲染环境
            self.generateVideo(
                snapshot: snapshot,
                splineCoords: splineCoords,
                duration: duration,
                resolution: resolution,
                photos: photos,
                photoThumbnails: photoThumbnails
            )
        }
    }
    
    private func generateVideo(
        snapshot: MKMapSnapshotter.Snapshot,
        splineCoords: [CLLocationCoordinate2D],
        duration: TimeInterval,
        resolution: CGSize,
        photos: [PhotoAsset],
        photoThumbnails: [String: UIImage]
    ) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoTrail_V5_\(UUID().uuidString).mp4")
        
        // Normalize resolution to even
        let exportWidth = Int(resolution.width) / 2 * 2
        let exportHeight = Int(resolution.height) / 2 * 2
        let finalResolution = CGSize(width: exportWidth, height: exportHeight)
        
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            updateStatus(.failed("Could not create AVAssetWriter"))
            return
        }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: exportWidth,
            AVVideoHeightKey: exportHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        // 4. 构建 CALayer 树 (在后台线程构建，不触碰 UIKit 对象)
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: finalResolution)
        rootLayer.backgroundColor = UIColor.black.cgColor
        
        let mapSize = snapshot.image.size
        let mapLayer = CALayer()
        mapLayer.contents = snapshot.image.cgImage
        mapLayer.frame = CGRect(origin: .zero, size: mapSize)
        rootLayer.addSublayer(mapLayer)
        
        // 预计算所有点，因为在渲染循环中调用 snapshot.point(for:) 可能很慢且不线程安全
        let points = splineCoords.map { snapshot.point(for: $0) }
        
        // 轨迹
        let pathLayer = CAShapeLayer()
        let path = UIBezierPath()
        if let first = points.first {
            path.move(to: first)
            for i in 1..<points.count {
                path.addLine(to: points[i])
            }
        }
        pathLayer.path = path.cgPath
        pathLayer.strokeColor = UIColor.orange.cgColor
        pathLayer.lineWidth = 12
        pathLayer.lineCap = .round
        pathLayer.lineJoin = .round
        pathLayer.fillColor = nil
        pathLayer.strokeEnd = 0
        mapLayer.addSublayer(pathLayer)
        
        // 轨迹动画
        let pathAnim = CABasicAnimation(keyPath: "strokeEnd")
        pathAnim.fromValue = 0
        pathAnim.toValue = 1
        pathAnim.duration = duration
        pathAnim.beginTime = AVCoreAnimationBeginTimeAtZero
        pathAnim.fillMode = .forwards
        pathAnim.isRemovedOnCompletion = false
        pathLayer.add(pathAnim, forKey: "path")
        
        // 摄像机平移动画
        let posAnim = CAKeyframeAnimation(keyPath: "position")
        var posValues: [CGPoint] = []
        for point in points {
            let newPos = CGPoint(
                x: mapSize.width/2 + (finalResolution.width/2 - point.x),
                y: mapSize.height/2 + (finalResolution.height/2 - point.y)
            )
            posValues.append(newPos)
        }
        posAnim.values = posValues
        posAnim.duration = duration
        posAnim.beginTime = AVCoreAnimationBeginTimeAtZero
        posAnim.fillMode = .forwards
        posAnim.isRemovedOnCompletion = false
        mapLayer.add(posAnim, forKey: "camera")
        
        // 照片弹出
        for photo in photos {
            let point = snapshot.point(for: photo.location)
            let photoLayer = CALayer()
            photoLayer.contents = photoThumbnails[photo.id]?.cgImage
            photoLayer.frame = CGRect(x: point.x - 120, y: point.y - 120, width: 240, height: 240)
            photoLayer.cornerRadius = 24
            photoLayer.masksToBounds = true
            photoLayer.borderColor = UIColor.white.cgColor
            photoLayer.borderWidth = 6
            photoLayer.opacity = 0
            mapLayer.addSublayer(photoLayer)
            
            let closestIdx = findClosestPointIndex(target: point, points: points)
            let startTime = duration * (Double(closestIdx) / Double(max(1, points.count - 1)))
            
            let opacityAnim = CABasicAnimation(keyPath: "opacity")
            opacityAnim.fromValue = 0
            opacityAnim.toValue = 1
            opacityAnim.beginTime = AVCoreAnimationBeginTimeAtZero + startTime
            opacityAnim.duration = 0.4
            opacityAnim.fillMode = .forwards
            opacityAnim.isRemovedOnCompletion = false
            photoLayer.add(opacityAnim, forKey: "opacity")
            
            let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
            scaleAnim.values = [0, 1.1, 1.0]
            scaleAnim.beginTime = AVCoreAnimationBeginTimeAtZero + startTime
            scaleAnim.duration = 0.4
            scaleAnim.fillMode = .forwards
            scaleAnim.isRemovedOnCompletion = false
            photoLayer.add(scaleAnim, forKey: "scale")
        }
        
        // 5. 渲染循环
        let fps = 30
        let totalFrames = Int(duration * Double(fps))
        var currentFrame = 0
        
        input.requestMediaDataWhenReady(on: .global(qos: .userInitiated)) {
            while input.isReadyForMoreMediaData {
                if currentFrame >= totalFrames {
                    input.markAsFinished()
                    writer.finishWriting {
                        self.updateStatus(.completed(url: outputURL))
                    }
                    return
                }
                
                autoreleasepool {
                    let timestamp = Double(currentFrame) / Double(fps)
                    let time = CMTime(seconds: timestamp, preferredTimescale: 600)
                    
                    if let buffer = self.renderLayer(rootLayer, at: timestamp, size: finalResolution) {
                        if !adaptor.append(buffer, withPresentationTime: time) {
                            print("Append failed at \(currentFrame)")
                        }
                    }
                    
                    currentFrame += 1
                }
                
                if currentFrame % 10 == 0 || currentFrame == totalFrames {
                    self.updateStatus(.synthesizing(progress: Double(currentFrame) / Double(totalFrames)))
                }
            }
        }
    }
    
    private func renderLayer(_ layer: CALayer, at time: TimeInterval, size: CGSize) -> CVPixelBuffer? {
        layer.speed = 0
        layer.timeOffset = time
        
        let width = Int(size.width)
        let height = Int(size.height)
        
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        
        if let context = context {
            layer.render(in: context)
        }
        
        return buffer
    }
    
    private func findClosestPointIndex(target: CGPoint, points: [CGPoint]) -> Int {
        var minDist = CGFloat.infinity
        var idx = 0
        for (i, p) in points.enumerated() {
            let d = pow(target.x - p.x, 2) + pow(target.y - p.y, 2)
            if d < minDist {
                minDist = d
                idx = i
            }
        }
        return idx
    }
}

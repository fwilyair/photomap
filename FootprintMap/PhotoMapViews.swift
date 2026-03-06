import SwiftUI
import MapKit
import CoreLocation
import Photos

// MARK: - Data Models

struct PhotoAsset: Identifiable, Hashable, Sendable {
    let id: String
    let location: CLLocationCoordinate2D
    let creationDate: Date
    
    static func == (lhs: PhotoAsset, rhs: PhotoAsset) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct Waypoint: Identifiable, Equatable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let photoCount: Int
    let photoIDs: [String]
    let dateRange: (start: Date, end: Date)
    
    static func == (lhs: Waypoint, rhs: Waypoint) -> Bool {
        lhs.id == rhs.id
    }
}

class WaypointAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    var id: String
    var count: Int
    var photoIDs: [String]
    
    init(waypoint: Waypoint) {
        self.coordinate = waypoint.coordinate
        self.id = waypoint.id.uuidString
        self.count = waypoint.photoCount
        self.photoIDs = waypoint.photoIDs
        super.init()
    }
}

// MARK: - CADisplayLink Proxy to prevent retain cycles
class DisplayLinkProxy: NSObject {
    weak var target: AnyObject?
    let selector: Selector
    init(target: AnyObject, selector: Selector) {
        self.target = target
        self.selector = selector
        super.init()
    }
    @objc func tick(_ sender: CADisplayLink) {
        _ = target?.perform(selector, with: sender)
    }
}

// MARK: - Playback Engine (CADisplayLink driven)

@MainActor
@Observable
class PlaybackEngine {
    var isPlaying = false
    var isPreparing = false
    var progress: Double = 0.0 // 0.0 to 1.0
    var duration: TimeInterval = 10.0 // 5s, 10s, 30s
    
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var startProgress: Double = 0.0
    
    private let prepareDuration: TimeInterval = 1.8 // Seconds to wait for camera to lock on start
    
    func togglePlayPause() {
        if isPlaying || isPreparing {
            pause()
        } else {
            play()
        }
    }
    
    func play() {
        if progress >= 1.0 {
            progress = 0.0
        }
        
        // If we are starting from 0, initiate the preparation phase
        if progress == 0.0 {
            isPreparing = true
            isPlaying = false
        } else {
            isPreparing = false
            isPlaying = true
        }
        
        startProgress = progress
        startTime = CACurrentMediaTime()
        
        displayLink?.invalidate()
        let proxy = DisplayLinkProxy(target: self, selector: #selector(handleDisplayLink(_:)))
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    
    func pause() {
        isPlaying = false
        isPreparing = false
        displayLink?.invalidate()
        displayLink = nil
    }
    
    func stop() {
        pause()
        progress = 0.0
    }
    
    func seek(to newProgress: Double) {
        progress = max(0.0, min(1.0, newProgress))
        if isPlaying || isPreparing {
            isPreparing = false // Manually seeking snaps us out of preparation
            isPlaying = true
            startProgress = progress
            startTime = CACurrentMediaTime()
        }
    }
    
    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - startTime
        
        if isPreparing {
            if elapsed >= prepareDuration {
                // Preparation finished, seamlessly transition into actual playback
                isPreparing = false
                isPlaying = true
                startTime = CACurrentMediaTime() // Reset start time for the actual run
                startProgress = 0.0
            } else {
                // Keep progress exactly at 0 to hold the camera at the start point
                self.progress = 0.0
            }
        } else if isPlaying {
            let addedProgress = elapsed / duration
            var newProgress = startProgress + addedProgress
            
            if newProgress >= 1.0 {
                newProgress = 1.0
                pause() // Auto pause at end
            }
            self.progress = newProgress
        }
    }
}

// MARK: - Smooth Spline Generation

struct SplineRouteBuilder {
    static func buildSmoothSpline(waypoints: [Waypoint]) -> [CLLocationCoordinate2D] {
        // 1. Deduplicate waypoints that are effectively identical to prevent division by zero (infinite tangents)
        var uniqueWaypoints: [Waypoint] = []
        for wp in waypoints {
            if let last = uniqueWaypoints.last {
                let dist = CLLocation(latitude: wp.coordinate.latitude, longitude: wp.coordinate.longitude)
                    .distance(from: CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude))
                if dist > 100.0 {
                    uniqueWaypoints.append(wp)
                }
            } else {
                uniqueWaypoints.append(wp)
            }
        }
        
        guard uniqueWaypoints.count > 1 else { return uniqueWaypoints.map { $0.coordinate } }
        
        // Convert to MKMapPoint for perfect Cartesian 2D interpolation, avoiding spherical distortion
        let mapPoints = uniqueWaypoints.map { MKMapPoint($0.coordinate) }
        
        if mapPoints.count == 2 {
            var route: [CLLocationCoordinate2D] = []
            let segments = 60
            for i in 0...segments {
                let t = Double(i) / Double(segments)
                let x = mapPoints[0].x + (mapPoints[1].x - mapPoints[0].x) * t
                let y = mapPoints[0].y + (mapPoints[1].y - mapPoints[0].y) * t
                route.append(MKMapPoint(x: x, y: y).coordinate)
            }
            return route
        }
        
        // Catmull-Rom requires 4 points per segment. We duplicate endpoints to close the spline nicely.
        var pts = [mapPoints[0]]
        pts.append(contentsOf: mapPoints)
        pts.append(mapPoints.last!)
        
        var smoothRoute: [CLLocationCoordinate2D] = []
        let steps = 60 // Points per spline segment for high-resolution curves
        
        // Centripetal Catmull-Rom requires calculating local knotted parameters.
        // We use an alpha of 0.5 (Centripetal) to ensure the curve doesn't create loops or overshoot tightly grouped points.
        func getT(t: Double, p0: MKMapPoint, p1: MKMapPoint) -> Double {
            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            let distSq = dx*dx + dy*dy
            let a = pow(distSq, 0.25) // alpha = 0.5
            return t + max(a, 0.0001) // Strict division by zero prevention
        }
        
        for i in 1..<(pts.count - 2) {
            let p0 = pts[i-1]
            let p1 = pts[i]
            let p2 = pts[i+1]
            let p3 = pts[i+2]
            
            let t0 = 0.0
            let t1 = getT(t: t0, p0: p0, p1: p1)
            let t2 = getT(t: t1, p0: p1, p1: p2)
            let t3 = getT(t: t2, p0: p2, p1: p3)
            
            for tInt in 0..<steps {
                let f = Double(tInt) / Double(steps)
                let t = t1 + f * (t2 - t1)
                
                let a1x = (t1-t)/(t1-t0)*p0.x + (t-t0)/(t1-t0)*p1.x
                let a1y = (t1-t)/(t1-t0)*p0.y + (t-t0)/(t1-t0)*p1.y
                
                let a2x = (t2-t)/(t2-t1)*p1.x + (t-t1)/(t2-t1)*p2.x
                let a2y = (t2-t)/(t2-t1)*p1.y + (t-t1)/(t2-t1)*p2.y
                
                let a3x = (t3-t)/(t3-t2)*p2.x + (t-t2)/(t3-t2)*p3.x
                let a3y = (t3-t)/(t3-t2)*p2.y + (t-t2)/(t3-t2)*p3.y // THIS WAS THE BUG: previously p0.longitude
                
                let b1x = (t2-t)/(t2-t0)*a1x + (t-t0)/(t2-t0)*a2x
                let b1y = (t2-t)/(t2-t0)*a1y + (t-t0)/(t2-t0)*a2y
                
                let b2x = (t3-t)/(t3-t1)*a2x + (t-t1)/(t3-t1)*a3x
                let b2y = (t3-t)/(t3-t1)*a2y + (t-t1)/(t3-t1)*a3y
                
                let cx = (t2-t)/(t2-t1)*b1x + (t-t1)/(t2-t1)*b2x
                let cy = (t2-t)/(t2-t1)*b1y + (t-t1)/(t2-t1)*b2y
                
                smoothRoute.append(MKMapPoint(x: cx, y: cy).coordinate)
            }
        }
        
        smoothRoute.append(mapPoints.last!.coordinate)
        return smoothRoute
    }
}

// MARK: - CoreAnimation Polyline Renderer

// Instead of using MKOverlayRenderer which draws on the Main Thread CPU and gets blocked by map tile loading,
// We use a hardware-accelerated CAShapeLayer overlaid directly on the MapView.
class SplineLayerManager {
    let shapeLayer = CAShapeLayer()
    
    init() {
        shapeLayer.strokeColor = UIColor.systemOrange.cgColor
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineWidth = 4.0
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        shapeLayer.strokeEnd = 1.0 // Fully draw whatever path is assigned
    }
    
    func updatePath(for splineCoords: [CLLocationCoordinate2D], in mapView: MKMapView, progressIndex: Double) {
        guard splineCoords.count > 1, progressIndex > 0 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shapeLayer.path = nil
            CATransaction.commit()
            return
        }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        let path = CGMutablePath()
        let firstCGPoint = mapView.convert(splineCoords[0], toPointTo: mapView)
        path.move(to: firstCGPoint)
        
        let maxIndex = min(splineCoords.count - 1, Int(ceil(progressIndex)))
        if maxIndex > 0 {
            for i in 1...maxIndex {
                if i == maxIndex {
                    // Precise interpolation of the tip of the line
                    let prev = splineCoords[i - 1]
                    let curr = splineCoords[i]
                    let remainder = progressIndex - Double(i - 1)
                    let lat = prev.latitude + (curr.latitude - prev.latitude) * remainder
                    let lon = prev.longitude + (curr.longitude - prev.longitude) * remainder
                    let exactEnd = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    let cgPoint = mapView.convert(exactEnd, toPointTo: mapView)
                    path.addLine(to: cgPoint)
                } else {
                    let cgPoint = mapView.convert(splineCoords[i], toPointTo: mapView)
                    path.addLine(to: cgPoint)
                }
            }
        }
        
        shapeLayer.path = path
        CATransaction.commit()
    }
}

// MARK: - Clustering Algorithm

struct PhotoClusterer {
    static func clusterPhotos(_ photos: [PhotoAsset], targetDuration: TimeInterval) -> [Waypoint] {
        guard !photos.isEmpty else { return [] }
        
        let maxWaypoints = max(5, Int(targetDuration * 2.5))
        let sorted = photos.sorted(by: { $0.creationDate < $1.creationDate })
        
        if sorted.count <= maxWaypoints {
            return sorted.map {
                Waypoint(coordinate: $0.location, photoCount: 1, photoIDs: [$0.id], dateRange: ($0.creationDate, $0.creationDate))
            }
        }
        
        var waypoints: [Waypoint] = []
        var currentGroup: [PhotoAsset] = [sorted[0]]
        
        let chunkSize = max(1, Int(ceil(Double(sorted.count) / Double(maxWaypoints))))
        
        for i in 1..<sorted.count {
            if currentGroup.count < chunkSize {
                currentGroup.append(sorted[i])
            } else {
                waypoints.append(createWaypoint(from: currentGroup))
                currentGroup = [sorted[i]]
            }
        }
        if !currentGroup.isEmpty {
            waypoints.append(createWaypoint(from: currentGroup))
        }
        
        return waypoints
    }
    
    private static func createWaypoint(from photos: [PhotoAsset]) -> Waypoint {
        let avgLat = photos.map { $0.location.latitude }.reduce(0, +) / Double(photos.count)
        let avgLon = photos.map { $0.location.longitude }.reduce(0, +) / Double(photos.count)
        return Waypoint(
            coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
            photoCount: photos.count,
            photoIDs: photos.map { $0.id },
            dateRange: (photos.first!.creationDate, photos.last!.creationDate)
        )
    }
}

// MARK: - Map View Representable

struct PhotoClusterMapView: UIViewRepresentable {
    var photos: [PhotoAsset]
    var waypoints: [Waypoint]
    var playbackProgress: Double  // State dependency to trigger `updateUIView` automatically
    var playbackDuration: TimeInterval
    var isPlaying: Bool
    var isPreparing: Bool
    var onAnnotationSelected: ((_ photoIDs: [String], _ screenPoint: CGPoint) -> Void)?
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var lastWaypoints: [Waypoint] = []
        var lastSplineCoords: [CLLocationCoordinate2D] = []
        var lastOverviewRect: MKMapRect?
        var lastProgress: Double = -1.0
        var lastIsPreparing: Bool = false
        var currentAltitude: CLLocationDistance?
        let splineManager = SplineLayerManager()
        var onAnnotationSelected: ((_ photoIDs: [String], _ screenPoint: CGPoint) -> Void)?
        var isPlayingOrPreparing = false
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            
            guard let wpAnn = annotation as? WaypointAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "waypoint") as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: wpAnn, reuseIdentifier: "waypoint")
            view.markerTintColor = .systemPink
            view.glyphText = "\(wpAnn.count)"
            view.titleVisibility = .hidden
            view.subtitleVisibility = .hidden
            view.displayPriority = .required
            return view
        }
        
        // Path needs to be recalculated when the map region physically changes (zooming/panning)
        // so the layer stays anchored to the geographic coordinates
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            if !lastSplineCoords.isEmpty {
                let targetIdxFloat = lastProgress * Double(max(0, lastSplineCoords.count - 1))
                splineManager.updatePath(for: lastSplineCoords, in: mapView, progressIndex: targetIdxFloat)
            }
        }
        
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard !isPlayingOrPreparing,
                  let wpAnn = view.annotation as? WaypointAnnotation else { return }
            let screenPoint = mapView.convert(wpAnn.coordinate, toPointTo: mapView)
            onAnnotationSelected?(wpAnn.photoIDs, screenPoint)
            mapView.deselectAnnotation(wpAnn, animated: false)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        
        mapView.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "waypoint")
        
        // Attach hardware accelerated line layer
        mapView.layer.addSublayer(context.coordinator.splineManager.shapeLayer)
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.isPlayingOrPreparing = isPlaying || isPreparing
        context.coordinator.onAnnotationSelected = onAnnotationSelected
        
        let splineCoords: [CLLocationCoordinate2D]
        
        // 1. Update Annotations, Overlays & Overview Bounds
        if context.coordinator.lastWaypoints != waypoints {
            context.coordinator.lastWaypoints = waypoints
            splineCoords = SplineRouteBuilder.buildSmoothSpline(waypoints: waypoints)
            context.coordinator.lastSplineCoords = splineCoords
            
            // Rebuild Annotations
            uiView.removeAnnotations(uiView.annotations)
            let newAnnotations = waypoints.map { WaypointAnnotation(waypoint: $0) }
            uiView.addAnnotations(newAnnotations)
            
            // Rebuild Overlays
            let startIdxFloat = playbackProgress * Double(max(0, splineCoords.count - 1))
            context.coordinator.splineManager.updatePath(for: splineCoords, in: uiView, progressIndex: startIdxFloat)
            
            // Calculate overview rect of BOTH waypoints and the curved spline!
            if !newAnnotations.isEmpty || !splineCoords.isEmpty {
                var zoomRect = MKMapRect.null
                for annotation in newAnnotations {
                    let pointRect = MKMapRect(origin: MKMapPoint(annotation.coordinate), size: MKMapSize(width: 0.1, height: 0.1))
                    zoomRect = zoomRect.union(pointRect)
                }
                for coord in splineCoords {
                    let pointRect = MKMapRect(origin: MKMapPoint(coord), size: MKMapSize(width: 0.1, height: 0.1))
                    zoomRect = zoomRect.union(pointRect)
                }
                
                let minSize: Double = 50000.0
                var finalWidth = zoomRect.size.width
                var finalHeight = zoomRect.size.height
                if finalWidth < minSize { finalWidth = minSize }
                if finalHeight < minSize { finalHeight = minSize }
                
                let center = MKMapPoint(x: zoomRect.midX, y: zoomRect.midY)
                zoomRect = MKMapRect(x: center.x - finalWidth/2, y: center.y - finalHeight/2, width: finalWidth, height: finalHeight)
                
                context.coordinator.lastOverviewRect = zoomRect
                
                // Initialize default full-view at time 0
                if playbackProgress == 0 {
                    context.coordinator.currentAltitude = nil
                    let edgePadding = UIEdgeInsets(top: 100, left: 50, bottom: 300, right: 50)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        uiView.setVisibleMapRect(zoomRect, edgePadding: edgePadding, animated: true)
                    }
                }
            }
        } else {
            splineCoords = context.coordinator.lastSplineCoords
        }
        
        // 2. Hardware Accelerated stroke updates
        // Rebuild exact path substring. (strokeEnd uses geographic length, which misaligns with our array-index camera logic)
        let targetIdxFloat = playbackProgress * Double(max(0, splineCoords.count - 1))
        context.coordinator.splineManager.updatePath(for: splineCoords, in: uiView, progressIndex: targetIdxFloat)
        
        // 3. Dynamic Cinematic Follow Camera
        let progressChanged = context.coordinator.lastProgress != playbackProgress
        let preparingChanged = context.coordinator.lastIsPreparing != isPreparing
        
        if progressChanged || preparingChanged {
            let justRewoundToZero = progressChanged && playbackProgress == 0.0 && context.coordinator.lastProgress != 0.0
            let justEnded = progressChanged && playbackProgress == 1.0 && context.coordinator.lastProgress != 1.0
            
            context.coordinator.lastProgress = playbackProgress
            context.coordinator.lastIsPreparing = isPreparing
            
            // Phase 1: Preparation flight (1.8s duration in engine, 1.5s animation here)
            if isPreparing && splineCoords.count > 0 {
                let exactCurrentCoord = splineCoords[0]
                
                let lookaheadSeconds = 3.0 // 3 seconds forward 
                let lookaheadProgress = lookaheadSeconds / playbackDuration
                let lookaheadIdxFloat = min(Double(splineCoords.count - 1), lookaheadProgress * Double(splineCoords.count - 1))
                
                let idx = min(splineCoords.count - 1, max(0, Int(lookaheadIdxFloat)))
                var exactFutureCoord = splineCoords[idx]
                if idx < splineCoords.count - 1 {
                    let remainder = lookaheadIdxFloat - Double(idx)
                    let c1 = splineCoords[idx]
                    let c2 = splineCoords[idx + 1]
                    exactFutureCoord = CLLocationCoordinate2D(
                        latitude: c1.latitude + (c2.latitude - c1.latitude) * remainder,
                        longitude: c1.longitude + (c2.longitude - c1.longitude) * remainder
                    )
                }
                
                let dist = CLLocation(latitude: exactCurrentCoord.latitude, longitude: exactCurrentCoord.longitude)
                    .distance(from: CLLocation(latitude: exactFutureCoord.latitude, longitude: exactFutureCoord.longitude))
                
                let targetAltitude = min(2500000.0, max(3000.0, dist * 2.2))
                context.coordinator.currentAltitude = targetAltitude // Seed altitude for continuous flight later
                
                let newCamera = MKMapCamera(lookingAtCenter: exactCurrentCoord, fromDistance: targetAltitude, pitch: 0, heading: 0)
                
                // Native smooth swoop utilizing the exact prep time
                UIView.animate(withDuration: 1.5, delay: 0, options: .curveEaseInOut) {
                    uiView.camera = newCamera
                }
            }
            // Phase 2: Returning to global overview at boundaries
            else if justRewoundToZero || justEnded {
                context.coordinator.currentAltitude = nil
                if let rect = context.coordinator.lastOverviewRect {
                    let edgePadding = UIEdgeInsets(top: 100, left: 50, bottom: 300, right: 50)
                    if justEnded {
                        // Smoothly fly back out with custom duration
                        // Approximate camera properties from the rect
                        let centerCoordinate = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
                        let distance = rect.size.width * 1.5 // Rough factor to fit rect
                        let newCamera = MKMapCamera(lookingAtCenter: centerCoordinate, fromDistance: distance, pitch: 0, heading: 0)
                        
                        // Wait a brief half-second on the final point, then float up slowly
                        UIView.animate(withDuration: 3.5, delay: 0.5, options: .curveEaseInOut) {
                            uiView.camera = newCamera
                        }
                    } else {
                        // Native fast snap for just rewinding manually
                        uiView.setVisibleMapRect(rect, edgePadding: edgePadding, animated: true)
                    }
                }
            }
            // Phase 3: Continuous Flight Camera Tracking
            else if playbackProgress > 0 && playbackProgress < 1.0 && splineCoords.count > 1 {
                let pointCount = splineCoords.count
                let targetIdxFloat = playbackProgress * Double(pointCount - 1)
                
                func interpolateCoord(at indexFloat: Double, in coords: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
                    let idx = min(coords.count - 1, max(0, Int(indexFloat)))
                    if idx == coords.count - 1 { return coords.last! }
                    let remainder = indexFloat - Double(idx)
                    let c1 = coords[idx]
                    let c2 = coords[idx + 1]
                    let lat = c1.latitude + (c2.latitude - c1.latitude) * remainder
                    let lon = c1.longitude + (c2.longitude - c1.longitude) * remainder
                    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
                
                let exactCurrentCoord = interpolateCoord(at: targetIdxFloat, in: splineCoords)
                
                let lookaheadSeconds = 3.0
                let lookaheadProgress = lookaheadSeconds / playbackDuration
                let lookaheadIdxFloat = min(Double(pointCount - 1), targetIdxFloat + (lookaheadProgress * Double(pointCount - 1)))
                let exactFutureCoord = interpolateCoord(at: lookaheadIdxFloat, in: splineCoords)
                
                let dist = CLLocation(latitude: exactCurrentCoord.latitude, longitude: exactCurrentCoord.longitude)
                    .distance(from: CLLocation(latitude: exactFutureCoord.latitude, longitude: exactFutureCoord.longitude))
                
                let baseAltitude: CLLocationDistance = 3000
                let maxAltitude: CLLocationDistance = 2500000
                let targetAltitude = min(maxAltitude, max(baseAltitude, dist * 2.2))
                
                let currentAlt = context.coordinator.currentAltitude ?? uiView.camera.altitude
                let lerpFactor = isPlaying ? 0.04 : 0.2 // Slightly faster lerp so camera keeps up vertically
                let smoothedAltitude = currentAlt + (targetAltitude - currentAlt) * lerpFactor
                context.coordinator.currentAltitude = smoothedAltitude
                
                let newCamera = MKMapCamera(lookingAtCenter: exactCurrentCoord, fromDistance: smoothedAltitude, pitch: 0, heading: 0)
                uiView.camera = newCamera
            }
        }
    }
}

// MARK: - Main View

struct FootprintMapView: View {
    var photos: [PhotoAsset]
    
    @State private var engine = PlaybackEngine()
    @State private var waypoints: [Waypoint] = []
    
    @State private var filteredPhotos: [PhotoAsset] = []
    
    // Filtering State
    @State private var isShowingFilter = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var endDate = Date()
    @State private var isControlsMinimized = false
    @State private var filterBounceTrigger = 0
    
    // Annotation interaction state
    @State private var selectedAnnotation: SelectedAnnotationInfo?
    @State private var thumbnailLoader = ThumbnailLoader()
    @State private var isShowingGallery = false
    @State private var galleryPhotoIDs: [String] = []
    @State private var fullScreenPhotoID: String?
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Map Layer strictly observes progress implicitly
            PhotoClusterMapView(
                photos: filteredPhotos,
                waypoints: waypoints,
                playbackProgress: engine.progress,
                playbackDuration: engine.duration,
                isPlaying: engine.isPlaying,
                isPreparing: engine.isPreparing,
                onAnnotationSelected: { ids, point in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        selectedAnnotation = SelectedAnnotationInfo(photoIDs: ids, screenPoint: point)
                    }
                    thumbnailLoader.loadThumbnails(for: ids)
                }
            )
            .ignoresSafeArea(edges: [.bottom, .horizontal])
            
            // Top Hint
            VStack {
                Text("模拟器缩放地图：按住键盘 `Option (⌥)` 键并用鼠标/触控板拖动")
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                Spacer()
            }
            
            // Fan thumbnail overlay
            if let selected = selectedAnnotation {
                FanThumbnailOverlay(
                    photoIDs: selected.photoIDs,
                    screenPoint: selected.screenPoint,
                    thumbnailLoader: thumbnailLoader,
                    onPhotoTap: { id in
                        fullScreenPhotoID = id
                        thumbnailLoader.loadThumbnails(for: [id], size: CGSize(width: 800, height: 800))
                    },
                    onMoreTap: {
                        galleryPhotoIDs = selected.photoIDs
                        thumbnailLoader.loadThumbnails(for: selected.photoIDs)
                        isShowingGallery = true
                    },
                    onDismiss: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedAnnotation = nil
                        }
                    }
                )
            }
            
            playbackControls
        }
        .navigationTitle("足迹轨道")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { 
                    filterBounceTrigger += 1
                    isShowingFilter.toggle() 
                }) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .symbolEffect(.bounce, value: filterBounceTrigger)
                }
            }
        }
        .sheet(isPresented: $isShowingFilter) {
            filterSheet
        }
        .onAppear {
            let sortedParams = photos.sorted(by: { $0.creationDate < $1.creationDate })
            
            // Set default date range to Dec 27, 2023 05:09 - Jan 1, 2024 12:42
            var componentsStart = DateComponents()
            componentsStart.year = 2023
            componentsStart.month = 12
            componentsStart.day = 27
            componentsStart.hour = 5
            componentsStart.minute = 9
            
            var componentsEnd = DateComponents()
            componentsEnd.year = 2024
            componentsEnd.month = 1
            componentsEnd.day = 1
            componentsEnd.hour = 12
            componentsEnd.minute = 42
            
            if let defaultStart = Calendar.current.date(from: componentsStart),
               let defaultEnd = Calendar.current.date(from: componentsEnd) {
                startDate = defaultStart
                endDate = defaultEnd
            }
            
            applyFilter()
        }
        .onDisappear {
            engine.stop()
        }
        .onChange(of: engine.isPlaying) { _, isPlaying in
            if isPlaying { withAnimation { selectedAnnotation = nil } }
        }
        .sheet(isPresented: $isShowingGallery) {
            MasonryGalleryView(
                photoIDs: galleryPhotoIDs,
                thumbnailLoader: thumbnailLoader,
                onPhotoTap: { id in
                    fullScreenPhotoID = id
                    thumbnailLoader.loadThumbnails(for: [id], size: CGSize(width: 800, height: 800))
                }
            )
            .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: Binding(
            get: { fullScreenPhotoID != nil },
            set: { if !$0 { fullScreenPhotoID = nil } }
        )) {
            if let id = fullScreenPhotoID {
                FullScreenPhotoView(photoID: id, thumbnailLoader: thumbnailLoader)
            }
        }
    }
    
    private func applyFilter() {
        engine.stop()
        let sorted = photos.sorted(by: { $0.creationDate < $1.creationDate })
        filteredPhotos = sorted.filter {
            $0.creationDate >= startDate && $0.creationDate <= endDate
        }
        recluster()
    }
    
    private func recluster() {
        let rawWaypoints = PhotoClusterer.clusterPhotos(filteredPhotos, targetDuration: engine.duration)
        var unique: [Waypoint] = []
        for wp in rawWaypoints {
            if let last = unique.last {
                let dist = CLLocation(latitude: wp.coordinate.latitude, longitude: wp.coordinate.longitude)
                    .distance(from: CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude))
                if dist > 100.0 { unique.append(wp) }
            } else {
                unique.append(wp)
            }
        }
        waypoints = unique
    }
    
    private var currentDisplayDate: Date? {
        guard !waypoints.isEmpty else { return nil }
        let progress = engine.progress
        if progress <= 0 { return waypoints.first?.dateRange.start }
        if progress >= 1.0 { return waypoints.last?.dateRange.end }
        
        let targetIdxFloat = progress * Double(waypoints.count - 1)
        let idx = min(Int(targetIdxFloat), waypoints.count - 1)
        
        return waypoints[idx].dateRange.start
    }
    
    // Filter UI Sheet
    @ViewBuilder
    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("选择播放的时间段")) {
                    DatePicker("开始时间", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("结束时间", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                }
                
                Section {
                    Button("应用筛选并重置播放") {
                        applyFilter()
                        isShowingFilter = false
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .foregroundColor(.blue)
                }
            }
            .navigationTitle("设置轨道时间段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        isShowingFilter = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    // Playback UI Panel
    @ViewBuilder
    private var playbackControls: some View {
        Group {
            if isControlsMinimized {
                // Minimized UI Panel during playback
                HStack(spacing: 16) {
                    Slider(
                        value: Binding(
                            get: { engine.progress },
                            set: { newProgress in
                                engine.seek(to: newProgress)
                            }
                        ),
                        in: 0.0...1.0
                    )
                    .accentColor(.orange)
                    
                    Button(action: {
                        withAnimation(.spring()) {
                            engine.togglePlayPause()
                        }
                    }) {
                        ZStack {
                            Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.orange)
                                .symbolEffect(.bounce, value: engine.isPlaying)
                                .symbolEffect(.pulse, isActive: engine.isPlaying)
                                
                            if engine.isPreparing {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.0)
                            }
                        }
                    }
                    
                    if !engine.isPlaying && !engine.isPreparing {
                        Button(action: {
                            withAnimation(.spring()) {
                                isControlsMinimized = false
                                engine.seek(to: 0.0) // Reset progress back to beginning upon expanding
                            }
                        }) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.gray)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
            } else {
                // Full UI Panel
                VStack(spacing: 16) {
                    // Duration selector
                    Picker("总时长", selection: Binding(
                        get: { engine.duration },
                        set: { newDuration in
                            engine.duration = newDuration
                            recluster()
                        }
                    )) {
                        Text("5秒").tag(5.0)
                        Text("10秒").tag(10.0)
                        Text("30秒").tag(30.0)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 8)
                    
                    // Date Display
                    if let displayDate = currentDisplayDate {
                        Text(displayDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.headline.monospacedDigit())
                            .foregroundColor(.primary)
                    } else {
                        Text("该时段内无照片")
                            .foregroundColor(.secondary)
                    }
                    
                    // Slider (0.0 - 1.0 progress)
                    if !waypoints.isEmpty {
                        Slider(
                            value: Binding(
                                get: { engine.progress },
                                set: { newProgress in
                                    engine.seek(to: newProgress)
                                }
                            ),
                            in: 0.0...1.0
                        )
                        .accentColor(.orange)
                    }
                    
                    // Playback controls
                    HStack(spacing: 32) {
                        Button(action: {
                            withAnimation { engine.seek(to: 0.0) }
                        }) {
                            Image(systemName: "backward.end.fill")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                        .disabled(waypoints.isEmpty)
                        
                        Button(action: {
                            withAnimation(.spring()) {
                                isControlsMinimized = true
                                engine.togglePlayPause()
                            }
                        }) {
                            ZStack {
                                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 50))
                                    .foregroundStyle(waypoints.isEmpty ? Color.gray : Color.orange)
                                    .symbolEffect(.bounce, value: engine.isPlaying)
                                    .symbolEffect(.pulse, isActive: engine.isPlaying)
                                    
                                if engine.isPreparing {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(1.2)
                                }
                            }
                        }
                        .disabled(waypoints.isEmpty)
                        
                        Button(action: {
                            withAnimation { engine.seek(to: 1.0) }
                        }) {
                            Image(systemName: "forward.end.fill")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                        .disabled(waypoints.isEmpty)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 32)
        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isControlsMinimized)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: engine.isPlaying || engine.isPreparing)
    }
}

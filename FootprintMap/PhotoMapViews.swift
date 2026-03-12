import SwiftUI
import MapKit
import CoreLocation
import Photos

// MARK: - Data Models

struct PhotoAsset: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let location: CLLocationCoordinate2D
    let creationDate: Date
    
    enum CodingKeys: String, CodingKey {
        case id
        case latitude
        case longitude
        case creationDate
    }
    
    init(id: String, location: CLLocationCoordinate2D, creationDate: Date) {
        self.id = id
        self.location = location
        self.creationDate = creationDate
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let lat = try container.decode(Double.self, forKey: .latitude)
        let lon = try container.decode(Double.self, forKey: .longitude)
        location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        creationDate = try container.decode(Date.self, forKey: .creationDate)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(location.latitude, forKey: .latitude)
        try container.encode(location.longitude, forKey: .longitude)
        try container.encode(creationDate, forKey: .creationDate)
    }
    
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
    var duration: TimeInterval = 10.0 // Dynamically calculated
    
    func calculateDynamicDuration(for waypoints: [Waypoint]) {
        guard !waypoints.isEmpty else {
            self.duration = 5.0
            return
        }
        
        var totalDuration: TimeInterval = 0.0
        
        for i in 0..<waypoints.count {
            totalDuration += 0.9 // Base time per waypoint (snappy local pacing)
            
            if i < waypoints.count - 1 {
                let wp1 = waypoints[i]
                let wp2 = waypoints[i+1]
                let loc1 = CLLocation(latitude: wp1.coordinate.latitude, longitude: wp1.coordinate.longitude)
                let loc2 = CLLocation(latitude: wp2.coordinate.latitude, longitude: wp2.coordinate.longitude)
                let dist = loc1.distance(from: loc2)
                
                // Adaptive Long-Jump: If distance > 50km, grant extra time for MapKit caching and visual transfer
                if dist > 50_000 {
                    // Grant ~2.5s per 100km to let the map load tiles steadily, up to a max jump delay of 10s per leg
                    let extraTime = min(10.0, (dist / 100_000.0) * 2.5)
                    totalDuration += extraTime
                }
            }
        }
        
        // UX Research indicates 30-45 seconds is the upper bound for short-form memory recaps before attention drop-off.
        // Capping at 45s maximum to prevent visual fatigue on extremely dense tracks.
        self.duration = max(5.0, min(45.0, totalDuration))
    }
    
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var startProgress: Double = 0.0
    
    private let prepareDuration: TimeInterval = 3.0 // 1.8s for camera flight + 1.2s buffer/focus time
    
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
    static func clusterPhotos(_ photos: [PhotoAsset]) -> [Waypoint] {
        guard !photos.isEmpty else { return [] }
        let sorted = photos.sorted(by: { $0.creationDate < $1.creationDate })
        
        // Pass 1: Coarse split by large gaps (> 4 hours OR > 10 km)
        var coarseChunks: [[PhotoAsset]] = []
        var currentChunk: [PhotoAsset] = [sorted[0]]
        
        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let curr = sorted[i]
            
            let timeDelta = curr.creationDate.timeIntervalSince(prev.creationDate)
            let prevLoc = CLLocation(latitude: prev.location.latitude, longitude: prev.location.longitude)
            let currLoc = CLLocation(latitude: curr.location.latitude, longitude: curr.location.longitude)
            let distDelta = currLoc.distance(from: prevLoc)
            
            if timeDelta > 3600 * 4 || distDelta > 10000 {
                // Major break, commit chunk
                coarseChunks.append(currentChunk)
                currentChunk = [curr]
            } else {
                currentChunk.append(curr)
            }
        }
        if !currentChunk.isEmpty {
            coarseChunks.append(currentChunk)
        }
        
        // Pass 2: Fine split for dense chunks (> 10 photos)
        var finalWaypoints: [Waypoint] = []
        
        for chunk in coarseChunks {
            if chunk.count <= 10 {
                // Sparse chunk, use as-is
                finalWaypoints.append(createWaypoint(from: chunk))
            } else {
                // Dense chunk (e.g. amusement park), apply fine-grained splitting
                var fineChunk: [PhotoAsset] = [chunk[0]]
                for i in 1..<chunk.count {
                    let prev = chunk[i - 1]
                    let curr = chunk[i]
                    
                    let timeDelta = curr.creationDate.timeIntervalSince(prev.creationDate)
                    let prevLoc = CLLocation(latitude: prev.location.latitude, longitude: prev.location.longitude)
                    let currLoc = CLLocation(latitude: curr.location.latitude, longitude: curr.location.longitude)
                    let distDelta = currLoc.distance(from: prevLoc)
                    
                    // Fine threshold: 5 minutes OR 50 meters
                    if timeDelta > 300 || distDelta > 50 {
                        finalWaypoints.append(createWaypoint(from: fineChunk))
                        fineChunk = [curr]
                    } else {
                        fineChunk.append(curr)
                    }
                }
                if !fineChunk.isEmpty {
                    finalWaypoints.append(createWaypoint(from: fineChunk))
                }
            }
        }
        
        return finalWaypoints
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
    var mapType: MKMapType = .standard
    var onAnnotationSelected: ((_ photoIDs: [String], _ screenPoint: CGPoint) -> Void)?
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var lastWaypoints: [Waypoint] = []
        var lastSplineCoords: [CLLocationCoordinate2D] = []
        var lastOverviewRect: MKMapRect?
        var lastProgress: Double = -1.0
        var lastIsPreparing: Bool = false
        var currentAltitude: CLLocationDistance?
        var initialCamera: MKMapCamera?
        let splineManager = SplineLayerManager()
        var onAnnotationSelected: ((_ photoIDs: [String], _ screenPoint: CGPoint) -> Void)?
        var isPlayingOrPreparing = false
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            
            guard let wpAnn = annotation as? WaypointAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "waypoint") as? WaypointAnnotationView ?? WaypointAnnotationView(annotation: wpAnn, reuseIdentifier: "waypoint")
            view.displayPriority = .required
            let zPriority = MKAnnotationViewZPriority(rawValue: 1000 + Float(wpAnn.count))
            view.zPriority = zPriority
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
        mapView.mapType = mapType
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
        
        if uiView.mapType != mapType {
            uiView.mapType = mapType
        }
        
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
            let justStartedPreparing = preparingChanged && isPreparing && !context.coordinator.lastIsPreparing
            
            if justStartedPreparing {
                context.coordinator.initialCamera = uiView.camera.copy() as? MKMapCamera
            }
            
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
                UIView.animate(withDuration: 1.8, delay: 0, options: .curveEaseInOut) {
                    uiView.camera = newCamera
                }
            }
            // Phase 2: Returning to global overview at boundaries
            else if justRewoundToZero || justEnded {
                context.coordinator.currentAltitude = nil
                
                if let initialCamera = context.coordinator.initialCamera {
                    if justEnded {
                        // Smoothly fly back out to user's exact pre-playback camera state
                        UIView.animate(withDuration: 3.5, delay: 0.5, options: .curveEaseInOut) {
                            uiView.camera = initialCamera
                        }
                    } else {
                        // Native fast snap for just rewinding manually
                        uiView.setCamera(initialCamera, animated: true)
                    }
                } else if let rect = context.coordinator.lastOverviewRect {
                    // Fallback to bounding rect if no initial camera saved
                    let edgePadding = UIEdgeInsets(top: 100, left: 50, bottom: 300, right: 50)
                    if justEnded {
                        let centerCoordinate = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
                        let distance = rect.size.width * 1.5
                        let newCamera = MKMapCamera(lookingAtCenter: centerCoordinate, fromDistance: distance, pitch: 0, heading: 0)
                        
                        UIView.animate(withDuration: 3.5, delay: 0.5, options: .curveEaseInOut) {
                            uiView.camera = newCamera
                        }
                    } else {
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
                
                let lookaheadSeconds = 0.8 // Tighter lookahead for faster localized sweeps
                let lookaheadProgress = lookaheadSeconds / playbackDuration
                let lookaheadIdxFloat = min(Double(pointCount - 1), targetIdxFloat + (lookaheadProgress * Double(pointCount - 1)))
                let exactFutureCoord = interpolateCoord(at: lookaheadIdxFloat, in: splineCoords)
                
                let dist = CLLocation(latitude: exactCurrentCoord.latitude, longitude: exactCurrentCoord.longitude)
                    .distance(from: CLLocation(latitude: exactFutureCoord.latitude, longitude: exactFutureCoord.longitude))
                
                let baseAltitude: CLLocationDistance = 3000
                let maxAltitude: CLLocationDistance = 600000 // Raised cap to 600km to tolerate cross-city caching
                let targetAltitude = min(maxAltitude, max(baseAltitude, dist * 1.5)) // Raised multiplier slightly for visual transfer
                
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
    
    @Environment(\.dismiss) private var dismiss
    @State private var engine = PlaybackEngine()
    @State private var waypoints: [Waypoint] = []
    @State private var mapStyleManager = MapStyleManager.shared
    @State private var isShowingLayerPicker = false
    
    @State private var filteredPhotos: [PhotoAsset] = []
    
    // Filtering State
    @State private var isShowingFilter = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var endDate = Date()
    @State private var filterBounceTrigger = 0
    
    // Annotation interaction state
    @State private var selectedAnnotation: SelectedAnnotationInfo?
    @State private var thumbnailLoader = ThumbnailLoader()
    @State private var isShowingGallery = false
    @State private var galleryPhotoIDs: [String] = []
    @State private var fullScreenPhotoID: String?
    @State private var fullScreenPhotoIDs: [String] = []
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Map Layer — dual engine: Apple MapKit or Mapbox
            if mapStyleManager.currentStyle.isApple {
                PhotoClusterMapView(
                    photos: filteredPhotos,
                    waypoints: waypoints,
                    playbackProgress: engine.progress,
                    playbackDuration: engine.duration,
                    isPlaying: engine.isPlaying,
                    isPreparing: engine.isPreparing,
                    mapType: mapStyleManager.currentStyle == .appleSatellite ? .satellite : .standard,
                    onAnnotationSelected: { ids, point in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            selectedAnnotation = SelectedAnnotationInfo(photoIDs: ids, screenPoint: point)
                        }
                        thumbnailLoader.loadThumbnails(for: ids)
                    }
                )
                .ignoresSafeArea(edges: [.bottom, .horizontal])
            } else if let styleURI = mapStyleManager.currentStyle.mapboxStyleURI {
                MapboxMapWrapperView(
                    photos: filteredPhotos,
                    waypoints: waypoints,
                    styleURI: styleURI,
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
            }
            

            
            // Fan thumbnail overlay
            if let selected = selectedAnnotation {
                FanThumbnailOverlay(
                    photoIDs: selected.photoIDs,
                    screenPoint: selected.screenPoint,
                    thumbnailLoader: thumbnailLoader,
                    onPhotoTap: { id in
                        fullScreenPhotoIDs = selected.photoIDs
                        fullScreenPhotoID = id
                        thumbnailLoader.loadThumbnails(for: selected.photoIDs, size: CGSize(width: 800, height: 800))
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
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            customNavigationBar
        }
        .sheet(isPresented: $isShowingFilter) {
            filterSheet
        }
        .sheet(isPresented: $isShowingLayerPicker) {
            MapLayerPickerSheet(styleManager: mapStyleManager)
                .presentationDetents([.fraction(0.75)])
        }
        .onAppear {
            let sortedParams = photos.sorted(by: { $0.creationDate < $1.creationDate })
            
            // Set default date range to Dec 27, 2023 - Jan 1, 2024
            var componentsStart = DateComponents()
            componentsStart.year = 2023
            componentsStart.month = 12
            componentsStart.day = 27
            componentsStart.hour = 0
            componentsStart.minute = 0
            
            var componentsEnd = DateComponents()
            componentsEnd.year = 2024
            componentsEnd.month = 1
            componentsEnd.day = 1
            componentsEnd.hour = 23
            componentsEnd.minute = 59
            
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
                FullScreenPhotoView(photoIDs: fullScreenPhotoIDs, initialPhotoID: id, thumbnailLoader: thumbnailLoader)
            }
        }
    }
    
    private func applyFilter() {
        engine.stop()
        // Normalize: startDate to 00:00, endDate to 23:59
        let cal = Calendar.current
        let normalizedStart = cal.startOfDay(for: startDate)
        let normalizedEnd = cal.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) ?? endDate
        
        let sorted = photos.sorted(by: { $0.creationDate < $1.creationDate })
        filteredPhotos = sorted.filter {
            $0.creationDate >= normalizedStart && $0.creationDate <= normalizedEnd
        }
        recluster()
    }
    
    private func recluster() {
        let rawWaypoints = PhotoClusterer.clusterPhotos(filteredPhotos)
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
        engine.calculateDynamicDuration(for: unique)
    }
    
    private var timeCapsuleDateText: String {
        let fmtDay = DateFormatter()
        fmtDay.dateFormat = "yy.MM.dd"
        return "\(fmtDay.string(from: startDate)) ―― \(fmtDay.string(from: endDate))"
    }
    
    // Filter UI Sheet
    @ViewBuilder
    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("选择播放的时间段")) {
                    DatePicker("开始日期", selection: $startDate, displayedComponents: [.date])
                    DatePicker("结束日期", selection: $endDate, displayedComponents: [.date])
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
    
    // Custom Navigation Bar to allow seamless fade transitions
    @ViewBuilder
    private var customNavigationBar: some View {
        HStack {
            // Back Button
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
            }
            
            Spacer()
            
            // Title removed for minimalist look
            
            Spacer()
            
            // Right Actions
            HStack(spacing: 8) {
                Button(action: {
                    isShowingLayerPicker = true
                }) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                }
                .frame(width: 44, height: 44)
                
                Button(action: {
                    filterBounceTrigger += 1
                    isShowingFilter.toggle()
                }) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                        .symbolEffect(.bounce, value: filterBounceTrigger)
                }
                .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(
            Color(UIColor.systemBackground)
                .opacity(0.8)
                .blur(radius: 10)
                .ignoresSafeArea(edges: .top)
        )
        .opacity(engine.isPlaying || engine.isPreparing ? 0 : 1)
        .animation(.easeInOut(duration: 0.35), value: engine.isPlaying || engine.isPreparing)
        .allowsHitTesting(!(engine.isPlaying || engine.isPreparing))
    }
    
    private var startDateText: String {
        let fmtDay = DateFormatter()
        fmtDay.dateFormat = "yy.MM.dd"
        return fmtDay.string(from: startDate)
    }
    
    private var endDateText: String {
        let fmtDay = DateFormatter()
        fmtDay.dateFormat = "yy.MM.dd"
        return fmtDay.string(from: endDate)
    }
    
    // Playback UI Panel
    @ViewBuilder
    private var playbackControls: some View {
        // Redesigned UI: The Time Capsule
        HStack(spacing: 16) {
            // Left: Micro-Timeline
            VStack(spacing: 4) {
                // Progress Bar Zone
                ZStack(alignment: .leading) {
                    // Touch Capture
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if selectedAnnotation != nil {
                                            withAnimation(.spring()) { selectedAnnotation = nil }
                                        }
                                        let percentage = min(max(value.location.x / geo.size.width, 0.0), 1.0)
                                        engine.seek(to: Double(percentage))
                                    }
                            )
                    }
                    
                    // Visual Bar
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.gray.opacity(0.15))
                            .frame(height: 2)
                        
                        Capsule()
                            .fill(Color.orange.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .mask(
                                GeometryReader { geo in
                                    Rectangle()
                                        .frame(width: geo.size.width * CGFloat(engine.progress))
                                }
                            )
                            .shadow(color: .orange.opacity(0.4), radius: 2, x: 0, y: 0)
                    }
                    .frame(height: 12)
                }
                .frame(height: 12) // Fix height for progress bar zone
                
                // Dates
                HStack {
                    Text(startDateText)
                    Spacer()
                    Text(endDateText)
                }
                .font(.system(size: 10, weight: .light, design: .monospaced))
                .foregroundColor(.primary.opacity(0.5))
                .tracking(1.0)
            }
            .frame(height: 32)
            .padding(.leading, 8)
            
            // Right Control Cluster
            HStack(spacing: 12) {
                // Secondary Button: Stop (Minimalist)
                if !waypoints.isEmpty && (engine.isPlaying || engine.progress > 0) {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.spring()) {
                            selectedAnnotation = nil
                            engine.stop()
                        }
                    }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary.opacity(0.8))
                            .frame(width: 32, height: 32)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
                
                // Primary Button: Play/Pause (Minimalist)
                Button(action: {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    withAnimation(.interpolatingSpring(stiffness: 120, damping: 12)) {
                        selectedAnnotation = nil
                        engine.togglePlayPause()
                    }
                }) {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.orange)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                }
                .disabled(waypoints.isEmpty)
                .opacity(waypoints.isEmpty ? 0.3 : 1.0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: engine.isPlaying || engine.isPreparing)
    }
}

// MARK: - Custom Annotation View

class WaypointAnnotationView: MKAnnotationView {
    private let countLabel = UILabel()
    private let bubbleView = UIView()
    
    override var annotation: MKAnnotation? {
        didSet {
            guard let wpAnn = annotation as? WaypointAnnotation else { return }
            countLabel.text = "\(wpAnn.count)"
            updateLayout(for: wpAnn.count)
        }
    }
    
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupView()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupView()
    }
    
    private func setupView() {
        backgroundColor = .clear
        
        // Solid Orange Dot
        bubbleView.backgroundColor = UIColor(red: 0.92, green: 0.43, blue: 0.12, alpha: 1.0) // Similar to #EB6E1F, solid orange
        bubbleView.clipsToBounds = true
        bubbleView.layer.borderColor = UIColor.white.cgColor
        bubbleView.layer.borderWidth = 2.0
        
        // Count label
        countLabel.textColor = .white
        countLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        countLabel.textAlignment = .center
        
        addSubview(bubbleView)
        bubbleView.addSubview(countLabel)
        
        self.collisionMode = .circle
        self.layer.shadowOpacity = 0 // Explicitly no shadow to keep it ultra minimalistic
    }
    
    private func updateLayout(for count: Int) {
        let text = "\(count)"
        let horizontalPadding: CGFloat = text.count > 2 ? 8 : 4
        let bubbleHeight: CGFloat = 28
        let minBubbleWidth: CGFloat = 28
        
        // Calculate width based on text
        let textSize = (text as NSString).size(withAttributes: [.font: countLabel.font!])
        let bubbleWidth = max(minBubbleWidth, textSize.width + horizontalPadding * 2)
        
        self.frame = CGRect(x: 0, y: 0, width: bubbleWidth, height: bubbleHeight)
        
        // Bubble
        bubbleView.frame = self.bounds
        bubbleView.layer.cornerRadius = bubbleHeight / 2
        
        // Label
        countLabel.frame = self.bounds
        
        // Center offset so the very center of the dot is at the exact coordinate
        self.centerOffset = .zero
    }
}

// MARK: - Map Layer Picker Sheet

struct MapLayerPickerSheet: View {
    @Bindable var styleManager: MapStyleManager
    @Environment(\.dismiss) private var dismiss
    
    let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    
    var allStyles: [MapStyleOption] {
        MapStyleOption.appleStyles + MapStyleOption.mapboxStyles
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(allStyles) { style in
                        BentoLayerCard(style: style, isSelected: styleManager.currentStyle == style) {
                            styleManager.currentStyle = style
                            // Add a tiny delay so the user feels the selection feedback
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                dismiss()
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("地图风格")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(UIColor.systemGroupedBackground))
        }
    }
}

// MARK: - Bento Grid Components

struct BentoLayerCard: View {
    let style: MapStyleOption
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Style Sample (Visual representation from Assets)
                ZStack {
                    StyleBackgroundView(style: style)
                    
                    if isSelected {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(6)
                    }
                }
                .frame(height: 84)
                .clipped()
                
                // Footer (Text only)
                Text(style.displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 2)
            )
            .shadow(color: Color.black.opacity(isSelected ? 0.08 : 0.04), radius: isSelected ? 8 : 4, x: 0, y: isSelected ? 4 : 2)
            .scaleEffect(isSelected ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

struct StyleBackgroundView: View {
    let style: MapStyleOption
    
    var body: some View {
        GeometryReader { geo in
            Image(style.rawValue)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                // Placeholder background while assets are missing
                .background(Color(UIColor.systemGray5))
        }
    }
}

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
    let isStayPoint: Bool
    
    static func == (lhs: Waypoint, rhs: Waypoint) -> Bool {
        lhs.id == rhs.id
    }
}

class WaypointAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    var id: String
    var count: Int
    var photoIDs: [String]
    var waypointIndex: Int
    
    init(waypoint: Waypoint, index: Int, isGCJ02Required: Bool = false) {
        if isGCJ02Required {
            self.coordinate = CoordinateConverter.transformFromWGSToGCJ(coordinate: waypoint.coordinate)
        } else {
            self.coordinate = waypoint.coordinate
        }
        self.id = waypoint.id.uuidString
        self.count = waypoint.photoCount
        self.photoIDs = waypoint.photoIDs
        self.waypointIndex = index
        super.init()
    }
}

// REMOVED: PlaybackEngine and DisplayLinkProxy are now provided by PlaybackController.swift

// MARK: - Smooth Spline Generation

struct SplineRouteBuilder {
    static func buildSmoothSpline(waypoints: [Waypoint], isGCJ02Required: Bool = false) -> [CLLocationCoordinate2D] {
        // 1. Deduplicate waypoints that are effectively identical to prevent division by zero (infinite tangents)
        var uniqueWaypoints: [Waypoint] = []
        for wp in waypoints {
            let wpCoord = isGCJ02Required ? CoordinateConverter.transformFromWGSToGCJ(coordinate: wp.coordinate) : wp.coordinate
            if let last = uniqueWaypoints.last {
                let lastCoord = isGCJ02Required ? CoordinateConverter.transformFromWGSToGCJ(coordinate: last.coordinate) : last.coordinate
                let dist = CLLocation(latitude: wpCoord.latitude, longitude: wpCoord.longitude)
                    .distance(from: CLLocation(latitude: lastCoord.latitude, longitude: lastCoord.longitude))
                if dist > 100.0 {
                    uniqueWaypoints.append(wp)
                }
            } else {
                uniqueWaypoints.append(wp)
            }
        }
        
        guard uniqueWaypoints.count > 1 else {
            return uniqueWaypoints.map { isGCJ02Required ? CoordinateConverter.transformFromWGSToGCJ(coordinate: $0.coordinate) : $0.coordinate }
        }
        
        // Convert to MKMapPoint for perfect Cartesian 2D interpolation, avoiding spherical distortion
        let mapPoints = uniqueWaypoints.map { MKMapPoint(isGCJ02Required ? CoordinateConverter.transformFromWGSToGCJ(coordinate: $0.coordinate) : $0.coordinate) }
        
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
        let steps = 20 // Points per spline segment for high-resolution curves
        
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
    
    func updatePath(for splineCoords: [CLLocationCoordinate2D], in mapView: MKMapView, progressIndex: Double, isPlaying: Bool, isPreparing: Bool) {
        // Respect current progress even when not playing (paused state).
        // Total path will naturally show when progressIndex reaches the end.
        let effectiveProgress = progressIndex
        
        guard splineCoords.count > 1 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shapeLayer.path = nil
            CATransaction.commit()
            return
        }
        
        // If progress is 0, we still want to clear the path if it was previously drawn
        if effectiveProgress <= 0 {
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
        
        let maxIndex = min(splineCoords.count - 1, Int(ceil(effectiveProgress)))
        if maxIndex > 0 {
            for i in 1...maxIndex {
                if i == maxIndex {
                    // Precise interpolation of the tip of the line
                    let prev = splineCoords[i - 1]
                    let curr = splineCoords[i]
                    let remainder = effectiveProgress - Double(i - 1)
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
        // Optimization: Input photos are already sorted by PhotoManager
        let sorted = photos 
        
        // Pass 1: Coarse split by large gaps (> 4 hours OR > 10 km)
        var coarseChunks: [[PhotoAsset]] = []
        var currentChunk: [PhotoAsset] = [sorted[0]]
        
        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let curr = sorted[i]
            
            let timeDelta = curr.creationDate.timeIntervalSince(prev.creationDate)
            
            // Faster distance check using raw coordinates (Manhattan distance / quick box check) before heavy CLLocation
            let latDelta = abs(curr.location.latitude - prev.location.latitude)
            let lonDelta = abs(curr.location.longitude - prev.location.longitude)
            
            if timeDelta > 3600 * 4 || latDelta > 0.1 || lonDelta > 0.1 { // ~10km at equator for 0.1 degree
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
        
        for (index, chunk) in coarseChunks.enumerated() {
            let isFirstOrLast = index == 0 || index == coarseChunks.count - 1
            if chunk.count <= 10 {
                // Sparse chunk
                finalWaypoints.append(createWaypoint(from: chunk, isMandatoryStop: isFirstOrLast))
            } else {
                // Dense chunk (e.g. amusement park), apply fine-grained splitting
                var fineChunk: [PhotoAsset] = [chunk[0]]
                for i in 1..<chunk.count {
                    let prev = chunk[i - 1]
                    let curr = chunk[i]
                    
                    let timeDelta = curr.creationDate.timeIntervalSince(prev.creationDate)
                    
                    // Faster distance check using raw coordinates
                    let latDelta = abs(curr.location.latitude - prev.location.latitude)
                    let lonDelta = abs(curr.location.longitude - prev.location.longitude)
                    
                    // Fine threshold: 5 minutes OR 50 meters (~0.0005 degree at equator for 50m)
                    if timeDelta > 300 || latDelta > 0.0005 || lonDelta > 0.0005 {
                        finalWaypoints.append(createWaypoint(from: fineChunk, isMandatoryStop: false))
                        fineChunk = [curr]
                    } else {
                        fineChunk.append(curr)
                    }
                }
                if !fineChunk.isEmpty {
                    finalWaypoints.append(createWaypoint(from: fineChunk, isMandatoryStop: isFirstOrLast))
                }
            }
        }
        
        return finalWaypoints
    }
    
    private static func createWaypoint(from photos: [PhotoAsset], isMandatoryStop: Bool) -> Waypoint {
        let avgLat = photos.map { $0.location.latitude }.reduce(0, +) / Double(photos.count)
        let avgLon = photos.map { $0.location.longitude }.reduce(0, +) / Double(photos.count)
        
        let startDate = photos.first!.creationDate
        let endDate = photos.last!.creationDate
        let duration = endDate.timeIntervalSince(startDate)
        
        // All waypoints are shown as icons on the map.
        // The isStayPoint flag is kept for potential future use.
        let isStayPoint = true
        
        return Waypoint(
            coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
            photoCount: photos.count,
            photoIDs: photos.map { $0.id },
            dateRange: (startDate, endDate),
            isStayPoint: isStayPoint
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
    var isGCJ02Required: Bool = false
    var onAnnotationSelected: ((_ photoIDs: [String], _ screenPoint: CGPoint) -> Void)?
    var onWaypointLitUp: ((_ waypointIndex: Int) -> Void)?
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var lastWaypoints: [Waypoint] = []
        var lastSplineCoords: [CLLocationCoordinate2D] = []
        var waypointSplineIndices: [Int] = []  // Maps each waypoint index to its closest spline index
        var lastOverviewRect: MKMapRect?
        var lastProgress: Double = -1.0
        var lastIsPreparing: Bool = false
        var currentAltitude: CLLocationDistance?
        var initialCamera: MKMapCamera?
        let splineManager = SplineLayerManager()
        var onAnnotationSelected: ((_ photoIDs: [String], _ screenPoint: CGPoint) -> Void)?
        var onWaypointLitUp: ((_ waypointIndex: Int) -> Void)?
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
                splineManager.updatePath(for: lastSplineCoords, in: mapView, progressIndex: targetIdxFloat, isPlaying: isPlayingOrPreparing, isPreparing: isPlayingOrPreparing)
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
        
        // Attach hardware accelerated line layer above the map's tiles
        context.coordinator.splineManager.shapeLayer.zPosition = 1000
        mapView.layer.addSublayer(context.coordinator.splineManager.shapeLayer)
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.isPlayingOrPreparing = isPlaying || isPreparing
        context.coordinator.onAnnotationSelected = onAnnotationSelected
        context.coordinator.onWaypointLitUp = onWaypointLitUp
        
        if uiView.mapType != mapType {
            uiView.mapType = mapType
        }
        
        let splineCoords: [CLLocationCoordinate2D]
        
        // 1. Update Annotations, Overlays & Overview Bounds
        if context.coordinator.lastWaypoints != waypoints {
            context.coordinator.lastWaypoints = waypoints
            splineCoords = SplineRouteBuilder.buildSmoothSpline(waypoints: waypoints, isGCJ02Required: isGCJ02Required)
            context.coordinator.lastSplineCoords = splineCoords
            
            // Precompute: map each waypoint to its closest spline index
            context.coordinator.waypointSplineIndices = waypoints.map { wp in
                let wpCoord = isGCJ02Required ? CoordinateConverter.transformFromWGSToGCJ(coordinate: wp.coordinate) : wp.coordinate
                var bestIdx = 0
                var bestDist = Double.greatestFiniteMagnitude
                for (i, sc) in splineCoords.enumerated() {
                    let d = pow(sc.latitude - wpCoord.latitude, 2) + pow(sc.longitude - wpCoord.longitude, 2)
                    if d < bestDist { bestDist = d; bestIdx = i }
                }
                return bestIdx
            }
            
            // Rebuild Annotations
            uiView.removeAnnotations(uiView.annotations)
            let newAnnotations = waypoints.enumerated().map { WaypointAnnotation(waypoint: $1, index: $0, isGCJ02Required: isGCJ02Required) }
            uiView.addAnnotations(newAnnotations)
            
            // Rebuild Overlays
            let startIdxFloat = playbackProgress * Double(max(0, splineCoords.count - 1))
            context.coordinator.splineManager.updatePath(for: splineCoords, in: uiView, progressIndex: startIdxFloat, isPlaying: isPlaying, isPreparing: isPreparing)
            
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
        context.coordinator.splineManager.updatePath(for: splineCoords, in: uiView, progressIndex: targetIdxFloat, isPlaying: isPlaying, isPreparing: isPreparing)
        
        // 2.5 Update waypoint passed/unpassed visual state based on spline position
        let splineIndices = context.coordinator.waypointSplineIndices
        for annotation in uiView.annotations {
            guard let wpAnn = annotation as? WaypointAnnotation,
                  let view = uiView.view(for: wpAnn) as? WaypointAnnotationView else { continue }
            let wpIdx = wpAnn.waypointIndex
            if wpIdx < splineIndices.count {
                let wpSplineIdx = Double(splineIndices[wpIdx])
                let isPassed = playbackProgress > 0 && targetIdxFloat >= wpSplineIdx
                
                // Notify on hollow -> filled transition
                let wasPassed = view.currentIsPassed ?? false
                if isPassed && !wasPassed {
                    context.coordinator.onWaypointLitUp?(wpIdx)
                }
                
                // Set zPriority to keep annotations above the line
                view.zPriority = .max
                view.updatePassedState(isPassed)
            }
        }
        
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
    var initialStartDate: Date? = nil
    var initialEndDate: Date? = nil
    
    @Environment(PhotoManager.self) private var photoManager
    @Environment(\.dismiss) private var dismiss
    @State private var playbackController = PlaybackController()
    @State private var waypoints: [Waypoint] = []
    @State private var mapStyleManager = MapStyleManager.shared
    @State private var isShowingLayerPicker = false
    
    @State private var filteredPhotos: [PhotoAsset] = []
    
    // Filtering State
    @State private var isShowingFilter = false
    @State private var startDate = Date.distantPast
    @State private var endDate = Date.distantFuture
    @State private var filterBounceTrigger = 0
    
    // Focused date for calendar linkage
    enum FocusedDateField { case start, end }
    @State private var focusedDate: FocusedDateField = .start
    
    // Annotation interaction state
    @State private var selectedAnnotation: SelectedAnnotationInfo?
    @State private var thumbnailLoader = ThumbnailLoader()
    @State private var isShowingGallery = false
    @State private var galleryPhotoIDs: [String] = []
    @State private var fullScreenPhotoID: String?
    @State private var fullScreenPhotoIDs: [String] = []
    
    // Smart Collections Bento View
    @State private var isShowingSmartCollections = false
    
    // Montage interaction
    @State private var showMontageControls = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Map Layer — dual engine: Apple MapKit or Mapbox
            if mapStyleManager.currentStyle.isApple {
                PhotoClusterMapView(
                    photos: filteredPhotos,
                    waypoints: waypoints,
                    playbackProgress: playbackController.progress,
                    playbackDuration: playbackController.duration,
                    isPlaying: playbackController.isPlaying,
                    isPreparing: playbackController.isPreparing,
                    mapType: mapStyleManager.currentStyle == .appleSatellite ? .satellite : .standard,
                    isGCJ02Required: mapStyleManager.currentStyle.isGCJ02Required,
                    onAnnotationSelected: { ids, point in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            selectedAnnotation = SelectedAnnotationInfo(photoIDs: ids, screenPoint: point)
                        }
                        thumbnailLoader.loadThumbnails(for: ids)
                    },
                    onWaypointLitUp: { wpIndex in
                        playbackController.showFlashbackForWaypoint(index: wpIndex)
                    }
                )
                .ignoresSafeArea(edges: [.bottom, .horizontal])
            } else if let styleURI = mapStyleManager.currentStyle.mapboxStyleURI {
                MapboxMapWrapperView(
                    photos: filteredPhotos,
                    waypoints: waypoints,
                    styleURI: styleURI,
                    playbackProgress: playbackController.progress,
                    playbackDuration: playbackController.duration,
                    isPlaying: playbackController.isPlaying,
                    isPreparing: playbackController.isPreparing,
                    onAnnotationSelected: { ids, point in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            selectedAnnotation = SelectedAnnotationInfo(photoIDs: ids, screenPoint: point)
                        }
                        thumbnailLoader.loadThumbnails(for: ids)
                    },
                    onWaypointLitUp: { wpIndex in
                        playbackController.showFlashbackForWaypoint(index: wpIndex)
                    }
                )
                .ignoresSafeArea(edges: [.bottom, .horizontal])
            }
            
            playbackControls
                .opacity(selectedAnnotation != nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: selectedAnnotation != nil)
            
            flashbackOverlay
            montageOverlay
            
            // Hybrid Selection UI: Fan for small groups, Scrollable Tray for large ones
            if let selected = selectedAnnotation {
                if selected.photoIDs.count <= 3 {
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
                            isShowingGallery = true
                            selectedAnnotation = nil
                        },
                        onDismiss: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedAnnotation = nil
                            }
                        }
                    )
                } else {
                    ClusterQuickGallery(
                        photoIDs: selected.photoIDs,
                        thumbnailLoader: thumbnailLoader,
                        onPhotoTap: { id in
                            fullScreenPhotoIDs = selected.photoIDs
                            fullScreenPhotoID = id
                            thumbnailLoader.loadThumbnails(for: selected.photoIDs, size: CGSize(width: 800, height: 800))
                        },
                        onShowFullGallery: {
                            galleryPhotoIDs = selected.photoIDs
                            isShowingGallery = true
                            selectedAnnotation = nil
                        },
                        onDismiss: {
                            withAnimation(.spring()) {
                                selectedAnnotation = nil
                            }
                        }
                    )
                    .background(
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation { selectedAnnotation = nil }
                            }
                    )
                }
            }
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
            // Reset to global photo range IF this is the first time entering (sentinel values detected)
            if startDate == Date.distantPast || endDate == Date.distantFuture {
                if let first = initialStartDate, let last = initialEndDate {
                    startDate = first
                    endDate = last
                } else if let first = photos.first?.creationDate, let last = photos.last?.creationDate {
                    // Fallback using the sorted property of our photos array
                    startDate = first
                    endDate = last
                }
            }
            
            applyFilter()
        }
        .onDisappear {
            playbackController.stop()
        }
        .onChange(of: playbackController.isPlaying) { _, isPlaying in
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
        .sheet(isPresented: $isShowingSmartCollections) {
            SmartCollectionsGalleryView(onSelect: { collection in
                withAnimation {
                    self.startDate = collection.startDate
                    self.endDate = collection.endDate
                    applyFilter()
                }
            })
            .environment(photoManager)
        }
    }
    
    @ViewBuilder
    private var flashbackOverlay: some View {
        if let asset = playbackController.currentFlashbackAsset, playbackController.state == .playing {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    if let image = thumbnailLoader.thumbnails[asset.id] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height * 0.40)
                            .clipped()
                            .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
                            .padding(.top, geo.safeAreaInsets.top + 44) // Below nav bar
                    } else {
                        Color.black.opacity(0.1)
                            .frame(width: geo.size.width, height: geo.size.height * 0.40)
                            .overlay(ProgressView())
                            .padding(.top, geo.safeAreaInsets.top + 44)
                            .onAppear {
                                thumbnailLoader.loadThumbnails(for: [asset.id], size: CGSize(width: 1200, height: 1200))
                            }
                    }
                    Spacer()
                }
            }
            .ignoresSafeArea()
            .id(asset.id)
            .allowsHitTesting(false)
        }
    }
    
    @ViewBuilder
    private var montageOverlay: some View {
        if playbackController.state == .montage || (playbackController.state == .finished && playbackController.currentMontageAsset != nil) {
            ZStack {
                Color.black.ignoresSafeArea()
                    .transition(.opacity.animation(.easeInOut(duration: 0.6)))
                               if let asset = playbackController.currentMontageAsset {
                    if let image = thumbnailLoader.thumbnails[asset.id] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .ignoresSafeArea()
                            // Removed .id(asset.id) and .transition to ensure instant photo swaps
                    } else {
                        ProgressView()
                            .tint(.white)
                            .onAppear {
                                thumbnailLoader.loadThumbnails(for: [asset.id], size: CGSize(width: 1200, height: 1200))
                            }
                    }
                }
                
                // Tap to show/hide controls (During montage OR when finished)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showMontageControls.toggle()
                        }
                    }
                
                // Active Montage Controls (Progress bar shown only during playback)
                if showMontageControls && playbackController.state == .montage {
                    VStack(spacing: 16) {
                        Spacer()
                        
                        // Draggable progress bar
                        GeometryReader { barGeo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.white.opacity(0.2))
                                    .frame(height: 3)
                                
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.orange)
                                    .frame(width: barGeo.size.width * CGFloat(playbackController.montageProgress), height: 3)
                            }
                            .frame(height: 24)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let ratio = min(max(value.location.x / barGeo.size.width, 0.0), 1.0)
                                        playbackController.seekMontage(to: Double(ratio))
                                    }
                            )
                        }
                        .frame(height: 24)
                        .padding(.horizontal, 32)
                        
                        HStack(spacing: 24) {
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring()) {
                                    showMontageControls = false
                                    playbackController.exitMontage()
                                }
                            }) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white.opacity(0.85))
                                    .frame(width: 54, height: 54)
                                    .background(Circle().fill(.ultraThinMaterial))
                            }
                            
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                if playbackController.isMontagePaused {
                                    playbackController.resumeMontage()
                                } else {
                                    playbackController.pause()
                                }
                            }) {
                                Image(systemName: playbackController.isMontagePaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.orange)
                                    .frame(width: 54, height: 54)
                                    .background(Circle().fill(.ultraThinMaterial))
                            }
                        }
                        .padding(.bottom, 80)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .environment(\.colorScheme, .dark)
                }
                
                // Final Screen Buttons (Swapped: Exit on left, Replay on right)
                if showMontageControls && playbackController.state == .finished && playbackController.currentMontageAsset != nil {
                    VStack {
                        Spacer()
                        HStack(spacing: 56) {
                            // Exit (Left)
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring()) {
                                    playbackController.stop()
                                }
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.white.opacity(0.85))
                                    .frame(width: 64, height: 64)
                                    .background(ZStack { Circle().fill(Color.white.opacity(0.08)); Circle().fill(.ultraThinMaterial) })
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
                            }
                            
                            // Replay (Right)
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) {
                                    playbackController.replayMontage()
                                }
                            }) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.orange)
                                    .frame(width: 64, height: 64)
                                    .background(ZStack { Circle().fill(Color.white.opacity(0.1)); Circle().fill(.ultraThinMaterial) })
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.1), radius: 15, x: 0, y: 8)
                            }
                        }
                        .padding(.bottom, 120)
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)).animation(.easeInOut(duration: 1.2)),
                        removal: .opacity
                    ))
                }
            }
            .gesture(
                DragGesture()
                    .onEnded { value in
                        guard playbackController.state == .finished else { return }
                        if value.translation.width > 50 {
                            // Swipe Right -> Previous
                            withAnimation(.easeInOut) {
                                playbackController.setMontageIndex(playbackController.currentMontageIndex - 1)
                            }
                        } else if value.translation.width < -50 {
                            // Swipe Left -> Next
                            withAnimation(.easeInOut) {
                                playbackController.setMontageIndex(playbackController.currentMontageIndex + 1)
                            }
                        }
                    }
            )
            .zIndex(100)
            .transition(.opacity.animation(.easeInOut(duration: 1.2)))
        }
    }
    
    private func applyFilter() {
        playbackController.stop()
        let cal = Calendar.current
        
        // Start of the selected start day (00:00:00)
        let normalizedStart = cal.startOfDay(for: startDate)
        
        // Start of the day AFTER the selected end day (to cover the full end day)
        let nextDay = cal.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        let normalizedEndLimit = cal.startOfDay(for: nextDay)
        
        // Filter (Photos are already sorted, so keep the order)
        filteredPhotos = photos.filter { photo in
            let dateInRange = photo.creationDate >= normalizedStart && photo.creationDate < normalizedEndLimit
            
            if photoManager.hideStationary, let home = photoManager.stationaryPoint {
                // Skip photos within ~5km (0.05 degrees)
                let dist = pow(photo.location.latitude - home.latitude, 2) + pow(photo.location.longitude - home.longitude, 2)
                if dist < 0.0025 { // 0.05^2
                    return false
                }
            }
            
            return dateInRange
        }
        
        recluster()
    }
    
    private func recluster() {
        // Use the raw waypoints from the clusterer
        let rawWaypoints = PhotoClusterer.clusterPhotos(filteredPhotos)
        
        // Pass 2: Merge extremely close waypoints (e.g., within 20m) to avoid overlapping icons
        // but IMPORTANTLY: merge the data (photo counts and IDs) instead of discarding it.
        var merged: [Waypoint] = []
        for wp in rawWaypoints {
            if let last = merged.last {
                // Quick approx distance check: 20m is ~0.0002 degrees locally
                let latDelta = abs(wp.coordinate.latitude - last.coordinate.latitude)
                let lonDelta = abs(wp.coordinate.longitude - last.coordinate.longitude)
                
                if latDelta < 0.0002 && lonDelta < 0.0002 {
                    // Update the last merging point instead of adding a new one
                    let totalPhotos = last.photoCount + wp.photoCount
                    let combinedIDs = last.photoIDs + wp.photoIDs
                    let combinedDateRange = (min(last.dateRange.start, wp.dateRange.start), max(last.dateRange.end, wp.dateRange.end))
                    
                    // Simple weighted average for the coordinate to represent the cluster center
                    let lat = (last.coordinate.latitude * Double(last.photoCount) + wp.coordinate.latitude * Double(wp.photoCount)) / Double(totalPhotos)
                    let lon = (last.coordinate.longitude * Double(last.photoCount) + wp.coordinate.longitude * Double(wp.photoCount)) / Double(totalPhotos)
                    
                    let isMergedStayPoint = last.isStayPoint || wp.isStayPoint
                    
                    let mergedWP = Waypoint(
                        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        photoCount: totalPhotos,
                        photoIDs: combinedIDs,
                        dateRange: combinedDateRange,
                        isStayPoint: isMergedStayPoint
                    )
                    merged[merged.count - 1] = mergedWP
                    continue
                }
            }
            merged.append(wp)
        }
        
        waypoints = merged
        playbackController.setup(waypoints: merged, photos: photos)
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
                Section {
                    PhotoTemporalHeatmap(
                        photos: photos,
                        startDate: $startDate,
                        endDate: $endDate
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    
                    Toggle("隐藏常驻地点 (家/办公)", isOn: Bindable(photoManager).hideStationary)
                        .font(.system(size: 15, weight: .medium))
                        .tint(.orange)
                        .onChange(of: photoManager.hideStationary) { _ in
                            applyFilter()
                        }
                }
                
                Section(header: Text("选择播放的时间段")) {
                    DatePicker("开始日期", selection: $startDate, in: ...endDate, displayedComponents: [.date])
                        .listRowSeparator(.hidden)
                    DatePicker("结束日期", selection: $endDate, in: startDate..., displayedComponents: [.date])
                        .listRowSeparator(.hidden)
                }
                .listRowSeparator(.hidden)
                
                Section {
                    Button(action: {
                        applyFilter()
                        isShowingFilter = false
                    }) {
                        Text("应用筛选并重置播放")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                    }
                    .listRowSeparator(.hidden)
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
        .presentationDetents([.fraction(0.7), .large])
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
            HStack(spacing: 12) {
                // New: Smart Collections Gallery Entry
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    isShowingSmartCollections = true
                }) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                }
                .frame(width: 44, height: 44)
                
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
            .padding(.trailing, 60) // Extra padding to avoid Mapbox compass
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .opacity(playbackController.isPlaying || playbackController.isPreparing ? 0 : 1)
        .animation(.easeInOut(duration: 0.35), value: playbackController.isPlaying || playbackController.isPreparing)
        .allowsHitTesting(!(playbackController.isPlaying || playbackController.isPreparing))
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
                                        playbackController.seek(to: Double(percentage))
                                    }
                            )
                    }
                    
                    // Visual Bar
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 1.0)
                        
                        Rectangle()
                            .fill(Color.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .mask(
                                GeometryReader { geo in
                                    Rectangle()
                                        .frame(width: geo.size.width * CGFloat(playbackController.progress))
                                }
                            )
                            .frame(height: 1.0)
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
                if !waypoints.isEmpty && (playbackController.isPlaying || playbackController.progress > 0) {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.spring()) {
                            selectedAnnotation = nil
                            playbackController.stop()
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
                        playbackController.togglePlayPause()
                    }
                }) {
                    Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
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
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: playbackController.isPlaying || playbackController.isPreparing)
    }
}

// MARK: - Custom Annotation View

class WaypointAnnotationView: MKAnnotationView {
    private let countLabel = UILabel()
    private let bubbleView = UIView()
    private let orangeColor = UIColor(red: 0.92, green: 0.43, blue: 0.12, alpha: 1.0)
    private(set) var currentIsPassed: Bool?
    
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
        
        // Default: hollow (unpassed) style
        bubbleView.backgroundColor = .white
        bubbleView.clipsToBounds = true
        bubbleView.layer.borderColor = orangeColor.cgColor
        bubbleView.layer.borderWidth = 2.0
        
        countLabel.textColor = orangeColor
        countLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        countLabel.textAlignment = .center
        
        addSubview(bubbleView)
        bubbleView.addSubview(countLabel)
        
        self.collisionMode = .circle
        self.layer.shadowOpacity = 0
    }
    
    func updatePassedState(_ isPassed: Bool) {
        guard currentIsPassed != isPassed else { return }
        currentIsPassed = isPassed
        
        UIView.animate(withDuration: 0.3) {
            if isPassed {
                // Filled: orange background, white text
                self.bubbleView.backgroundColor = self.orangeColor
                self.bubbleView.layer.borderColor = UIColor.white.cgColor
                self.countLabel.textColor = .white
            } else {
                // Hollow: white background, orange border, orange text
                self.bubbleView.backgroundColor = .white
                self.bubbleView.layer.borderColor = self.orangeColor.cgColor
                self.countLabel.textColor = self.orangeColor
            }
        }
    }
    
    private func updateLayout(for count: Int) {
        let text = "\(count)"
        let horizontalPadding: CGFloat = text.count > 2 ? 8 : 4
        let bubbleHeight: CGFloat = 28
        let minBubbleWidth: CGFloat = 28
        
        let textSize = (text as NSString).size(withAttributes: [.font: countLabel.font!])
        let bubbleWidth = max(minBubbleWidth, textSize.width + horizontalPadding * 2)
        
        self.frame = CGRect(x: 0, y: 0, width: bubbleWidth, height: bubbleHeight)
        bubbleView.frame = self.bounds
        bubbleView.layer.cornerRadius = bubbleHeight / 2
        countLabel.frame = self.bounds
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
                .background(Color(UIColor.systemGray5))
        }
    }
}

// MARK: - Photo Temporal Heatmap

struct PhotoTemporalHeatmap: View {
    let photos: [PhotoAsset]
    @Binding var startDate: Date
    @Binding var endDate: Date
    
    // Viewport manages the "zoomed in" range of the heatmap
    @State private var viewportStart: Date?
    @State private var viewportEnd: Date?
    
    // Drag state
    @State private var isDraggingStart = false
    @State private var isDraggingEnd = false
    // Anchors saved at drag start to avoid feedback loops during expansion
    @State private var dragAnchorViewportStart: Date?
    @State private var dragAnchorSpan: TimeInterval = 0
    
    @State private var indicatorDate: Date?
    @State private var indicatorX: CGFloat?
    
    // Cached calculation results
    @State private var cachedBuckets: [BinBucket] = []
    @State private var cachedGlobalStart: Date = Date()
    @State private var cachedGlobalEnd: Date = Date()
    @State private var cachedPeak: Double = 1.0
    
    // Fast accessors
    private var globalStart: Date { cachedGlobalStart }
    private var globalEnd: Date { cachedGlobalEnd }
    
    private func refreshCache() {
        let cal = Calendar.current
        let start = photos.min(by: { $0.creationDate < $1.creationDate })?.creationDate ?? Date()
        let end = photos.max(by: { $0.creationDate < $1.creationDate })?.creationDate ?? Date()
        
        cachedGlobalStart = cal.startOfDay(for: start)
        cachedGlobalEnd = cal.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
        
        // Initial buckets for the full range
        updateBuckets(for: viewportStart ?? cachedGlobalStart, end: viewportEnd ?? cachedGlobalEnd)
    }
    
    private func updateBuckets(for start: Date, end: Date) {
        let numBins = 50
        let span = end.timeIntervalSince(start)
        guard span > 0 else {
            cachedBuckets = []
            cachedPeak = 1.0
            return
        }
        
        let binDuration = span / Double(numBins)
        var bins = Array(repeating: 0, count: numBins)
        for photo in photos {
            let d = photo.creationDate
            guard d >= start && d <= end else { continue }
            let offset = d.timeIntervalSince(start)
            let idx = min(numBins - 1, max(0, Int(offset / binDuration)))
            bins[idx] += 1
        }
        cachedBuckets = bins.enumerated().map { BinBucket(id: $0.offset, count: $0.element) }
        cachedPeak = Double(bins.max() ?? 1)
    }
    
    private var currentViewportStart: Date { viewportStart ?? globalStart }
    private var currentViewportEnd: Date { viewportEnd ?? globalEnd }
    
    private var isZoomed: Bool {
        viewportStart != nil || viewportEnd != nil
    }

    struct BinBucket {
        let id: Int
        let count: Int
    }
    

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前旅程")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                    Text("\(photos.filter { $0.creationDate >= startDate && $0.creationDate <= endDate }.count) / \(photos.count) 张照片")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isZoomed {
                    Button(action: {
                        withAnimation(.spring()) {
                            viewportStart = nil
                            viewportEnd = nil
                            startDate = globalStart
                            endDate = globalEnd
                            updateBuckets(for: globalStart, end: globalEnd)
                        }
                    }) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(.horizontal, 4)
            
            GeometryReader { geo in
                let bkts = cachedBuckets
                let peak = cachedPeak
                let span = currentViewportEnd.timeIntervalSince(currentViewportStart)
                
                ZStack(alignment: .bottomLeading) {
                    // Padding to allow handles to move outside the chart area visually
                    Group {
                        // 1. Smooth Area Heatmap (Fill)
                        HeatmapAreaShape(buckets: bkts, peak: peak, isFill: true)
                            .fill(
                                LinearGradient(
                                    colors: [Color.orange.opacity(0.6), Color.orange.opacity(0.1)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        
                        // 2. Smooth Curve (Stroke - Top Only)
                        HeatmapAreaShape(buckets: bkts, peak: peak, isFill: false)
                            .stroke(Color.orange, lineWidth: 2)
                    }
                    .padding(.horizontal, 20) // The "Expansion Buffer"
                    
                    // Selection Handles (Relative to padded width)
                    let chartWidth = geo.size.width - 40
                    let leftX = span > 0 ? CGFloat((startDate.timeIntervalSince1970 - currentViewportStart.timeIntervalSince1970) / span) * chartWidth + 20 : 20
                    let rightX = span > 0 ? CGFloat((endDate.timeIntervalSince1970 - currentViewportStart.timeIntervalSince1970) / span) * chartWidth + 20 : geo.size.width - 20
                    
                    // Left Handle — drag past left edge to expand viewport earlier
                    CapsuleHandle(isDragging: isDraggingStart)
                        .position(x: leftX, y: geo.size.height / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isDraggingStart {
                                        dragAnchorViewportStart = currentViewportStart
                                        dragAnchorSpan = span
                                    }
                                    isDraggingStart = true
                                    guard let anchor = dragAnchorViewportStart, dragAnchorSpan > 0 else { return }
                                    
                                    let relativeX = value.location.x - 20
                                    let fraction = relativeX / chartWidth
                                    
                                    // Calculate target date based on EXACT finger position relative to original viewport
                                    let targetDate = anchor.addingTimeInterval(dragAnchorSpan * Double(fraction))
                                    let clamped = max(globalStart, min(targetDate, endDate.addingTimeInterval(-3600)))
                                    startDate = clamped
                                    
                                    // REVEAL EFFECT: If pulling left, expand viewport MORE than handle
                                    if clamped < currentViewportStart {
                                        // Viewport expands to reveal a 10% buffer earlier than the handle
                                        viewportStart = max(globalStart, clamped.addingTimeInterval(-dragAnchorSpan * 0.15))
                                    }
                                }
                                .onEnded { _ in
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        isDraggingStart = false
                                        dragAnchorViewportStart = nil
                                        dragAnchorSpan = 0
                                        // Auto-zoom to final selection (snaps to edges)
                                        viewportStart = startDate
                                        viewportEnd = endDate
                                    }
                                }
                        )
                    
                    // Right Handle
                    CapsuleHandle(isDragging: isDraggingEnd)
                        .position(x: rightX, y: geo.size.height / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isDraggingEnd {
                                        dragAnchorViewportStart = currentViewportStart
                                        dragAnchorSpan = span
                                    }
                                    isDraggingEnd = true
                                    guard let anchor = dragAnchorViewportStart, dragAnchorSpan > 0 else { return }
                                    
                                    let relativeX = value.location.x - 20
                                    let fraction = relativeX / chartWidth
                                    
                                    let targetDate = anchor.addingTimeInterval(dragAnchorSpan * Double(fraction))
                                    let clamped = min(globalEnd, max(targetDate, startDate.addingTimeInterval(3600)))
                                    endDate = clamped
                                    
                                    // REVEAL EFFECT: If pulling right, expand viewport MORE than handle
                                    if clamped > currentViewportEnd {
                                        // Viewport expands to reveal a 10% buffer later than the handle
                                        viewportEnd = min(globalEnd, clamped.addingTimeInterval(dragAnchorSpan * 0.15))
                                    }
                                }
                                .onEnded { _ in
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        isDraggingEnd = false
                                        dragAnchorViewportStart = nil
                                        dragAnchorSpan = 0
                                        // Zoom viewport to current selection
                                        viewportStart = startDate
                                        viewportEnd = endDate
                                    }
                                }
                        )

                    // 4. Interactive Tooltip (Scrubbing / Tapping Background)
                    if let x = indicatorX, let date = indicatorDate {
                        VStack(spacing: 4) {
                            Text(dateLabel(date))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange))
                                .foregroundColor(.white)
                            
                            Rectangle()
                                .fill(Color.orange.opacity(0.3))
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                        .position(x: x, y: geo.size.height / 2)
                        .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !isDraggingStart, !isDraggingEnd else {
                                indicatorDate = nil
                                indicatorX = nil
                                return
                            }
                            
                            let relativeX = value.location.x - 20
                            let chartWidth = geo.size.width - 40
                            let fraction = max(0, min(1, relativeX / chartWidth))
                            let date = currentViewportStart.addingTimeInterval(span * Double(fraction))
                            
                            indicatorDate = date
                            indicatorX = value.location.x
                        }
                        .onEnded { _ in
                            withAnimation(.easeOut(duration: 0.2)) {
                                indicatorDate = nil
                                indicatorX = nil
                            }
                        }
                )
            }
            .frame(height: 80)
            
            HStack {
                Text(dateLabel(startDate))
                Spacer()
                Text(dateLabel(endDate))
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
        }
        .padding(.vertical, 8)
        .onAppear {
            refreshCache()
            
            // Restore visual zoom state from currently selected dates
            // If the values differ from global range, initialize viewport to match
            if startDate > globalStart || endDate < globalEnd {
                viewportStart = startDate
                viewportEnd = endDate
                updateBuckets(for: startDate, end: endDate)
            }
        }
        .onChange(of: photos) { _, _ in
            refreshCache()
        }
        .onChange(of: viewportStart) { _, _ in
            updateBuckets(for: currentViewportStart, end: currentViewportEnd)
        }
        .onChange(of: viewportEnd) { _, _ in
            updateBuckets(for: currentViewportStart, end: currentViewportEnd)
        }
    }
    
    private func dateLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy.MM.dd"
        return fmt.string(from: date)
    }
}

// MARK: - Heatmap Area Shape & Helpers

struct HeatmapAreaShape: Shape {
    let buckets: [PhotoTemporalHeatmap.BinBucket]
    let peak: Double
    var isFill: Bool = true
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !buckets.isEmpty, buckets.count > 1 else { return path }
        
        let width = rect.width
        let height = rect.height
        let step = width / CGFloat(buckets.count - 1)
        
        var points: [CGPoint] = []
        for b in buckets {
            let x = CGFloat(b.id) * step
            let normalizedHeight = peak > 0 ? (Double(b.count) / peak) : 0
            let y = height - (CGFloat(normalizedHeight) * height * 0.85)
            points.append(CGPoint(x: x, y: y))
        }
        
        if isFill {
            path.move(to: CGPoint(x: 0, y: height))
            path.addLine(to: points[0])
            
            for i in 0..<points.count - 1 {
                let p1 = points[i]
                let p2 = points[i+1]
                let control1 = CGPoint(x: p1.x + (p2.x - p1.x) / 2, y: p1.y)
                let control2 = CGPoint(x: p1.x + (p2.x - p1.x) / 2, y: p2.y)
                path.addCurve(to: p2, control1: control1, control2: control2)
            }
            
            path.addLine(to: CGPoint(x: width, y: height))
            path.closeSubpath()
        } else {
            // For stroke: ONLY the top curve
            path.move(to: points[0])
            for i in 0..<points.count - 1 {
                let p1 = points[i]
                let p2 = points[i+1]
                let control1 = CGPoint(x: p1.x + (p2.x - p1.x) / 2, y: p1.y)
                let control2 = CGPoint(x: p1.x + (p2.x - p1.x) / 2, y: p2.y)
                path.addCurve(to: p2, control1: control1, control2: control2)
            }
        }
        
        return path
    }
}

private struct CapsuleHandle: View {
    let isDragging: Bool
    
    var body: some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 4, height: 32)
            .overlay(
                Capsule()
                    .stroke(Color.orange, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            .scaleEffect(isDragging ? 1.4 : 1.0)
            .contentShape(Rectangle().size(width: 30, height: 50)) // Larger touch target
    }
}

// MARK: - Photo Date Calendar View

struct PhotoDateCalendarView: UIViewRepresentable {
    let photos: [PhotoAsset]
    @Binding var selectedDate: Date      // The date currently being selected/focused
    @Binding var otherDate: Date         // The other end of the range (for marking)
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    func makeUIView(context: Context) -> UICalendarView {
        let calendarView = UICalendarView()
        calendarView.delegate = context.coordinator
        calendarView.calendar = Calendar.current
        calendarView.fontDesign = .rounded
        calendarView.tintColor = .systemOrange
        
        // Single date selection
        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        calendarView.selectionBehavior = selection
        
        // Initial visible date
        let cal = Calendar.current
        calendarView.setVisibleDateComponents(cal.dateComponents([.year, .month, .day], from: selectedDate), animated: false)
        selection.selectedDate = cal.dateComponents([.year, .month, .day], from: selectedDate)
        
        return calendarView
    }
    
    func updateUIView(_ uiView: UICalendarView, context: Context) {
        let cal = Calendar.current
        let targetComps = cal.dateComponents([.year, .month, .day], from: selectedDate)
        
        // Sync selection
        if let selection = uiView.selectionBehavior as? UICalendarSelectionSingleDate {
            if selection.selectedDate != targetComps {
                selection.selectedDate = targetComps
            }
        }
        
        // Sync visible month (Linkage fix)
        let visibleComps = uiView.visibleDateComponents
        if visibleComps.year != targetComps.year || visibleComps.month != targetComps.month {
            uiView.setVisibleDateComponents(targetComps, animated: true)
        }
        
        uiView.reloadDecorations(forDateComponents: [], animated: true)
    }
    
    class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: PhotoDateCalendarView
        let photoDates: Set<DateComponents>
        
        init(parent: PhotoDateCalendarView) {
            self.parent = parent
            let cal = Calendar.current
            var dates = Set<DateComponents>()
            for photo in parent.photos {
                dates.insert(cal.dateComponents([.year, .month, .day], from: photo.creationDate))
            }
            self.photoDates = dates
        }
        
        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            if photoDates.contains(dateComponents) {
                return .default(color: .systemOrange, size: .small)
            }
            return nil
        }
        
        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let comps = dateComponents, let date = Calendar.current.date(from: comps) else { return }
            parent.selectedDate = date
        }
    }
}

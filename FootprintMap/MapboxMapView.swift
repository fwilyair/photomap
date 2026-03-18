import SwiftUI
import MapboxMaps
import CoreLocation
import UIKit

// MARK: - Mapbox Map View (UIViewRepresentable)

struct MapboxMapWrapperView: UIViewRepresentable {
    var photos: [PhotoAsset]
    var waypoints: [Waypoint]
    var styleURI: String
    var playbackProgress: Double
    var playbackDuration: TimeInterval
    var isPlaying: Bool
    var isPreparing: Bool
    var onAnnotationSelected: ((_ photoIDs: [String], _ screenPoint: CGPoint) -> Void)?
    var onWaypointLitUp: ((_ waypointIndex: Int) -> Void)?
    
    func makeUIView(context: Context) -> MapView {
        let options = MapInitOptions(
            cameraOptions: nil,
            styleURI: StyleURI(rawValue: styleURI)
        )
        let mapView = MapView(frame: UIScreen.main.bounds, mapInitOptions: options)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        if !waypoints.isEmpty {
            let splineCoords = SplineRouteBuilder.buildSmoothSpline(waypoints: waypoints)
            var allCoords = splineCoords
            allCoords.append(contentsOf: waypoints.map { $0.coordinate })
            
            // Minimum span check: 0.05 degrees is ~5km
            if let first = allCoords.first {
                var minLat = first.latitude
                var maxLat = first.latitude
                var minLon = first.longitude
                var maxLon = first.longitude
                for c in allCoords {
                    minLat = min(minLat, c.latitude)
                    maxLat = max(maxLat, c.latitude)
                    minLon = min(minLon, c.longitude)
                    maxLon = max(maxLon, c.longitude)
                }
                if abs(maxLat - minLat) < 0.05 && abs(maxLon - minLon) < 0.05 {
                    let centerLat = (minLat + maxLat) / 2
                    let centerLon = (minLon + maxLon) / 2
                    allCoords.append(CLLocationCoordinate2D(latitude: centerLat + 0.025, longitude: centerLon + 0.025))
                    allCoords.append(CLLocationCoordinate2D(latitude: centerLat - 0.025, longitude: centerLon - 0.025))
                }
            }
            
            var camera = mapView.mapboxMap.camera(
                for: allCoords,
                padding: UIEdgeInsets(top: 100, left: 50, bottom: 300, right: 50),
                bearing: nil,
                pitch: nil
            )
            if let currentZoom = camera.zoom {
                camera.zoom = min(22.0, currentZoom + 0.8)
            }
            mapView.mapboxMap.setCamera(to: camera)
        }
        
        mapView.ornaments.scaleBarView.isHidden = true
        mapView.ornaments.compassView.isHidden = false
        mapView.ornaments.attributionButton.isHidden = true
        mapView.ornaments.logoView.isHidden = true
        
        context.coordinator.mapView = mapView
        return mapView
    }
    
    func updateUIView(_ mapView: MapView, context: Context) {
        // Force hide ornaments every update using public isHidden property
        mapView.ornaments.attributionButton.isHidden = true
        mapView.ornaments.logoView.isHidden = true
        mapView.ornaments.scaleBarView.isHidden = true
        
        if mapView.mapboxMap.styleURI?.rawValue != styleURI {
            mapView.mapboxMap.styleURI = StyleURI(rawValue: styleURI)
        }
        
        context.coordinator.onSelected = onAnnotationSelected
        context.coordinator.onWaypointLitUp = onWaypointLitUp
        
        context.coordinator.update(
            mapView: mapView,
            waypoints: waypoints,
            playbackProgress: playbackProgress,
            playbackDuration: playbackDuration,
            isPreparing: isPreparing,
            isPlaying: isPlaying
        )
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    // MARK: - Coordinator
    
    @MainActor
    class Coordinator: NSObject {
        weak var mapView: MapView?
        var onSelected: ((_ photoIDs: [String], _ screenPoint: CGPoint) -> Void)?
        var onWaypointLitUp: ((_ waypointIndex: Int) -> Void)?
        
        // Canvas annotation managers — creation ORDER = Z-order (bottom to top)
        private var pointAnnotationManager: PointAnnotationManager?     // Bottom: Waypoint icons
        private var polylineAnnotationManager: PolylineAnnotationManager? // Top: Trajectory line
        
        // Cache for rendered images to avoid expensive rendering (survives navigation)
        private static var iconCache: [Int: UIImage] = [:]  
        private static var hollowIconCache: [Int: UIImage] = [:]  
        
        private var lastWaypoints: [Waypoint] = []
        private var waypointLookup: [(coordinate: CLLocationCoordinate2D, photoIDs: [String])] = []
        private var lastSplineCoords: [CLLocationCoordinate2D] = []
        private var waypointSplineIndices: [Int] = [] // Maps waypoint to spline index
        private var lastProgress: Double = -1.0
        private var lastIsPreparing = false
        private var didInitialFit = false
        private var initialCamera: CameraOptions?
        
        func update(
            mapView: MapView,
            waypoints: [Waypoint],
            playbackProgress: Double,
            playbackDuration: TimeInterval,
            isPreparing: Bool,
            isPlaying: Bool
        ) {
            // Lazy init managers — ORDER determines Z-order on GL canvas (first created is bottom)
            // Polyline (bottom) -> Points (top)
            if polylineAnnotationManager == nil {
                polylineAnnotationManager = mapView.annotations.makePolylineAnnotationManager()
            }
            if pointAnnotationManager == nil {
                pointAnnotationManager = mapView.annotations.makePointAnnotationManager()
                pointAnnotationManager?.delegate = self
            }
            
            let splineCoords: [CLLocationCoordinate2D]
            let waypointsChanged = lastWaypoints != waypoints
            
            // 1. Data changes (waypoints change)
            if waypointsChanged {
                lastWaypoints = waypoints
                let newSplineCoords = SplineRouteBuilder.buildSmoothSpline(waypoints: waypoints)
                splineCoords = newSplineCoords
                lastSplineCoords = splineCoords
                
                // Precompute waypoint to spline indices for sync
                waypointSplineIndices = waypoints.map { wp in
                    var bestIdx = 0
                    var bestDist = Double.greatestFiniteMagnitude
                    for (i, sc) in splineCoords.enumerated() {
                        let d = pow(sc.latitude - wp.coordinate.latitude, 2) + pow(sc.longitude - wp.coordinate.longitude, 2)
                        if d < bestDist { bestDist = d; bestIdx = i }
                    }
                    return bestIdx
                }
                
                // Build Point Annotations for all waypoints
                var pointAnnotations: [PointAnnotation] = []
                
                for (index, wp) in waypoints.enumerated() {
                    var point = PointAnnotation(id: wp.photoIDs.joined(), coordinate: wp.coordinate)
                    
                    // Render filled icon if not in cache
                    let count = wp.photoCount
                    if Self.iconCache[count] == nil {
                        let renderer = ImageRenderer(content: WaypointClusterIcon(count: count, isFilled: true))
                        renderer.scale = UIScreen.main.scale
                        if let image = renderer.uiImage {
                            Self.iconCache[count] = image
                        }
                    }
                    // Render hollow icon if not in cache
                    if Self.hollowIconCache[count] == nil {
                        let renderer = ImageRenderer(content: WaypointClusterIcon(count: count, isFilled: false))
                        renderer.scale = UIScreen.main.scale
                        if let image = renderer.uiImage {
                            Self.hollowIconCache[count] = image
                        }
                    }
                    
                    // Default: all hollow (no playback yet)
                    if let image = Self.hollowIconCache[count] {
                        point.image = .init(image: image, name: "wp_hollow_\(count)")
                    }
                    
                    point.iconAnchor = .center
                    point.userInfo = ["photoIDs": wp.photoIDs, "waypointIndex": index, "isPassed": false]
                    pointAnnotations.append(point)
                }
                pointAnnotationManager?.annotations = pointAnnotations
                
                // Data-driven Camera Fit: Fix bounds both on first appear AND when filter changes
                let shouldFit = !didInitialFit || !isPlaying
                
                if shouldFit && (!splineCoords.isEmpty || !waypoints.isEmpty) {
                    var allCoords = splineCoords
                    allCoords.append(contentsOf: waypoints.map { $0.coordinate })
                    
                    // Safely calculate bounds and ensure a minimum span (prevent infinite zoom on single point)
                    if !allCoords.isEmpty {
                        var minLat = allCoords[0].latitude
                        var maxLat = allCoords[0].latitude
                        var minLon = allCoords[0].longitude
                        var maxLon = allCoords[0].longitude
                        
                        for c in allCoords {
                            minLat = min(minLat, c.latitude)
                            maxLat = max(maxLat, c.latitude)
                            minLon = min(minLon, c.longitude)
                            maxLon = max(maxLon, c.longitude)
                        }
                        
                        // Minimum span check: 0.05 degrees is ~5km, enough to avoid map artifacts
                        if abs(maxLat - minLat) < 0.05 && abs(maxLon - minLon) < 0.05 {
                            let centerLat = (minLat + maxLat) / 2
                            let centerLon = (minLon + maxLon) / 2
                            allCoords.append(CLLocationCoordinate2D(latitude: centerLat + 0.025, longitude: centerLon + 0.025))
                            allCoords.append(CLLocationCoordinate2D(latitude: centerLat - 0.025, longitude: centerLon - 0.025))
                        }
                    }
                    
                    var camera = mapView.mapboxMap.camera(
                        for: allCoords,
                        padding: UIEdgeInsets(top: 100, left: 50, bottom: 300, right: 50),
                        bearing: nil,
                        pitch: nil
                    )
                    
                    // Apply +0.8 boost to match MapKit's tighter feel
                    if let currentZoom = camera.zoom {
                        camera.zoom = min(22.0, currentZoom + 0.8)
                    }
                    
                    if !didInitialFit {
                        didInitialFit = true
                        mapView.mapboxMap.setCamera(to: camera)
                    } else {
                        // Smoothly transition to the filtered area
                        mapView.camera.ease(to: camera, duration: 1.2, curve: .easeInOut)
                    }
                }
            } else {
                splineCoords = lastSplineCoords
            }
            
            // 2. Playback state or Data changes
            if lastProgress != playbackProgress || lastIsPreparing != isPreparing || waypointsChanged {
                let justRewoundToZero = playbackProgress == 0.0 && lastProgress > 0.0
                let justEnded = playbackProgress == 1.0 && lastProgress < 1.0
                let justStartedPreparing = isPreparing && !lastIsPreparing
                
                let pointCount = splineCoords.count
                if pointCount > 1 {
                    // Sub-segment interpolation helper
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
                    
                    // Respect current progress even when not playing (paused state).
                    let effectiveProgress = playbackProgress
                    
                    let targetIdxFloat = effectiveProgress * Double(pointCount - 1)
                    let targetIdxInt = Int(floor(targetIdxFloat))
                    
                    // Build precise polyline path
                    var currentPath: [CLLocationCoordinate2D] = []
                    
                    if effectiveProgress > 0 {
                        if targetIdxInt > 0 {
                            currentPath.append(contentsOf: splineCoords[0...targetIdxInt])
                        } else {
                            currentPath.append(splineCoords[0])
                        }
                        
                        let exactCurrentCoord = interpolateCoord(at: targetIdxFloat, in: splineCoords)
                        
                        if let last = currentPath.last {
                            let dist = CLLocation(latitude: exactCurrentCoord.latitude, longitude: exactCurrentCoord.longitude)
                                .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
                            if dist > 0.1 || currentPath.count == 1 {
                                currentPath.append(exactCurrentCoord)
                            }
                        }
                    }
                    
                    // Helper: Convert MapKit altitude to Mapbox zoom level for exact visual match
                    func altitudeToZoom(altitude: Double, latitude: Double) -> Double {
                        // Aggressive match to MapKit: Increase to 120,000,000
                        let cosLat = cos(latitude * .pi / 180.0)
                        return log2(120000000.0 * cosLat / max(1.0, altitude))
                    }
                    
                    if currentPath.count >= 2 {
                        var polyline = PolylineAnnotation(id: "playback-line", lineCoordinates: currentPath)
                        polyline.lineColor = StyleColor(UIColor.systemOrange)
                        polyline.lineWidth = 5.0
                        polyline.lineOpacity = 0.95
                        polyline.lineJoin = .round
                        polylineAnnotationManager?.annotations = [polyline]
                    } else {
                        polylineAnnotationManager?.annotations = []
                    }
                    
                    // Update waypoint icons: filled for passed, hollow for unpassed
                    let wpCount = lastWaypoints.count
                    if wpCount > 0, var annotations = pointAnnotationManager?.annotations {
                        let targetIdxFloat = playbackProgress * Double(max(0, splineCoords.count - 1))
                        var didChange = false
                        
                        for i in 0..<annotations.count {
                            guard let wpIndex = annotations[i].userInfo?["waypointIndex"] as? Int else { continue }
                            
                            let isPassed: Bool
                            if wpIndex < waypointSplineIndices.count {
                                let wpSplineIdx = Double(waypointSplineIndices[wpIndex])
                                isPassed = playbackProgress > 0 && targetIdxFloat >= wpSplineIdx
                            } else {
                                let wpProgress = wpCount > 1 ? Double(wpIndex) / Double(wpCount - 1) : 0.0
                                isPassed = playbackProgress > 0 && playbackProgress >= wpProgress
                            }
                            
                            // Check if state actually changed before updating image
                            let currentState = (annotations[i].userInfo?["isPassed"] as? Bool) ?? false
                            if currentState != isPassed || annotations[i].image == nil {
                                let count = lastWaypoints[wpIndex].photoCount
                                if isPassed, let image = Self.iconCache[count] {
                                    annotations[i].image = .init(image: image, name: "wp_filled_\(count)")
                                    // Notify: waypoint just lit up (hollow -> filled)
                                    if !currentState {
                                        onWaypointLitUp?(wpIndex)
                                    }
                                } else if !isPassed, let image = Self.hollowIconCache[count] {
                                    annotations[i].image = .init(image: image, name: "wp_hollow_\(count)")
                                }
                                
                                // Update stored state
                                var userInfo = annotations[i].userInfo ?? [:]
                                userInfo["isPassed"] = isPassed
                                annotations[i].userInfo = userInfo
                                didChange = true
                            }
                        }
                        
                        // ONLY re-assign if something actually changed to avoid GL flicker
                        if didChange {
                            pointAnnotationManager?.annotations = annotations
                        }
                    }
                    
                    // Cinematic camera
                    if justStartedPreparing {
                        initialCamera = CameraOptions(
                            center: mapView.mapboxMap.cameraState.center,
                            zoom: mapView.mapboxMap.cameraState.zoom,
                            bearing: mapView.mapboxMap.cameraState.bearing,
                            pitch: mapView.mapboxMap.cameraState.pitch
                        )
                        if let startCoord = splineCoords.first {
                            // Match MapKit: Look ahead 3 seconds to determine initial altitude
                            let lookaheadSeconds = 3.0
                            let lookaheadProgress = lookaheadSeconds / playbackDuration
                            let lookaheadIdxFloat = min(Double(splineCoords.count - 1), lookaheadProgress * Double(splineCoords.count - 1))
                            let exactFutureCoord = interpolateCoord(at: lookaheadIdxFloat, in: splineCoords)
                            
                            let dist = CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
                                .distance(from: CLLocation(latitude: exactFutureCoord.latitude, longitude: exactFutureCoord.longitude))
                            
                            let targetAltitude = min(2500000.0, max(3000.0, dist * 2.2))
                            let targetZoom = altitudeToZoom(altitude: targetAltitude, latitude: startCoord.latitude)
                            
                            let newCamera = CameraOptions(
                                center: startCoord,
                                zoom: targetZoom,
                                bearing: 0,
                                pitch: 0
                            )
                            mapView.camera.ease(to: newCamera, duration: 1.8)
                        }
                    } else if justRewoundToZero || justEnded {
                        let zoomOut = { [weak self] in
                            guard let self = self, let mapView = self.mapView else { return }
                            
                            if let cam = self.initialCamera {
                                // Match MapKit: 3.5s smooth flight back for natural finish, fast for manual
                                mapView.camera.ease(to: cam, duration: justEnded ? 3.5 : 1.5)
                            } else if !splineCoords.isEmpty {
                                var allCoords = splineCoords
                                allCoords.append(contentsOf: waypoints.map { $0.coordinate })
                                var camera = mapView.mapboxMap.camera(
                                    for: allCoords,
                                    padding: UIEdgeInsets(top: 40, left: 10, bottom: 120, right: 10),
                                    bearing: nil,
                                    pitch: nil
                                )
                                // Apply +0.8 boost on zoom out/fit bounds as well
                                if let currentZoom = camera.zoom {
                                    camera.zoom = min(22.0, currentZoom + 0.8)
                                }
                                mapView.camera.ease(to: camera, duration: justEnded ? 3.5 : 1.5)
                            }
                        }
                        
                        if justEnded {
                            // Match MapKit: 0.5 second post-playback delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                zoomOut()
                            }
                        } else {
                            zoomOut()
                        }
                    } else if isPlaying, pointCount > 1 {
                        let exactCurrentCoord = interpolateCoord(at: targetIdxFloat, in: splineCoords)
                        
                        // Match MapKit Cinematic Flight Logic:
                        // 1. Look ahead for terrain/speed based altitude
                        let lookaheadSeconds = 0.8
                        let lookaheadProgress = lookaheadSeconds / playbackDuration
                        let lookaheadIdxFloat = min(Double(pointCount - 1), targetIdxFloat + (lookaheadProgress * Double(pointCount - 1)))
                        let exactFutureCoord = interpolateCoord(at: lookaheadIdxFloat, in: splineCoords)
                        
                        let dist = CLLocation(latitude: exactCurrentCoord.latitude, longitude: exactCurrentCoord.longitude)
                            .distance(from: CLLocation(latitude: exactFutureCoord.latitude, longitude: exactFutureCoord.longitude))
                        
                        // MapKit formula: min(600k, max(3000, dist * 1.5))
                        let targetAltitude = min(600000.0, max(3000.0, dist * 1.5))
                        let targetZoom = altitudeToZoom(altitude: targetAltitude, latitude: exactCurrentCoord.latitude)
                        
                        // 2. Smooth LERP for altitude zoom transition
                        let currentZoom = mapView.mapboxMap.cameraState.zoom
                        let lerpFactor = 0.04 // Exact match to MapKit's isPlaying lerp
                        let smoothedZoom = currentZoom + (targetZoom - currentZoom) * lerpFactor
                        
                        let newCamera = CameraOptions(
                            center: exactCurrentCoord,
                            zoom: smoothedZoom,
                            bearing: 0,
                            pitch: 0
                        )
                        // Precise 0.1s step for continuous motion
                        mapView.camera.ease(to: newCamera, duration: 0.1)
                    }
                }
                
                lastProgress = playbackProgress
                lastIsPreparing = isPreparing
            }
        }
    }
}

// MARK: - Annotation Interaction Delegate

extension MapboxMapWrapperView.Coordinator: AnnotationInteractionDelegate {
    func annotationManager(_ manager: AnnotationManager, didDetectTappedAnnotations annotations: [Annotation]) {
        guard let first = annotations.first as? PointAnnotation,
              let ids = first.userInfo?["photoIDs"] as? [String] else { return }
        
        let point = mapView?.mapboxMap.point(for: first.point.coordinates) ?? .zero
        onSelected?(ids, point)
    }
}


// MARK: - Native SwiftUI Cluster Icon

struct WaypointClusterIcon: View {
    let count: Int
    var isFilled: Bool = true
    
    private let orangeColor = Color(red: 0.92, green: 0.43, blue: 0.12)
    
    var body: some View {
        ZStack {
            if isFilled {
                // Filled: orange background
                Circle()
                    .fill(orangeColor)
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2.0)
            } else {
                // Hollow: white background, orange border
                Circle()
                    .fill(Color.white)
                Circle()
                    .strokeBorder(orangeColor, lineWidth: 2.0)
            }
            
            Text("\(count)")
                .font(.system(size: count > 9 ? 12 : 14, weight: .bold, design: .monospaced))
                .foregroundColor(isFilled ? .white : orangeColor)
        }
        .frame(width: count > 9 ? 30 : 26, height: count > 9 ? 30 : 26)
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
        .padding(4)
    }
}


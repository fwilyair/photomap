import SwiftUI
import MapboxMaps

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
    
    func makeUIView(context: Context) -> MapView {
        let options = MapInitOptions(
            styleURI: StyleURI(rawValue: styleURI)
        )
        let mapView = MapView(frame: .zero, mapInitOptions: options)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        mapView.ornaments.scaleBarView.isHidden = true
        mapView.ornaments.compassView.isHidden = false
        
        context.coordinator.mapView = mapView
        return mapView
    }
    
    func updateUIView(_ mapView: MapView, context: Context) {
        if mapView.mapboxMap.styleURI?.rawValue != styleURI {
            mapView.mapboxMap.styleURI = StyleURI(rawValue: styleURI)
        }
        
        context.coordinator.onSelected = onAnnotationSelected
        
        context.coordinator.update(
            mapView: mapView,
            waypoints: waypoints,
            playbackProgress: playbackProgress,
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
        
        // Canvas annotation managers — creation ORDER = Z-order (bottom to top)
        private var pointAnnotationManager: PointAnnotationManager?     // Bottom: Waypoint icons
        private var polylineAnnotationManager: PolylineAnnotationManager? // Top: Trajectory line
        
        // Cache for rendered images to avoid expensive rendering
        private var iconCache: [Int: UIImage] = [:]
        
        private var lastWaypoints: [Waypoint] = []
        private var waypointLookup: [(coordinate: CLLocationCoordinate2D, photoIDs: [String])] = []
        private var lastSplineCoords: [CLLocationCoordinate2D] = []
        private var lastProgress: Double = -1.0
        private var lastIsPreparing = false
        private var didInitialFit = false
        private var initialCamera: CameraOptions?
        
        func update(
            mapView: MapView,
            waypoints: [Waypoint],
            playbackProgress: Double,
            isPreparing: Bool,
            isPlaying: Bool
        ) {
            // Lazy init managers — ORDER determines Z-order on GL canvas
            // Points (bottom) -> Polyline (top)
            if pointAnnotationManager == nil {
                pointAnnotationManager = mapView.annotations.makePointAnnotationManager()
                pointAnnotationManager?.delegate = self
            }
            if polylineAnnotationManager == nil {
                polylineAnnotationManager = mapView.annotations.makePolylineAnnotationManager()
            }
            
            let splineCoords: [CLLocationCoordinate2D]
            
            // 1. Data changes (waypoints change)
            if lastWaypoints != waypoints {
                lastWaypoints = waypoints
                let newSplineCoords = SplineRouteBuilder.buildSmoothSpline(waypoints: waypoints)
                splineCoords = newSplineCoords
                lastSplineCoords = splineCoords
                
                // Build Point Annotations using rendered SwiftUI views as icons
                // This ensures the trajectory line (on canvas) can be rendered ON TOP of the waypoints
                var pointAnnotations: [PointAnnotation] = []
                for wp in waypoints {
                    var point = PointAnnotation(id: wp.photoIDs.joined(), coordinate: wp.coordinate)
                    
                    // Render image if not in cache
                    let count = wp.photoCount
                    if iconCache[count] == nil {
                        let renderer = ImageRenderer(content: WaypointClusterIcon(count: count))
                        renderer.scale = UIScreen.main.scale
                        if let image = renderer.uiImage {
                            iconCache[count] = image
                        }
                    }
                    
                    if let image = iconCache[count] {
                        point.image = .init(image: image, name: "wp_\(count)")
                    }
                    
                    point.iconAnchor = .center
                    point.userInfo = ["photoIDs": wp.photoIDs]
                    pointAnnotations.append(point)
                }
                pointAnnotationManager?.annotations = pointAnnotations
                
                // Fit bounds
                if !didInitialFit && (!splineCoords.isEmpty || !waypoints.isEmpty) {
                    didInitialFit = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        var allCoords = splineCoords
                        allCoords.append(contentsOf: waypoints.map { $0.coordinate })
                        
                        var camera = mapView.mapboxMap.camera(
                            for: allCoords,
                            padding: UIEdgeInsets(top: 100, left: 50, bottom: 300, right: 50),
                            bearing: nil,
                            pitch: nil
                        )
                        
                        // MapKit code limits the minimum zoom rect size to MKMapPoint 50000 
                        // To match the default scaled-out feel in MapKit, we cap the zoom
                        if let z = camera.zoom, z > 12.0 {
                            camera.zoom = 12.0 
                        }
                        
                        mapView.camera.ease(to: camera, duration: 0.8)
                    }
                }
            } else {
                splineCoords = lastSplineCoords
            }
            
            // 2. Playback state changes
            if lastProgress != playbackProgress || lastIsPreparing != isPreparing {
                let justRewoundToZero = playbackProgress == 0.0 && lastProgress > 0.0
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
                    
                    let targetIdxFloat = playbackProgress * Double(pointCount - 1)
                    let targetIdxInt = Int(floor(targetIdxFloat))
                    
                    // Build precise polyline path
                    var currentPath: [CLLocationCoordinate2D] = []
                    
                    if targetIdxFloat > 0 {
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
                    
                    if currentPath.count >= 2 {
                        var polyline = PolylineAnnotation(lineCoordinates: currentPath)
                        polyline.lineColor = StyleColor(UIColor.systemOrange)
                        polyline.lineWidth = 5.0
                        polyline.lineOpacity = 0.95
                        polyline.lineJoin = .round
                        polylineAnnotationManager?.annotations = [polyline]
                    } else {
                        polylineAnnotationManager?.annotations = []
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
                            let newCamera = CameraOptions(
                                center: startCoord,
                                zoom: 14.0,
                                bearing: 0,
                                pitch: 0
                            )
                            mapView.camera.ease(to: newCamera, duration: 1.8)
                        }
                    } else if justRewoundToZero {
                        if let cam = initialCamera {
                            mapView.camera.ease(to: cam, duration: 1.5)
                        } else if !splineCoords.isEmpty {
                            var allCoords = splineCoords
                            allCoords.append(contentsOf: waypoints.map { $0.coordinate })
                            var camera = mapView.mapboxMap.camera(
                                for: allCoords,
                                padding: UIEdgeInsets(top: 100, left: 50, bottom: 300, right: 50),
                                bearing: nil,
                                pitch: nil
                            )
                            if let z = camera.zoom, z > 12.0 {
                                camera.zoom = 12.0
                            }
                            mapView.camera.ease(to: camera, duration: 1.5)
                        }
                    } else if isPlaying, pointCount > 1 {
                        let exactCurrentCoord = interpolateCoord(at: targetIdxFloat, in: splineCoords)
                        
                        let currentCamera = mapView.mapboxMap.cameraState
                        let zoom = currentCamera.zoom
                        let targetZoom = 14.5
                        let smoothedZoom = zoom + (targetZoom - zoom) * 0.03
                        
                        let newCamera = CameraOptions(
                            center: exactCurrentCoord,
                            zoom: smoothedZoom,
                            bearing: 0,
                            pitch: 0
                        )
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
    
    var body: some View {
        ZStack {
            // Background orange circle
            Circle()
                .fill(Color(red: 0.92, green: 0.43, blue: 0.12))
            
            // White stroke - using strokeBorder ensures it stays inside the frame perfectly
            Circle()
                .strokeBorder(Color.white, lineWidth: 2.0)
            
            // Photo count text
            Text("\(count)")
                .font(.system(size: count > 9 ? 12 : 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(width: count > 9 ? 30 : 26, height: count > 9 ? 30 : 26)
        // Add subtle shadow for depth
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
        // CRITICAL: Add padding to prevent edge clipping during ImageRenderer snapshot
        // This ensures super-smooth anti-aliased edges on the GL canvas
        .padding(4)
    }
}


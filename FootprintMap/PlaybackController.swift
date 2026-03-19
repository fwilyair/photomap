import SwiftUI
import CoreLocation
import QuartzCore

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

enum PlaybackState: Equatable {
    case idle
    case preparing
    case playing        // Track playback with En-route flash
    case montage        // Finale montage
    case finished
}

@MainActor
@Observable
class PlaybackController {
    var state: PlaybackState = .idle
    var progress: Double = 0.0 // 0.0 to 1.0 representing map path progress
    var duration: TimeInterval = 10.0 // Trajectory playback duration
    var montageProgress: Double = 0.0 // 0.0 to 1.0 for montage timeline
    
    // For En-route Flash and Finale Montage
    var currentFlashbackAsset: PhotoAsset? = nil
    var currentMontageAsset: PhotoAsset? = nil
    
    // Playback Internals
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var startProgress: Double = 0.0
    private let prepareDuration: TimeInterval = 3.0
    
    // Processed Data
    private var waypoints: [Waypoint] = []
    private var photoDict: [String: PhotoAsset] = [:]
    
    // Pre-calculated Segment & Montage Timings
    private struct SegmentTiming {
        let waypointIndex: Int
        let duration: TimeInterval
        let startTime: TimeInterval
        let accumulatedProgressStart: Double
        let accumulatedProgressEnd: Double
        let asset: PhotoAsset?
    }
    private var pathSegments: [SegmentTiming] = []
    private var montageAssets: [PhotoAsset] = []
    private var montageDuration: TimeInterval = 0.0
    private var montageStartTime: TimeInterval = 0.0
    // Per-photo cumulative end times for time-weighted montage pacing
    private var montageSliceEndTimes: [TimeInterval] = []
    // Montage pause tracking
    private var montagePausedElapsed: TimeInterval = 0.0
    var isMontagePaused: Bool = false
    
    init() {}
    
    // MARK: - Setup
    
    func setup(waypoints: [Waypoint], photos: [PhotoAsset]) {
        self.waypoints = waypoints
        self.photoDict = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        calculateSegmentTimings()
        calculateMontageTimings()
        
        // Reset state
        self.stop()
    }
    
    // MARK: - Time-Driven Speed (Logarithmic) Calculation
    
    private func calculateSegmentTimings() {
        guard waypoints.count > 1 else {
            self.duration = 5.0
            self.pathSegments = []
            if let firstWP = waypoints.first, let firstPhotoID = firstWP.photoIDs.first {
                self.currentFlashbackAsset = photoDict[firstPhotoID]
            }
            return
        }
        
        // 1. Calculate raw weights based on log(1 + delta_T)
        var weights: [Double] = []
        var totalWeight: Double = 0.0
        
        for i in 0..<(waypoints.count - 1) {
            let wp1 = waypoints[i]
            let wp2 = waypoints[i+1]
            let deltaT = max(0, wp2.dateRange.start.timeIntervalSince(wp1.dateRange.start))
            
            // Non-linear logarithmic compression: Log(1 + seconds)
            // e.g., 1 min (60s) -> ~4.1, 1 hour (3600s) -> ~8.1, 6 hours (21600s) -> ~9.9
            var weight = log(1.0 + deltaT)
            
            // Provide a base minimum weight for zero-time jumps (e.g., burst photos)
            weight = max(1.0, weight)
            
            // Adaptive Long-Jump: if physical distance is huge, ensure weight is large enough to allow caching
            let loc1 = CLLocation(latitude: wp1.coordinate.latitude, longitude: wp1.coordinate.longitude)
            let loc2 = CLLocation(latitude: wp2.coordinate.latitude, longitude: wp2.coordinate.longitude)
            let physicalDist = loc1.distance(from: loc2)
            if physicalDist > 50_000 {
                // Grant extra weight to let map load tiles steadily, up to a max
                let scale = min(10.0, (physicalDist / 100_000.0) * 2.5) / 0.8  // Assuming 0.8 is approx average duration proportion
                weight = max(weight, scale * weight)
            }
            
            weights.append(weight)
            totalWeight += weight
        }
        
        // 2. Decide Total Trajectory Playback Duration
        // Base: ~0.9s per waypoint, capped at 45 seconds to prevent fatigue.
        let rawDuration = Double(waypoints.count) * 0.9
        let totalDuration = min(45.0, max(5.0, rawDuration))
        self.duration = totalDuration
        
        // 3. Apportion Total Duration to Segments using Weights
        var accumulatedTime: TimeInterval = 0.0
        var segments: [SegmentTiming] = []
        
        for i in 0..<weights.count {
            let normalizedRatio = weights[i] / totalWeight
            let rawSegmentTime = totalDuration * normalizedRatio
            
            // Constrain single segment min and max to ensure smoothness on extremes
            let boundedSegmentTime = min(6.0, max(0.4, rawSegmentTime))
            
            let wp = waypoints[i]
            let repAssetID = wp.photoIDs.first
            let repAsset = repAssetID != nil ? photoDict[repAssetID!] : nil
            
            let progressStart = accumulatedTime / totalDuration
            let progressEnd = (accumulatedTime + boundedSegmentTime) / totalDuration
            
            segments.append(SegmentTiming(
                waypointIndex: i,
                duration: boundedSegmentTime,
                startTime: accumulatedTime,
                accumulatedProgressStart: progressStart,
                accumulatedProgressEnd: progressEnd,
                asset: repAsset
            ))
            
            accumulatedTime += boundedSegmentTime
        }
        
        // Ensure final total duration matches our recalculations to keep `progress` logic 0...1 perfect
        self.duration = accumulatedTime
        
        // Final normalization of progress
        self.pathSegments = segments.map { s in
            SegmentTiming(
                waypointIndex: s.waypointIndex,
                duration: s.duration,
                startTime: s.startTime,
                accumulatedProgressStart: s.startTime / self.duration,
                accumulatedProgressEnd: (s.startTime + s.duration) / self.duration,
                asset: s.asset
            )
        }
    }
    
    private func calculateMontageTimings() {
        var collectedAssets: [PhotoAsset] = []
        for wp in waypoints {
            for id in wp.photoIDs {
                if let asset = photoDict[id] {
                    collectedAssets.append(asset)
                }
            }
        }
        
        collectedAssets.sort(by: { $0.creationDate < $1.creationDate })
        self.montageAssets = collectedAssets
        
        let count = collectedAssets.count
        guard count > 0 else {
            self.montageDuration = 0
            self.montageSliceEndTimes = []
            return
        }
        
        // Total montage duration: dynamic, max 15s, min = count * 1.0s bounded at 3s
        let idealMinTime = Double(count) * 1.0
        let totalMontage = max(3.0, min(15.0, idealMinTime))
        self.montageDuration = totalMontage
        
        // Calculate per-photo weights based on time gaps to next photo
        // Photos followed by a long gap get more display time ("lingering")
        // Dense bursts get shorter display
        var weights: [Double] = []
        for i in 0..<count {
            if i < count - 1 {
                let gap = max(0, collectedAssets[i+1].creationDate.timeIntervalSince(collectedAssets[i].creationDate))
                // Use sqrt to soften extremes (not as aggressive as log)
                weights.append(max(0.5, sqrt(gap + 1.0)))
            } else {
                // Last photo: give it a base weight
                weights.append(1.0)
            }
        }
        
        let totalWeight = weights.reduce(0, +)
        
        // Convert weights to cumulative end times
        var cumulative: TimeInterval = 0
        var sliceEnds: [TimeInterval] = []
        for w in weights {
            let sliceDuration = max(0.3, totalMontage * (w / totalWeight)) // min 0.3s per photo
            cumulative += sliceDuration
            sliceEnds.append(cumulative)
        }
        
        // Normalize to exact totalMontage (rounding errors)
        if let last = sliceEnds.last, last > 0 {
            let scale = totalMontage / last
            sliceEnds = sliceEnds.map { $0 * scale }
        }
        
        self.montageSliceEndTimes = sliceEnds
    }
    
    // MARK: - Playback Controls
    
    func togglePlayPause() {
        if isPlaying || isPreparing || isMontage {
            pause()
        } else {
            play()
        }
    }
    
    func play() {
        if progress >= 1.0 {
            // Already at end, restart
            progress = 0.0
            state = .preparing
            currentFlashbackAsset = nil
            currentMontageAsset = nil
        } else if state == .finished || state == .idle {
            if progress == 0.0 {
                state = .preparing
            } else {
                state = .playing
            }
        } else if state == .montage {
            // Already handled: continue montage
        } else {
            state = .playing
        }
        
        startProgress = progress
        startTime = CACurrentMediaTime()
        
        // Resume montage tracking if returning to montage
        if state == .montage {
            // If we paused during montage, startTime must adapt to montage progress
            // Since we don't have a `montageProgress`, we start fresh or from 0 for now.
            // A more complex implementation would track montage paused time.
            montageStartTime = CACurrentMediaTime() 
        }
        
        startDisplayLink()
    }
    
    func pause() {
        if state == .preparing || state == .playing {
            state = .idle
        } else if state == .montage {
            // Pause montage — keep state as .montage but stop the display link
            montagePausedElapsed = CACurrentMediaTime() - montageStartTime
            isMontagePaused = true
            stopDisplayLink()
            return // Don't change state, keep showing montage
        } else {
            state = .idle
        }
        stopDisplayLink()
    }
    
    func resumeMontage() {
        guard state == .montage, isMontagePaused else { return }
        isMontagePaused = false
        // Adjust montageStartTime so elapsed continues from where we left off
        montageStartTime = CACurrentMediaTime() - montagePausedElapsed
        startDisplayLink()
    }
    
    func stop() {
        stopDisplayLink()
        state = .idle
        progress = 0.0
        currentFlashbackAsset = nil
        currentMontageAsset = nil
    }
    
    func seek(to newProgress: Double) {
        let safeProgress = max(0.0, min(1.0, newProgress))
        self.progress = safeProgress
        
        if isPlaying || isPreparing {
            state = .playing // Snaps out of preparation
            startProgress = safeProgress
            startTime = CACurrentMediaTime()
        }
        updateFlashbackAssetForCurrentProgress()
    }
    
    // MARK: - DisplayLink Handling
    
    private func startDisplayLink() {
        displayLink?.invalidate()
        let proxy = DisplayLinkProxy(target: self, selector: #selector(handleDisplayLink(_:)))
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - startTime
        
        switch state {
        case .preparing:
            if elapsed >= prepareDuration {
                state = .playing
                startTime = CACurrentMediaTime()
                startProgress = 0.0
            } else {
                self.progress = 0.0
            }
            
        case .playing:
            guard duration > 0 else {
                finishTrajectory()
                return
            }
            
            let addedProgress = elapsed / duration
            var newProgress = startProgress + addedProgress
            
            if newProgress >= 1.0 {
                newProgress = 1.0
                self.progress = newProgress
                finishTrajectory()
            } else {
                self.progress = newProgress
                updateFlashbackAssetForCurrentProgress()
            }
            
        case .montage:
            let now = CACurrentMediaTime()
            let montageElapsed = now - montageStartTime
            
            if montageElapsed < 0 {
                // In dedicated fade-in period
                montageProgress = 0.0
                updateMontageAssetForElapsed(0)
            } else if montageElapsed >= montageDuration {
                montageProgress = 1.0
                finishMontage()
            } else {
                montageProgress = montageDuration > 0 ? montageElapsed / montageDuration : 0
                updateMontageAssetForElapsed(montageElapsed)
            }
            
        default:
            break
        }
    }
    
    private let montageFadeInDuration: TimeInterval = 1.2

    private func finishTrajectory() {
        self.progress = 1.0
        self.currentFlashbackAsset = nil
        
        if montageDuration > 0 && !montageAssets.isEmpty {
            state = .montage
            // Shift start time into the future to allow for a dedicated fade-in period
            montageStartTime = CACurrentMediaTime() + montageFadeInDuration
            updateMontageAssetForElapsed(0)
        } else {
            state = .finished
            stopDisplayLink()
        }
    }
    
    private func finishMontage() {
        // Keep currentMontageAsset so the last photo stays visible
        self.state = .finished
        stopDisplayLink()
    }
    
    /// Replay only the final photo montage
    func replayMontage() {
        guard montageDuration > 0 && !montageAssets.isEmpty else { return }
        
        // Reset montage state
        self.state = .montage
        self.montageProgress = 0.0
        // Set start time with fade-in delay
        self.montageStartTime = CACurrentMediaTime() + montageFadeInDuration
        self.isMontagePaused = false
        self.montagePausedElapsed = 0.0
        
        // Ensure display link is running
        startDisplayLink()
        
        // Show first asset immediately
        updateMontageAssetForElapsed(0)
    }
    
    /// Manual navigation for montage browse
    func setMontageIndex(_ index: Int) {
        let count = montageAssets.count
        guard count > 0 else { return }
        
        let clampedIndex = max(0, min(count - 1, index))
        currentMontageAsset = montageAssets[clampedIndex]
    }
    
    var currentMontageIndex: Int {
        guard let current = currentMontageAsset else { return 0 }
        return montageAssets.firstIndex(where: { $0.id == current.id }) ?? 0
    }
    
    /// Restart the entire journey from the beginning
    func resetAndPlay() {
        stop() // Reset progress, state, and assets
        play() // Start preparation -> playback -> montage
    }
    
    private func updateFlashbackAssetForCurrentProgress() {
        // No longer self-drives flashback — map calls showFlashbackForWaypoint directly
    }
    
    /// Called by map view when a waypoint transitions from hollow to filled
    func showFlashbackForWaypoint(index: Int) {
        guard index >= 0, index < waypoints.count else { return }
        let wp = waypoints[index]
        if let firstID = wp.photoIDs.first, let asset = photoDict[firstID] {
            currentFlashbackAsset = asset
        } else {
            currentFlashbackAsset = nil
        }
    }
    
    /// Clear flashback (called when playback ends or reaches montage)
    func clearFlashback() {
        currentFlashbackAsset = nil
    }
    
    private func updateMontageAssetForElapsed(_ elapsed: TimeInterval) {
        guard !montageAssets.isEmpty, !montageSliceEndTimes.isEmpty else { return }
        
        var index = 0
        for (i, endTime) in montageSliceEndTimes.enumerated() {
            if elapsed < endTime {
                index = i
                break
            }
            index = i
        }
        index = max(0, min(montageAssets.count - 1, index))
        
        let asset = montageAssets[index]
        if currentMontageAsset?.id != asset.id {
            // No animation — instant swap for short-duration slices
            self.currentMontageAsset = asset
        }
    }
    
    /// User-triggered exit from montage
    func exitMontage() {
        currentMontageAsset = nil
        currentFlashbackAsset = nil
        state = .finished
        progress = 1.0
        montageProgress = 0.0
        stopDisplayLink()
    }
    
    /// Seek montage to a specific progress (0.0~1.0)
    func seekMontage(to newProgress: Double) {
        guard state == .montage, montageDuration > 0 else { return }
        let clamped = max(0.0, min(1.0, newProgress))
        let targetElapsed = clamped * montageDuration
        
        montageProgress = clamped
        
        // Rebase montageStartTime so the display link picks up from here
        if isMontagePaused {
            montagePausedElapsed = targetElapsed
        } else {
            montageStartTime = CACurrentMediaTime() - targetElapsed
        }
        
        updateMontageAssetForElapsed(targetElapsed)
    }
    
    // MARK: - Legacy Boolean Helpers
    
    var isPlaying: Bool {
        return state == .playing
    }
    
    var isPreparing: Bool {
        return state == .preparing
    }
    
    var isMontage: Bool {
        return state == .montage
    }
}

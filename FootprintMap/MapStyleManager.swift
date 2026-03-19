import Foundation
import SwiftUI

// MARK: - Map Style Definition

enum MapStyleOption: String, CaseIterable, Identifiable, Codable {
    // Apple MapKit layers
    case appleDefault = "apple_default"
    case appleSatellite = "apple_satellite"
    case appleHybrid = "apple_hybrid"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .appleDefault: return "标准"
        case .appleSatellite: return "卫星"
        case .appleHybrid: return "混合"
        }
    }
    
    var iconName: String {
        switch self {
        case .appleDefault: return "map"
        case .appleSatellite: return "globe.americas"
        case .appleHybrid: return "map.circle"
        }
    }
    
    var isApple: Bool { true }
    
    /// Apple Maps always uses GCJ-02 in China
    var isGCJ02Required: Bool { true }
    
    static var allStyles: [MapStyleOption] { [.appleDefault, .appleSatellite, .appleHybrid] }
}

// MARK: - Style Manager (Persistence)

@Observable @MainActor
final class MapStyleManager {
    static let shared = MapStyleManager()
    
    var currentStyle: MapStyleOption {
        didSet { save() }
    }
    
    private let key = "com.seven.footprintmap.mapStyle"
    
    private init() {
        if let raw = UserDefaults.standard.string(forKey: key),
           let style = MapStyleOption(rawValue: raw) {
            self.currentStyle = style
        } else {
            self.currentStyle = .appleDefault
        }
    }
    
    private func save() {
        UserDefaults.standard.set(currentStyle.rawValue, forKey: key)
    }
}

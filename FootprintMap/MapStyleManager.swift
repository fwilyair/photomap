import Foundation
import SwiftUI

// MARK: - Map Style Definition

enum MapStyleOption: String, CaseIterable, Identifiable, Codable {
    case appleDefault = "apple_default"
    case appleSatellite = "apple_satellite"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .appleDefault: return "标准"
        case .appleSatellite: return "卫星"
        }
    }
    
    var iconName: String {
        switch self {
        case .appleDefault: return "map"
        case .appleSatellite: return "globe.americas"
        }
    }
    
    var isApple: Bool { true }
    
    /// Apple Maps always uses GCJ-02 in China
    var isGCJ02Required: Bool { true }
    
    static var allStyles: [MapStyleOption] { [.appleDefault, .appleSatellite] }
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

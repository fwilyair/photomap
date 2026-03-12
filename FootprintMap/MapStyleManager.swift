import Foundation
import SwiftUI

// MARK: - Map Style Definition

enum MapStyleOption: String, CaseIterable, Identifiable, Codable {
    // Apple MapKit layers
    case appleDefault = "apple_default"
    case appleSatellite = "apple_satellite"
    
    // Mapbox layers
    case mapboxLight = "mapbox_light"
    case mapboxDark = "mapbox_dark"
    case mapboxStreets = "mapbox_streets"
    case mapboxStandard = "mapbox_standard"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .appleDefault: return "标准"
        case .appleSatellite: return "卫星"
        case .mapboxLight: return "现代简约"
        case .mapboxDark: return "现代酷黑"
        case .mapboxStreets: return "街景"
        case .mapboxStandard: return "3D城市"
        }
    }
    
    var iconName: String {
        switch self {
        case .appleDefault: return "map"
        case .appleSatellite: return "globe.americas"
        case .mapboxLight: return "sun.max"
        case .mapboxDark: return "moon.stars"
        case .mapboxStreets: return "road.lanes"
        case .mapboxStandard: return "building.2"
        }
    }
    
    var isApple: Bool {
        switch self {
        case .appleDefault, .appleSatellite: return true
        default: return false
        }
    }
    
    var isMapbox: Bool { !isApple }
    
    /// Mapbox style URI string (only valid for Mapbox styles)
    var mapboxStyleURI: String? {
        switch self {
        case .mapboxLight: return "mapbox://styles/mapbox/light-v11"
        case .mapboxDark: return "mapbox://styles/mapbox/dark-v11"
        case .mapboxStreets: return "mapbox://styles/mapbox/streets-v12"
        case .mapboxStandard: return "mapbox://styles/mapbox/standard"
        default: return nil
        }
    }
    
    /// Group label for the picker
    var providerLabel: String {
        isApple ? "Apple" : "Mapbox"
    }
    
    static var appleStyles: [MapStyleOption] { [.appleDefault, .appleSatellite] }
    static var mapboxStyles: [MapStyleOption] { [.mapboxLight, .mapboxDark, .mapboxStreets, .mapboxStandard] }
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

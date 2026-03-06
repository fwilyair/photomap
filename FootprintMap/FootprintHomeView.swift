import SwiftUI
import Photos

// MARK: - View Model (Manager)

@Observable @MainActor
final class PhotoManager {
    
    enum AuthStatus {
        case notDetermined
        case restricted
        case denied
        case authorized
        case limited
    }
    
    var authorizationStatus: AuthStatus = .notDetermined
    var validPhotos: [PhotoAsset] = []
    var isScanning: Bool = false
    var errorMessage: String? = nil
    
    init() {
        checkInitialStatus()
    }
    
    private func checkInitialStatus() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        updateAuthStatus(from: status)
    }
    
    private func updateAuthStatus(from status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self.authorizationStatus = .notDetermined
        case .restricted: self.authorizationStatus = .restricted
        case .denied: self.authorizationStatus = .denied
        case .authorized, .limited: self.authorizationStatus = .authorized
        @unknown default: self.authorizationStatus = .notDetermined
        }
    }
    
    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        self.updateAuthStatus(from: status)
        
        if status == .authorized || status == .limited {
            await fetchPhotosWithLocation()
        }
    }
    
    func fetchPhotosWithLocation() async {
        self.isScanning = true
        self.errorMessage = nil
        
        let fetchedAssets = await Task.detached(priority: .userInitiated) { () -> [PhotoAsset] in
            let fetchOptions = PHFetchOptions()
            fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            
            let result = PHAsset.fetchAssets(with: fetchOptions)
            var assets: [PhotoAsset] = []
            
            result.enumerateObjects { (asset, _, _) in
                autoreleasepool {
                    if let location = asset.location, let date = asset.creationDate {
                        assets.append(PhotoAsset(id: asset.localIdentifier, location: location.coordinate, creationDate: date))
                    }
                }
            }
            return assets
        }.value
        
        self.validPhotos = fetchedAssets
        self.isScanning = false
    }
}

// MARK: - UI Layer

struct FootprintHomeView: View {
    @State private var photoManager = PhotoManager()
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background Layer (Option B: Cinematic Glassmorphism)
                Image("HomeBackground")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Scale slightly to prevent transparent/white edges from the heavy blur bleeding in
                    .scaleEffect(1.05)
                    .clipped()
                    // Reduced blur from 12 to 10 per user request
                    .blur(radius: 10)
                    .overlay(Color.black.opacity(0.25)) // Darken slightly to compensate for less blur
                    .ignoresSafeArea()
                
                // Content Layer (Option A: Minimalist Editorial)
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white)
                            .shadow(color: .white.opacity(0.3), radius: 10, x: 0, y: 5)
                            .padding(.bottom, 8)
                        
                        Text("足迹地图")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("基于本地相册的无感旅行轨迹记录")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.top, 60)
                    
                    Spacer()
                    
                    // Massive Visual Anchor
                    VStack(alignment: .leading, spacing: -10) {
                        if photoManager.isScanning {
                            ProgressView()
                                .scaleEffect(2.0)
                                .tint(.white)
                                .frame(height: 120)
                        } else if photoManager.authorizationStatus != .authorized && photoManager.authorizationStatus != .limited {
                            Image(systemName: "photo.lock")
                                .font(.system(size: 60))
                                .foregroundColor(.white.opacity(0.8))
                                .frame(height: 120)
                        } else {
                            Text("\(photoManager.validPhotos.count)")
                                .font(.system(size: 120, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 10)
                                .contentTransition(.numericText())
                                .tracking(-4) // tighter letter spacing for huge numbers
                        }
                        
                        Text("张有效足迹照片")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.leading, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 40)
                    .animation(.bouncy, value: photoManager.validPhotos.count)
                    .animation(.easeInOut, value: photoManager.isScanning)
                    
                    Spacer()
                    
                    // Floating Action Bar CTA
                    VStack(spacing: 16) {
                        if !photoManager.validPhotos.isEmpty && (photoManager.authorizationStatus == .authorized || photoManager.authorizationStatus == .limited) {
                            NavigationLink(destination: FootprintMapView(photos: photoManager.validPhotos)) {
                                floatingActionBar(title: "查看足迹地图", icon: "arrow.right")
                            }
                        }
                        
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task {
                                if photoManager.authorizationStatus == .notDetermined {
                                    await photoManager.requestAuthorization()
                                } else if photoManager.authorizationStatus == .authorized || photoManager.authorizationStatus == .limited {
                                    await photoManager.fetchPhotosWithLocation()
                                } else {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        await UIApplication.shared.open(url)
                                    }
                                }
                            }
                        }) {
                            Text(buttonTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .disabled(photoManager.isScanning)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 50)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
    
    @ViewBuilder
    private func floatingActionBar(title: String, icon: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.black)
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark) // Force dark blur material
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
    
    private var buttonTitle: String {
        switch photoManager.authorizationStatus {
        case .notDetermined: return "授权相册访问"
        case .authorized, .limited: return "重新扫描合并轨迹"
        case .restricted, .denied: return "前往设置开启无感授权"
        }
    }
}

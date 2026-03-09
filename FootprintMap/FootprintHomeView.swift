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
    var newlyAddedCount: Int = 0
    
    private var cacheFileURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("photo_cache.json")
    }
    
    init() {
        checkInitialStatus()
        loadCache() // Load cache instantly on initialization
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
            await addPhotos()
        }
    }
    
    func loadCache() {
        do {
            let data = try Data(contentsOf: cacheFileURL)
            let cachedPhotos = try JSONDecoder().decode([PhotoAsset].self, from: data)
            self.validPhotos = cachedPhotos
        } catch {
            print("No cache found or failed to load: \(error)")
        }
    }
    
    func saveCache() {
        do {
            let data = try JSONEncoder().encode(self.validPhotos)
            try data.write(to: cacheFileURL)
        } catch {
            print("Failed to save cache: \(error)")
        }
    }
    
    func addPhotos() async {
        self.isScanning = true
        self.errorMessage = nil
        self.newlyAddedCount = 0
        
        let latestDate = self.validPhotos.max(by: { $0.creationDate < $1.creationDate })?.creationDate
        
        let fetchedAssets = await Task.detached(priority: .userInitiated) { () -> [PhotoAsset] in
            let fetchOptions = PHFetchOptions()
            let basePredicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            
            if let latest = latestDate {
                fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    basePredicate,
                    NSPredicate(format: "creationDate > %@", latest as NSDate)
                ])
            } else {
                fetchOptions.predicate = basePredicate
            }
            
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
        
        // Filter out existing IDs just in case
        let existingIDs = Set(self.validPhotos.map { $0.id })
        let newUniqueAssets = fetchedAssets.filter { !existingIDs.contains($0.id) }
        
        self.validPhotos.append(contentsOf: newUniqueAssets)
        self.validPhotos.sort(by: { $0.creationDate < $1.creationDate })
        self.newlyAddedCount = newUniqueAssets.count
        
        self.saveCache()
        self.isScanning = false
    }
}

// MARK: - UI Layer

struct FootprintHomeView: View {
    @State private var photoManager = PhotoManager()
    @State private var showNoNewPhotosToast: Bool = false
    
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
                                .font(.system(size: 140, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 10)
                                .contentTransition(.numericText())
                                .tracking(-6) // tighter letter spacing for huge numbers
                        }
                        
                        Text("枚被定格的地理印记")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.8)) // slightly boosted visibility from 0.7
                            .padding(.leading, 8)
                        
                        if photoManager.newlyAddedCount > 0 {
                            Text("新点亮了 \(photoManager.newlyAddedCount) 处世界的角落")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(Color(hue: 0.45, saturation: 0.6, brightness: 0.9)) // Soft cinematic teal/green
                                .padding(.leading, 8)
                                .padding(.top, 16)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.top, UIScreen.main.bounds.height * 0.22)
                    .animation(.bouncy, value: photoManager.validPhotos.count)
                    .animation(.easeInOut, value: photoManager.newlyAddedCount)
                    .animation(.easeInOut, value: photoManager.isScanning)
                    
                    Spacer()
                    
                    // Floating Action Bar CTA
                    VStack(spacing: 16) {
                        if photoManager.authorizationStatus == .authorized || photoManager.authorizationStatus == .limited {
                            HStack(spacing: 16) {
                                // Add Photos Button
                                Button(action: {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    Task { 
                                        await photoManager.addPhotos() 
                                        if photoManager.newlyAddedCount == 0 {
                                            withAnimation(.spring()) {
                                                showNoNewPhotosToast = true
                                            }
                                            // Auto hide after 3 seconds
                                            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                                            withAnimation(.spring()) {
                                                showNoNewPhotosToast = false
                                            }
                                        }
                                    }
                                }) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 24, weight: .medium))
                                        .foregroundColor(.white)
                                        .frame(width: 64, height: 64)
                                        .background(
                                            Circle()
                                                .fill(.ultraThinMaterial)
                                                .environment(\.colorScheme, .dark)
                                        )
                                        .overlay(
                                            Circle().stroke(Color.white.opacity(0.2), lineWidth: 1)
                                        )
                                        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                                }
                                .disabled(photoManager.isScanning)
                                
                                // View Map Button
                                if !photoManager.validPhotos.isEmpty {
                                    NavigationLink(destination: FootprintMapView(photos: photoManager.validPhotos)) {
                                        floatingActionBar(title: "漫游记忆的疆界", icon: "arrow.right")
                                    }
                                }
                            }
                        } else {
                            // Authorization Button
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                Task {
                                    if photoManager.authorizationStatus == .notDetermined {
                                        await photoManager.requestAuthorization()
                                    } else {
                                        if let url = URL(string: UIApplication.openSettingsURLString) {
                                            await UIApplication.shared.open(url)
                                        }
                                    }
                                }
                            }) {
                                Text(buttonTitle)
                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 20)
                                    .background(
                                        Capsule()
                                            .fill(.ultraThinMaterial)
                                            .environment(\.colorScheme, .dark)
                                    )
                                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                            }
                            .disabled(photoManager.isScanning)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 50)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                if showNoNewPhotosToast {
                    Text("本次无新增照片")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                        )
                        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                        .padding(.top, 60)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
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
        case .authorized, .limited: return "添加照片"
        case .restricted, .denied: return "前往设置开启无感授权"
        }
    }
}

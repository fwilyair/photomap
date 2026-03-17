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
    
    // Cached global range
    var globalStartDate: Date?
    var globalEndDate: Date?
    
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
        updateGlobalRange()
    }
    
    private func updateGlobalRange() {
        guard !validPhotos.isEmpty else { return }
        // Photos are sorted, so first and last are the range
        self.globalStartDate = validPhotos.first?.creationDate
        self.globalEndDate = validPhotos.last?.creationDate
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
        
        updateGlobalRange()
        self.saveCache()
        self.isScanning = false
    }
    
    func simulateAddition() {
        // Mock a few photos with random coordinates around world cities
        let cities = [
            (31.23, 121.47), // Shanghai
            (39.90, 116.40), // Beijing
            (35.67, 139.65), // Tokyo
            (51.50, -0.12),  // London
            (40.71, -74.00)  // New York
        ]
        
        let randomCity = cities.randomElement()!
        let newAsset = PhotoAsset(
            id: UUID().uuidString,
            location: .init(latitude: randomCity.0 + Double.random(in: -0.05...0.05),
                            longitude: randomCity.1 + Double.random(in: -0.05...0.05)),
            creationDate: Date()
        )
        
        withAnimation {
            self.validPhotos.append(newAsset)
            self.newlyAddedCount += 1
            self.saveCache()
        }
    }
    
    func clearData() {
        withAnimation {
            self.validPhotos = []
            self.newlyAddedCount = 0
            self.saveCache()
        }
    }
}

// MARK: - UI Layer

struct FootprintHomeView: View {
    @State private var photoManager = PhotoManager()
    @State private var showNoNewPhotosToast: Bool = false
    @State private var animatedTotalCount: Double = 0
    
    // Zero-state animation triggers
    @State private var showZeroStateLine1: Bool = false
    @State private var showZeroStateLine2: Bool = false
    @State private var showZeroStateLine3: Bool = false
    
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
                    VStack(alignment: .leading, spacing: 0) {
                        if photoManager.authorizationStatus != .authorized && photoManager.authorizationStatus != .limited {
                            Image(systemName: "photo.lock")
                                .font(.system(size: 60))
                                .foregroundColor(.white.opacity(0.8))
                                .frame(height: 120)
                        } else if photoManager.validPhotos.isEmpty {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("唤醒相册")
                                    .font(.system(size: 38, weight: .bold, design: .rounded))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 1.0, green: 0.95, blue: 0.88),  // Luminous Champagne
                                                Color(red: 1.0, green: 0.88, blue: 0.80),  // Bright Peach
                                                Color(red: 0.95, green: 0.80, blue: 0.75)  // Soft Warm Rose
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .shadow(color: Color(red: 0.95, green: 0.80, blue: 0.75).opacity(0.4), radius: 16, x: 0, y: 5)
                                    .opacity(showZeroStateLine1 ? 1 : 0)
                                    .offset(y: showZeroStateLine1 ? 0 : 15)
                                    .blur(radius: showZeroStateLine1 ? 0 : 8)
                                
                                Text("将散落的记忆锚定为")
                                    .font(.system(size: 18, weight: .regular, design: .rounded))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundColor(Color(red: 0.85, green: 0.88, blue: 0.92)) // distinct silver
                                    .tracking(8)
                                    .opacity(showZeroStateLine2 ? 1 : 0)
                                    .offset(y: showZeroStateLine2 ? 0 : 15)
                                    .blur(radius: showZeroStateLine2 ? 0 : 8)
                                    
                                Text("永恒的坐标")
                                    .font(.system(size: 72, weight: .black, design: .rounded))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundColor(Color(hue: 0.45, saturation: 0.6, brightness: 0.9)) // Soft cinematic teal/green
                                    .tracking(2)
                                    .shadow(color: Color(hue: 0.45, saturation: 0.6, brightness: 0.9).opacity(0.2), radius: 8, x: 0, y: 0)
                                    .opacity(showZeroStateLine3 ? 1 : 0)
                                    .offset(y: showZeroStateLine3 ? 0 : 15)
                                    .blur(radius: showZeroStateLine3 ? 0 : 8)
                            }
                            .padding(.top, 10)
                            .padding(.bottom, 20)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            .onAppear {
                                showZeroStateLine1 = false
                                showZeroStateLine2 = false
                                showZeroStateLine3 = false
                                
                                withAnimation(.easeOut(duration: 1.2)) {
                                    showZeroStateLine1 = true
                                }
                                withAnimation(.easeOut(duration: 1.2).delay(0.8)) {
                                    showZeroStateLine2 = true
                                }
                                withAnimation(.easeOut(duration: 1.2).delay(1.6)) {
                                    showZeroStateLine3 = true
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: -10) {
                                AnimatedNumberView(value: animatedTotalCount)
                                    .font(.system(size: 140, weight: .heavy, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 1.0, green: 0.95, blue: 0.88),  // Luminous Champagne
                                                Color(red: 1.0, green: 0.88, blue: 0.80),  // Bright Peach
                                                Color(red: 0.95, green: 0.80, blue: 0.75)  // Soft Warm Rose
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .shadow(color: Color(red: 0.95, green: 0.80, blue: 0.75).opacity(0.3),
                                            radius: 12,
                                            x: 0,
                                            y: 5)
                                    .tracking(-6) // tighter letter spacing for huge numbers
                                
                                Text("枚被定格的地理印记")
                                    .font(.system(size: 16, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.8)) // slightly boosted visibility from 0.7
                                    .padding(.leading, 8)
                            }
                            
                            if photoManager.newlyAddedCount > 0 {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("新点亮了")
                                        .font(.system(size: 16, weight: .medium, design: .rounded))
                                        .foregroundColor(Color(red: 0.85, green: 0.88, blue: 0.92)) // Distinct metallic silver
                                    
                                    Text(verbatim: "\(photoManager.newlyAddedCount)")
                                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                        .foregroundColor(Color(hue: 0.45, saturation: 0.6, brightness: 0.9)) // Soft cinematic teal/green
                                    
                                    Text("处世界的角落")
                                        .font(.system(size: 16, weight: .medium, design: .rounded))
                                        .foregroundColor(Color(red: 0.85, green: 0.88, blue: 0.92)) // Distinct metallic silver
                                }
                                .padding(.leading, 8)
                                .padding(.top, 16)
                                .transition(.opacity)
                            }
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
                                    NavigationLink(destination: FootprintMapView(
                                        photos: photoManager.validPhotos,
                                        initialStartDate: photoManager.globalStartDate,
                                        initialEndDate: photoManager.globalEndDate
                                    )) {
                                        floatingActionBar(title: "漫游记忆的疆界", icon: "arrow.right")
                                    }
                                }
                            }
                            
                            // TEMPORARY DEBUG BUTTONS
                            HStack(spacing: 20) {
                                Button(action: {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    photoManager.simulateAddition()
                                }) {
                                    Label("模拟新增", systemImage: "sparkles")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Capsule().fill(Color.white.opacity(0.1)))
                                }
                                
                                Button(action: {
                                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                    photoManager.clearData()
                                }) {
                                    Label("快速清理", systemImage: "trash")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.red.opacity(0.8))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Capsule().fill(Color.red.opacity(0.1)))
                                }
                            }
                            .padding(.top, 8)
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
        .onAppear {
            animatedTotalCount = Double(photoManager.validPhotos.count)
            // DEBUG: list available Chinese-related fonts
            for family in UIFont.familyNames.sorted() {
                for name in UIFont.fontNames(forFamilyName: family) {
                    let l = name.lowercased()
                    if l.contains("yuan") || l.contains("heiti") || l.contains("songti") || l.contains("kaiti") || l.contains("pingfang") || l.contains("baoli") || l.contains("weibei") || l.contains("libian") || l.contains("xingkai") || l.contains("yuppy") || l.contains("lantinghei") || l.contains("hei") || l.contains("round") {
                        print("FONT: \(family) -> \(name)")
                    }
                }
            }
        }
        .onChange(of: photoManager.validPhotos.count) { old, new in
            if old == 0 {
                // Initial load: Snap immediately
                animatedTotalCount = Double(new)
            } else {
                // Incremental addition: Use a slow-starting, springy ease-out bounce over ~1.5s
                withAnimation(.interpolatingSpring(mass: 1.0, stiffness: 45, damping: 6, initialVelocity: 0)) {
                    animatedTotalCount = Double(new)
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

struct AnimatedNumberView: View, Animatable {
    var value: Double
    
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    
    var body: some View {
        Text(verbatim: "\(Int(round(value)))")
            .lineLimit(1)
            .minimumScaleFactor(0.3)
    }
}

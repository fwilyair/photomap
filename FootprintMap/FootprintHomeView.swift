import SwiftUI
import Photos

// MARK: - View Model (Manager)

struct SmartCollection: Identifiable, Hashable {
    let id: String
    let title: String
    let type: CollectionType
    let startDate: Date
    let endDate: Date
    let coverAssetID: String? // For bento box preview
    
    enum CollectionType {
        case memory, trip, recentDay
    }
}

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
    
    // Smart Collections & Home detection
    var smartCollections: [SmartCollection] = []
    var stationaryPoint: CLLocationCoordinate2D?
    var hideStationary: Bool = UserDefaults.standard.bool(forKey: "hideStationary") {
        didSet { UserDefaults.standard.set(hideStationary, forKey: "hideStationary") }
    }
    
    private var cacheFileURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("photo_cache.json")
    }
    
    init() {
        checkInitialStatus()
        loadCache() // Load cache instantly on initialization
        
        // Background analysis for smart features
        Task {
            await fetchSmartCollections()
            detectStationaryPoint()
        }
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
        
        // Re-analyze after adding new photos
        cleanupInvalidAssets()
        await fetchSmartCollections()
        detectStationaryPoint()
        
        self.isScanning = false
    }
    
    /// Silently remove references to photos that are no longer in the system library
    private func cleanupInvalidAssets() {
        let allIDs = self.validPhotos.map { $0.id }
        guard !allIDs.isEmpty else { return }
        
        let fetchOptions = PHFetchOptions()
        let result = PHAsset.fetchAssets(withLocalIdentifiers: allIDs, options: fetchOptions)
        
        var validIDSet = Set<String>()
        result.enumerateObjects { asset, _, _ in
            validIDSet.insert(asset.localIdentifier)
        }
        
        if validIDSet.count < allIDs.count {
            let initialCount = self.validPhotos.count
            self.validPhotos.removeAll { !validIDSet.contains($0.id) }
            print("🧹 Silent Cleanup: Removed \(initialCount - self.validPhotos.count) invalid photo references.")
            
            updateGlobalRange()
            saveCache()
        }
    }
    
    func fetchSmartCollections() async {
        let options = PHFetchOptions()
        var collections: [SmartCollection] = []
        
        // 1. 保底策略：尝试获取系统直接提供的重要智能相册（如果有的话）
        let allSmartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: options)
        
        allSmartAlbums.enumerateObjects { collection, _, _ in
            let title = collection.localizedTitle ?? ""
            var type: SmartCollection.CollectionType? = nil
            
            if title.contains("Trip") || title.contains("旅行") || title.contains("旅程") {
                type = .trip
            } else if title.contains("Memory") || title.contains("回忆") || title.contains("瞬间") {
                type = .memory
            }
            
            if let type = type, let start = collection.startDate, let end = collection.endDate {
                let assetsFetch = PHAsset.fetchAssets(in: collection, options: nil)
                let coverID = assetsFetch.firstObject?.localIdentifier
                
                collections.append(SmartCollection(
                    id: collection.localIdentifier,
                    title: title.isEmpty ? "精彩瞬间" : title,
                    type: type,
                    startDate: start,
                    endDate: end,
                    coverAssetID: coverID
                ))
            }
        }
        
        // 2. 核心算法：基于系统原生 Moment 拼装旅程与回忆
        analyzeAndGenerateCollections(into: &collections)
        
        // 最终去重、排序与截取
        self.smartCollections = collections
            .filter { $0.startDate < $0.endDate }
            .sorted(by: { $0.startDate > $1.startDate })
            .prefix(20)
            .map { $0 }
    }
    
    private func analyzeAndGenerateCollections(into collections: inout [SmartCollection]) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: true)]
        
        // 请求系统切割好的底层积木：Moments
        let moments = PHAssetCollection.fetchMoments(with: options)
        
        var currentTripMoments: [PHAssetCollection] = []
        let now = Date()
        var localCollections: [SmartCollection] = []
        
        moments.enumerateObjects { moment, _, _ in
            guard let start = moment.startDate, let end = moment.endDate else { return }
            
            // 1. 甄别近期的高光时刻（作为“回忆”）
            let daysSinceMoment = now.timeIntervalSince(end) / 86400
            if daysSinceMoment <= 30 {
                let assetsCount = PHAsset.fetchAssets(in: moment, options: nil).count
                if assetsCount >= 20 { // 聚会、同城游等高密度事件
                    let coverID = PHAsset.fetchAssets(in: moment, options: nil).firstObject?.localIdentifier
                    let title = moment.localizedTitle ?? "近期瞬间"
                    let memory = SmartCollection(
                        id: moment.localIdentifier + "_mem",
                        title: title,
                        type: .memory,
                        startDate: start,
                        endDate: end,
                        coverAssetID: coverID
                    )
                    localCollections.append(memory)
                }
            }
            
            // 2. 甄别是否在异地（拼装“旅程”）
            var isFarFromHome = true
            if let home = self.stationaryPoint, let location = moment.approximateLocation {
                let distance = location.distance(from: CLLocation(latitude: home.latitude, longitude: home.longitude))
                if distance <= 20000 { // 在常驻地 20km 内，视为本地活动
                    isFarFromHome = false
                }
            } else if self.stationaryPoint != nil && moment.approximateLocation == nil {
                // 如果没有获取到地理位置，保守视为非远途，以避免误判合并
                isFarFromHome = false
            }
            
            if isFarFromHome {
                // 属于异地，加入当前旅程拼图
                if let last = currentTripMoments.last, let lastEnd = last.endDate {
                    let gap = start.timeIntervalSince(lastEnd)
                    if gap > 86400 * 2 { // 超过 48 小时空档期，代表上个旅程断片了，打包结单
                        if let trip = self.processTripMoments(currentTripMoments) {
                            localCollections.append(trip)
                        }
                        currentTripMoments = [moment]
                    } else {
                        currentTripMoments.append(moment)
                    }
                } else {
                    currentTripMoments.append(moment)
                }
            } else {
                // 回到本地了，把积攒的异地时刻打包为旅程结单
                if let trip = self.processTripMoments(currentTripMoments) {
                    localCollections.append(trip)
                }
                currentTripMoments.removeAll()
            }
        }
        
        // 将最后一段潜在旅程打包
        if let trip = self.processTripMoments(currentTripMoments) {
            localCollections.append(trip)
        }
        
        collections.append(contentsOf: localCollections)
    }
    
    private func processTripMoments(_ moments: [PHAssetCollection]) -> SmartCollection? {
        guard !moments.isEmpty else { return nil }
        
        let start = moments.first!.startDate!
        let end = moments.last!.endDate!
        let duration = end.timeIntervalSince(start)
        
        // 只有短于 24 小时但多个组合，或者跨越 6 小时以上的，才算一次正经旅程
        guard duration > 6 * 3600 || moments.count >= 2 else { return nil }
        
        // 灵活命名：尝试使用合并块中出现过的有效位置名称
        var tripTitle = "旅途"
        let titles = moments.compactMap { $0.localizedTitle }.filter { !$0.isEmpty }
        if let firstTitle = titles.first {
            tripTitle = "\(firstTitle)之旅"
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日"
            tripTitle = "\(fmt.string(from: start))之旅"
        }
        
        // 提取最具代表性的封面，这里简单取最后（或最新）时刻的首张图
        let fetchOptions = PHFetchOptions()
        fetchOptions.fetchLimit = 1
        let coverID = PHAsset.fetchAssets(in: moments.last!, options: fetchOptions).firstObject?.localIdentifier
        
        // 防止和本地生成的产生ID冲突
        let combinedID = moments.map { $0.localIdentifier }.joined(separator: "_").prefix(20)
        
        return SmartCollection(
            id: String(combinedID),
            title: tripTitle,
            type: .trip,
            startDate: start,
            endDate: end,
            coverAssetID: coverID
        )
    }
    
    func detectStationaryPoint() {
        guard validPhotos.count > 50 else { return }
        
        // Simple grid-based frequency analysis (approx 100m grid)
        var grid: [String: Int] = [:]
        var dayCounts: [String: Set<Int>] = [:] // How many distinct days per grid cell
        
        let calendar = Calendar.current
        
        for photo in validPhotos {
            let latInt = Int(photo.location.latitude * 1000)
            let lonInt = Int(photo.location.longitude * 1000)
            let key = "\(latInt),\(lonInt)"
            
            grid[key, default: 0] += 1
            
            let day = calendar.ordinality(of: .day, in: .era, for: photo.creationDate) ?? 0
            if dayCounts[key] == nil { dayCounts[key] = [] }
            dayCounts[key]?.insert(day)
        }
        
        // Home point is likely where we have most photos AND most distinct days
        let candidate = dayCounts.max { a, b in
            // Primary sort: distinct days, Secondary: photo count
            if a.value.count != b.value.count {
                return a.value.count < b.value.count
            }
            return (grid[a.key] ?? 0) < (grid[b.key] ?? 0)
        }
        
        if let key = candidate?.key, let days = candidate?.value, days.count > 7 {
            let parts = key.split(separator: ",").map { Double($0)! / 1000.0 }
            if parts.count == 2 {
                self.stationaryPoint = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
                print("Detected stationary point: \(parts[0]), \(parts[1]) over \(days.count) days")
            }
        }
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
                                    ).environment(photoManager)) {
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

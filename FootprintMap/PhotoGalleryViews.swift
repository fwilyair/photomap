import SwiftUI
import Photos

// MARK: - Selected Annotation Info

struct SelectedAnnotationInfo: Equatable {
    let photoIDs: [String]
    let screenPoint: CGPoint
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.photoIDs == rhs.photoIDs }
}

// MARK: - Thumbnail Loader

@MainActor @Observable
class ThumbnailLoader {
    var thumbnails: [String: UIImage] = [:]
    
    func loadThumbnails(for ids: [String], size: CGSize = CGSize(width: 300, height: 300)) {
        let idsToLoad = ids.filter { thumbnails[$0] == nil }
        guard !idsToLoad.isEmpty else { return }
        
        let fetchOptions = PHFetchOptions()
        
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: idsToLoad, options: fetchOptions)
        
        // Log if some IDs are missing from the fetch result
        if assets.count < idsToLoad.count {
            let foundIDs = Set((0..<assets.count).map { assets.object(at: $0).localIdentifier })
            let missing = idsToLoad.filter { !foundIDs.contains($0) }
            print("📸 ThumbnailLoader: Missing \(missing.count) assets in library fetch. IDs: \(missing.prefix(3))...")
        }
        
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        assets.enumerateObjects { [weak self] asset, _, _ in
            PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: .aspectFill, options: options
            ) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    print("❌ ThumbnailLoader: Error requesting image for \(asset.localIdentifier): \(error.localizedDescription)")
                }
                
                guard let image = image else { return }
                
                Task { @MainActor in
                    self?.thumbnails[asset.localIdentifier] = image
                }
            }
        }
    }
    
    func loadFullImage(for id: String, completion: @escaping @Sendable (UIImage?) -> Void) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else { completion(nil); return }
        
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestImage(
            for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options
        ) { image, _ in
            completion(image)
        }
    }
}

// MARK: - Fan Thumbnail Overlay

struct FanThumbnailOverlay: View {
    let photoIDs: [String]
    let screenPoint: CGPoint
    let thumbnailLoader: ThumbnailLoader
    let onPhotoTap: (String) -> Void
    let onMoreTap: () -> Void
    let onDismiss: () -> Void
    
    private let maxThumbs = 3
    private let thumbSize: CGFloat = 64
    private let fanRadius: CGFloat = 85
    
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Compute the direction vector pointing from the screen point toward the center
            let centerX = size.width / 2
            let centerY = size.height / 2
            // Base angle: direction from annotation toward screen center (in radians, 0 = up)
            let dx = centerX - screenPoint.x
            let dy = centerY - screenPoint.y
            let baseAngle = atan2(dx, -dy) // atan2(x, -y) gives 0=up, positive=clockwise
            
            ZStack {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }
                
                let displayIDs = Array(photoIDs.prefix(maxThumbs))
                let hasMore = photoIDs.count > maxThumbs
                let totalItems = displayIDs.count + (hasMore ? 1 : 0)
                
                ZStack {
                    ForEach(Array(displayIDs.enumerated()), id: \.offset) { index, id in
                        let offset = fanOffset(index: index, total: totalItems, baseAngle: baseAngle)
                        
                        Button(action: { onPhotoTap(id) }) {
                            thumbnailCircle(for: id)
                        }
                        .offset(x: offset.x, y: offset.y)
                        .transition(.scale.combined(with: .opacity))
                    }
                    
                    if hasMore {
                        let offset = fanOffset(index: displayIDs.count, total: totalItems, baseAngle: baseAngle)
                        
                        Button(action: { onMoreTap() }) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: thumbSize, height: thumbSize)
                                Text("+\(photoIDs.count - maxThumbs)")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(.orange)
                            }
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                        }
                        .offset(x: offset.x, y: offset.y)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .position(x: screenPoint.x, y: screenPoint.y)
            }
        }
    }
    
    @ViewBuilder
    private func thumbnailCircle(for id: String) -> some View {
        if let thumb = thumbnailLoader.thumbnails[id] {
            Image(uiImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbSize, height: thumbSize)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        } else {
            Circle()
                .fill(.gray.opacity(0.3))
                .frame(width: thumbSize, height: thumbSize)
                .overlay(ProgressView().scaleEffect(0.8))
        }
    }
    
    private func fanOffset(index: Int, total: Int, baseAngle: Double) -> CGPoint {
        let spreadAngle = 70.0 * (.pi / 180) // Convert to radians
        let itemAngle: Double
        if total == 1 {
            itemAngle = baseAngle
        } else {
            let startAngle = baseAngle - spreadAngle / 2
            itemAngle = startAngle + (spreadAngle / Double(total - 1)) * Double(index)
        }
        return CGPoint(x: sin(itemAngle) * fanRadius, y: -cos(itemAngle) * fanRadius)
    }
}

// MARK: - Cluster Quick Gallery (Bottom Scroller)

struct ClusterQuickGallery: View {
    let photoIDs: [String]
    let thumbnailLoader: ThumbnailLoader
    let onPhotoTap: (String) -> Void
    let onShowFullGallery: () -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Interaction Area
            VStack(spacing: 12) {
                // Header / Handle
                HStack {
                    Text("足迹详情 (\(photoIDs.count)张照片)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                    
                    Spacer()
                    
                    Button(action: onShowFullGallery) {
                        Text("查看全部")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                // Horizontal Scroller
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(photoIDs, id: \.self) { id in
                            Button(action: { 
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                onPhotoTap(id) 
                            }) {
                                quickThumbnail(for: id)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(height: 100)
                .padding(.bottom, 20)
            }
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .offset(y: 0)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            thumbnailLoader.loadThumbnails(for: Array(photoIDs.prefix(20)), size: CGSize(width: 300, height: 300))
        }
    }
    
    @ViewBuilder
    private func quickThumbnail(for id: String) -> some View {
        if let thumb = thumbnailLoader.thumbnails[id] {
            Image(uiImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .frame(width: 80, height: 80)
                .overlay(ProgressView().scaleEffect(0.7))
        }
    }
}

// MARK: - Masonry Gallery

struct MasonryGalleryView: View {
    let photoIDs: [String]
    let thumbnailLoader: ThumbnailLoader
    let onPhotoTap: (String) -> Void
    
    @State private var internalFullScreenID: String?
    
    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(photoIDs, id: \.self) { id in
                        Button(action: {
                            internalFullScreenID = id
                            thumbnailLoader.loadThumbnails(for: [id], size: CGSize(width: 800, height: 800))
                        }) {
                            if let thumb = thumbnailLoader.thumbnails[id] {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(minHeight: 110)
                                    .frame(maxHeight: 160)
                                    .clipped()
                                    .cornerRadius(8)
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.gray.opacity(0.15))
                                    .frame(height: 120)
                                    .overlay(ProgressView())
                            }
                        }
                    }
                }
                .padding(4)
            }
            .navigationTitle("该组照片 (\(photoIDs.count)张)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(isPresented: Binding(
            get: { internalFullScreenID != nil },
            set: { if !$0 { internalFullScreenID = nil } }
        )) {
            if let id = internalFullScreenID {
                FullScreenPhotoView(photoIDs: photoIDs, initialPhotoID: id, thumbnailLoader: thumbnailLoader)
            }
        }
    }
}

// MARK: - Full Screen Photo Viewer

struct FullScreenPhotoView: View {
    let photoIDs: [String]
    let initialPhotoID: String
    let thumbnailLoader: ThumbnailLoader
    @Environment(\.dismiss) private var dismiss
    @State private var currentID: String
    @State private var fullImages: [String: UIImage] = [:]
    @State private var scales: [String: CGFloat] = [:]
    
    init(photoIDs: [String], initialPhotoID: String, thumbnailLoader: ThumbnailLoader) {
        self.photoIDs = photoIDs
        self.initialPhotoID = initialPhotoID
        self.thumbnailLoader = thumbnailLoader
        self._currentID = State(initialValue: initialPhotoID)
    }
    
    var body: some View {
        ZStack {
            // Tap background to dismiss
            Color.black.ignoresSafeArea()
                .onTapGesture { dismiss() }
            
            TabView(selection: $currentID) {
                ForEach(photoIDs, id: \.self) { id in
                    photoPage(for: id)
                        .tag(id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photoIDs.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .automatic))
        }
        .onAppear {
            // Preload current and adjacent images
            preloadImages(around: initialPhotoID)
        }
        .onChange(of: currentID) { _, newID in
            preloadImages(around: newID)
        }
        .statusBarHidden()
    }
    
    @ViewBuilder
    private func photoPage(for id: String) -> some View {
        let currentScale = scales[id] ?? 1.0
        
        ZStack {
            Color.black // Fill each page
                .onTapGesture { dismiss() }
            
            if let image = fullImages[id] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(currentScale)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in scales[id] = value.magnification }
                            .onEnded { _ in withAnimation { scales[id] = max(1.0, min(currentScale, 5.0)) } }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { scales[id] = currentScale > 1.0 ? 1.0 : 2.5 }
                    }
            } else if let thumb = thumbnailLoader.thumbnails[id] {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(ProgressView().tint(.white))
            } else {
                ProgressView().tint(.white)
            }
        }
    }
    
    private func preloadImages(around id: String) {
        guard let idx = photoIDs.firstIndex(of: id) else { return }
        let range = max(0, idx - 1)...min(photoIDs.count - 1, idx + 1)
        for i in range {
            let pid = photoIDs[i]
            guard fullImages[pid] == nil else { continue }
            thumbnailLoader.loadFullImage(for: pid) { image in
                Task { @MainActor in
                    if let image { fullImages[pid] = image }
                }
            }
        }
    }
}

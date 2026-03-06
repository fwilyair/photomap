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
    
    func loadThumbnails(for ids: [String], size: CGSize = CGSize(width: 200, height: 200)) {
        let idsToLoad = ids.filter { thumbnails[$0] == nil }
        guard !idsToLoad.isEmpty else { return }
        
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: idsToLoad, options: nil)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        
        assets.enumerateObjects { asset, _, _ in
            PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: .aspectFill, options: options
            ) { image, _ in
                if let image = image {
                    Task { @MainActor in
                        self.thumbnails[asset.localIdentifier] = image
                    }
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
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            
            let displayIDs = Array(photoIDs.prefix(maxThumbs))
            let hasMore = photoIDs.count > maxThumbs
            let totalItems = displayIDs.count + (hasMore ? 1 : 0)
            
            ZStack {
                ForEach(Array(displayIDs.enumerated()), id: \.offset) { index, id in
                    let offset = fanOffset(index: index, total: totalItems)
                    
                    Button(action: { onPhotoTap(id) }) {
                        thumbnailCircle(for: id)
                    }
                    .offset(x: offset.x, y: offset.y)
                    .transition(.scale.combined(with: .opacity))
                }
                
                if hasMore {
                    let offset = fanOffset(index: displayIDs.count, total: totalItems)
                    
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
            .position(x: screenPoint.x, y: screenPoint.y - 60)
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
    
    private func fanOffset(index: Int, total: Int) -> CGPoint {
        let spreadAngle = 70.0
        let radius: CGFloat = 85
        let startAngle: Double
        if total == 1 {
            startAngle = 0
        } else {
            startAngle = -spreadAngle / 2
        }
        let angle = total == 1 ? 0.0 : startAngle + (spreadAngle / Double(total - 1)) * Double(index)
        let rad = angle * .pi / 180
        return CGPoint(x: sin(rad) * radius, y: -cos(rad) * radius)
    }
}

// MARK: - Masonry Gallery

struct MasonryGalleryView: View {
    let photoIDs: [String]
    let thumbnailLoader: ThumbnailLoader
    let onPhotoTap: (String) -> Void
    
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
                        Button(action: { onPhotoTap(id) }) {
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
    }
}

// MARK: - Full Screen Photo Viewer

struct FullScreenPhotoView: View {
    let photoID: String
    let thumbnailLoader: ThumbnailLoader
    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?
    @State private var scale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let image = fullImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in scale = value.magnification }
                            .onEnded { _ in withAnimation { scale = max(1.0, min(scale, 5.0)) } }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { scale = scale > 1.0 ? 1.0 : 2.5 }
                    }
            } else if let thumb = thumbnailLoader.thumbnails[photoID] {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(ProgressView().tint(.white))
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding()
            }
        }
        .onAppear {
            thumbnailLoader.loadFullImage(for: photoID) { image in
                Task { @MainActor in self.fullImage = image }
            }
        }
        .statusBarHidden()
    }
}

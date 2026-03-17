import SwiftUI
import Photos

struct SmartCollectionsGalleryView: View {
    @Environment(PhotoManager.self) private var photoManager
    @Environment(\.dismiss) private var dismiss
    
    let onSelect: (SmartCollection) -> Void
    
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(photoManager.smartCollections.enumerated()), id: \.element.id) { index, collection in
                        BentoCard(collection: collection, isLarge: index % 3 == 0)
                            .onTapGesture {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onSelect(collection)
                                dismiss()
                            }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("精彩瞬间")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct BentoCard: View {
    let collection: SmartCollection
    let isLarge: Bool
    
    @State private var coverImage: UIImage?
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background Image
            if let image = coverImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .frame(height: isLarge ? 240 : 160)
                    .clipped()
            } else {
                Color.gray.opacity(0.2)
                    .frame(height: isLarge ? 240 : 160)
            }
            
            // Gradient Overlay
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            
            // Text Content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: collection.type == .trip ? "airplane" : "sparkles")
                        .font(.system(size: 12, weight: .bold))
                    Text(collection.type == .trip ? "旅程" : "回忆")
                        .font(.system(size: 10, weight: .bold))
                        .textCase(.uppercase)
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                
                Text(collection.title)
                    .font(.system(size: isLarge ? 20 : 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                
                Text(collection.startDate.formatted(.dateTime.month().day()))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
        .onAppear {
            loadCoverImage()
        }
    }
    
    private func loadCoverImage() {
        guard let assetID = collection.coverAssetID else { return }
        
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return }
        
        let targetSize = CGSize(width: 400, height: 400)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, _ in
            self.coverImage = image
        }
    }
}

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
                LinearGradient(
                    colors: [Color(uiColor: .systemGroupedBackground), Color(uiColor: .secondarySystemGroupedBackground)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(
                                .linearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                        
                        Text("足迹地图")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        
                        Text("基于本地相册的无感旅行轨迹记录")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)
                    
                    Spacer()
                    
                    statusCard
                    
                    Spacer()
                    
                    VStack(spacing: 16) {
                        if !photoManager.validPhotos.isEmpty {
                            NavigationLink(destination: FootprintMapView(photos: photoManager.validPhotos)) {
                                HStack {
                                    Image(systemName: "map.fill")
                                    Text("查看足迹地图")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(
                                    Capsule()
                                        .fill(Color.orange)
                                        .shadow(color: Color.orange.opacity(0.4), radius: 10, x: 0, y: 5)
                                )
                            }
                        }
                        
                        actionButton
                    }
                    .padding(.bottom, 40)
                }
                .padding(.horizontal, 24)
            }
            // 隐藏顶部的导航栏空隙，因为我们已经处理了安全区域并让子视图自己处理标题
            .toolbar(.hidden, for: .navigationBar)
        }
    }
    
    @ViewBuilder
    private var statusCard: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(height: 180)
            .overlay(
                VStack(spacing: 16) {
                    if photoManager.isScanning {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.blue)
                        Text("正在后台解析地理坐标...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    } else if photoManager.authorizationStatus != .authorized && photoManager.authorizationStatus != .limited {
                        Image(systemName: "photo.lock")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("需要相册访问权限以生成热力图")
                            .font(.headline)
                    } else {
                        VStack(spacing: 8) {
                            Text("\(photoManager.validPhotos.count)")
                                .font(.system(size: 48, weight: .heavy, design: .rounded))
                                .contentTransition(.numericText()) 
                            Text("张有效足迹照片")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            )
            .shadow(color: .black.opacity(0.05), radius: 15, x: 0, y: 10)
            .animation(.easeInOut, value: photoManager.isScanning)
            .animation(.bouncy, value: photoManager.validPhotos.count)
    }
    
    @ViewBuilder
    private var actionButton: some View {
        Button(action: {
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
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    Capsule()
                        .fill(buttonColor)
                        .shadow(color: buttonColor.opacity(0.4), radius: 10, x: 0, y: 5)
                )
        }
        .disabled(photoManager.isScanning) 
    }
    
    private var buttonTitle: String {
        switch photoManager.authorizationStatus {
        case .notDetermined: return "授权相册访问"
        case .authorized, .limited: return "重新扫描合并轨迹"
        case .restricted, .denied: return "前往设置开启无感授权"
        }
    }
    
    private var buttonColor: Color {
        (photoManager.authorizationStatus == .authorized || photoManager.authorizationStatus == .limited) ? Color.green : Color.blue
    }
}

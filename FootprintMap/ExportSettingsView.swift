import SwiftUI
import Photos

struct ExportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    var playbackController: PlaybackController
    var waypoints: [Waypoint]
    var thumbnailLoader: ThumbnailLoader
    var onStartExport: (VideoExportEngine.ExportConfig) -> Void
    
    @State private var selectedResolution: Resolution = .native
    @State private var includeMusic: Bool = true
    @State private var includeWatermark: Bool = true
    
    enum Resolution: String, CaseIterable, Identifiable {
        case native = "设备分辨率"
        case p1080 = "1080p (FHD)"
        case p2k = "2K (QHD)"
        case p4k = "4K (UHD)"
        
        var id: String { self.rawValue }
        
        var size: CGSize {
            switch self {
            case .native: return UIScreen.main.nativeBounds.size
            case .p1080: return CGSize(width: 1920, height: 1080)
            case .p2k: return CGSize(width: 2560, height: 1440)
            case .p4k: return CGSize(width: 3840, height: 2160)
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                
                VStack(spacing: 0) {
                    Form {
                        Section(header: Text("导出规格").font(.system(size: 13, weight: .medium))) {
                            Picker("分辨率", selection: $selectedResolution) {
                                ForEach(Resolution.allCases) { res in
                                    Text(res.rawValue).tag(res)
                                }
                            }
                            .tint(.orange)
                        }
                        
                        Section(header: Text("影片细节").font(.system(size: 13, weight: .medium))) {
                            Toggle("添加氛围配乐", isOn: $includeMusic)
                                .tint(.orange)
                            Toggle("添加时间地点水印", isOn: $includeWatermark)
                                .tint(.orange)
                        }
                        
                        Section(footer: Text("导出期间请保持屏幕开启，视频将实时录制播放画面。").font(.system(size: 12))) {
                            Button(action: startExport) {
                                HStack {
                                    Spacer()
                                    Text("开始渲染电影")
                                        .fontWeight(.bold)
                                    Spacer()
                                }
                            }
                            .foregroundColor(.orange)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("准备导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
    
    private func startExport() {
        let config = VideoExportEngine.ExportConfig(
            resolution: selectedResolution.size,
            fps: 30,
            includeMusic: includeMusic,
            includeWatermark: includeWatermark,
            watermarkText: "PhotoTrail Journey"
        )
        
        // Dismiss the settings sheet, then trigger export in the parent view
        dismiss()
        
        // Small delay to allow sheet dismissal animation to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            onStartExport(config)
        }
    }
}

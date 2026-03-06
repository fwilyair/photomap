<div align="center">
  <img src="assets/poster.png" alt="FootprintMap Cartographic Memory Poster" width="600"/>
</div>

# FootprintMap (足迹地图)

基于本地相册的无感旅行轨迹记录与可视化呈现工具。

## 简介

FootprintMap 是一款原生的 iOS 应用程序，它通过读取你本地相册中的照片地理位置和关键元数据，利用高阶的空间聚类算法与平滑曲线插值算法，在地图上丝滑重现你的每一次旅行轨迹与驻留足迹。

得益于 Apple 的 `MapKit` 与 `CoreAnimation` 底层硬件加速渲染，应用在密集点位与长途跨越时仍能保持极极高帧率的电影级地图运镜体验。无论是日常走街串巷，还是跨越大陆的长途旅行，FootprintMap 都会让回忆以最优雅、最具质感的方式在你的手心中流转。

## 核心特性

- **📸 本地数据驱动**：完全读取本地图库 (`PHAsset`)，无须后台持续定位，不耗电，绝对保护隐私。
- **🗺️ 智能地理聚类**：采用时间间隔与地理距离双向贪心聚类算法，将海量照片智能折叠为有逻辑的“停留节点 (Waypoints)”。
- **✨ 硬件级轨迹沉浸播放**：
  - 抛弃 CPU 渲染的 `MKOverlayRenderer`，使用 `CAShapeLayer` 结合核心动画，实现 60fps 丝滑抗锯齿画线。
  - **电影级无人机运镜**：根据轨迹密度动态调整镜头高度 (3000m - 2500km)，自动预测前方路线。
- **⏱️ 分段时长过滤**：支持指定时间区间，随时查看某一次单独的旅行回忆。
- **📱 极简浮动 UI**：播放时主动折叠隐藏臃肿面板，极致让位给全屏地图沉浸感。

## 安装与运行

本项目采用 `xcodegen` 管理 Xcode 工程文件，避免 `.xcodeproj` 冲突，提升开发体验。

### 环境依赖

- macOS (含 Xcode 15+)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### 步骤

```bash
# 1. 克隆代码仓库
git clone https://github.com/fwilyair/photomap.git

# 2. 进入项目目录
cd photomap/FootprintMap

# 3. 使用 xcodegen 生成项目配置文件
xcodegen

# 4. 双击打开生成的 .xcodeproj
open FootprintMap.xcodeproj
```

*在 Xcode 中，选择对应的 iOS Simulator 或者 真机，按下 `Cmd + R` 即可运行测试。*

## 快速使用说明

1. 启动应用后，允许访问**所有照片**权限。
2. 应用会自动扫描并统计出拥有 GPS 坐标的照片总数。
3. 点击 **"查看足迹地图"** 进入全屏地图模式。
4. (可选) 点击右上角的筛选按钮，选择你想要的旅行时间段。
5. 在底部的控制面板中，点击 **"播放 (►)"**，即可享受电影级的自动巡航回顾。
6. (高级) 播放期间可以拖动滑动条快进/快退，面板会自动变小。此时点击 **停止 (■)** 可瞬间重置视角与面板。

## 技术架构

- **UI层**: `SwiftUI`
- **地图内核**: `MapKit` 结合 `UIViewRepresentable` 深度定制
- **渲染加速**: `CoreAnimation` (`CAShapeLayer`), 绕过地图重绘瓶颈
- **照片授权**: `Photos` (`PHPhotoLibrary`)
- **曲线插值**: 平滑 Catmull-Rom 样条风格的数学插值法，专为墨卡托投影 (Mercator Projection) 和绝对经纬度进行适配。

## 贡献

欢迎提交 Issue 与 Pull Request，特别是那些关于相机运动参数调整和平滑算法边缘优化上的改进。

## 开源协议

MIT License

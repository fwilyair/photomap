<div align="center">
  <img src="assets/poster.png" alt="FootprintMap Cartographic Memory Poster" width="600"/>
</div>

# FootprintMap (足迹地图)

**唤醒相册，将散落的记忆锚定为永恒的坐标。**

FootprintMap 是一款专为 iOS 设计的极简主义足迹可视化工具。它能够深度挖掘你本地相册中的地理信息，通过电影级的地图运镜和丝滑的轨迹动画，将你过去散落各地的生活碎片，编织成一条跨越时空的记忆曲线。

## ✨ 核心特性

- **🎬 电影级运镜体验**：
  - **Cinema Cruise**：内置智能无人机运镜算法，根据轨迹密度动态调整镜头高度（3,000m - 2,500km）。
  - **60FPS 丝滑渲染**：基于 `CoreAnimation` 与硬件加速，绕过原生 `MapKit` 的渲染瓶颈。
  - **Catmull-Rom 插值**：采用高阶数学模型生成的平滑路径，让轨迹告别生硬线条。
- **🕯️ 极简主义设计 (Editorial Minimalism)**：
  - **动态数字光效**：主界面采用低饱和“破晓余风 (Dawn Ash)”微光渐变。
  - **沉浸式控制面板**：播放时面板自动折叠，极致让位给全屏地图的沉浸感。
  - **零负担体验**：专为 iOS 18+ 优化的 Apple 原生视觉语言。
- **🛡️ 隐私与效率**：
  - **100% 本地运算**：完全读取本地图库 (`PHAsset`)，无须上传任何照片。
  - **增量扫描逻辑**：智能识别上次扫描位置，仅拉取新增足迹，省电且疾速。
  - **离线持久化**：采用加密 JSON 缓存，退出 App 后的下一次打开依然瞬间加载。

## 🛠️ 技术架构

- **UI 框架**: SwiftUI (Swift 5.10+)
- **地图引擎**: MapKit (UIViewRepresentable 深度定制)
- **底层加速**: Core Animation (`CAShapeLayer`)
- **数据源**: PhotoKit (`PHPhotoLibrary`)
- **项目管理**: XcodeGen (告别 `.xcodeproj` 的 Git 冲突)

## 🚀 快速启动

### 准备工作

1. 确保你的 macOS 已安装最新版 Xcode。
2. 安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

   ```bash
   brew install xcodegen
   ```

### 运行步骤

```bash
# 1. 克隆仓库
git clone https://github.com/fwilyair/photomap.git

# 2. 生成项目工程
cd FootprintMap
xcodegen

# 3. 开启回忆
open FootprintMap.xcodeproj
```

## 📖 使用指南

1. **首次点击**：允许访问“所有照片”，App 将瞬间扫描历史坐标。
2. **首页视效**：主屏展示的是经过低饱和渐变处理的“总足迹数”。
3. **漫游记忆**：点击底部胶囊按钮进入地图，点击播放（►）开始自动巡航。
4. **时空筛选**：点击右上角时钟图标，可自由定制想要回顾的具体旅行时段。

## 🤝 贡献与反馈

如果你对地图平滑算法、运镜曲线或视觉系统有更好的想法，欢迎提交 Issue 或 Pull Request。

## 📄 开源协议

MIT License. 保护隐私，致敬回忆。

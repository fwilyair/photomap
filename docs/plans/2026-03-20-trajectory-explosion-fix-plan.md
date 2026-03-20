# Trajectory Explosion Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复轨迹生成中因重合点导致的数值爆炸（长飞线）问题，确保轨迹起止平滑且数值稳定。

**Architecture:** 采用向量外推法（Vector Extrapolation）计算轨迹起止的虚拟辅助点，替换原有的原地复制逻辑，确保 Catmull-Rom 算法的分母永远不为零。

**Tech Stack:** Swift, MapKit (MKMapPoint)

---

### Task 1: 优化 SplineRouteBuilder 数值稳定性

**Files:**
- Modify: `/Users/seven/Downloads/PhotoTrail/FootprintMap/FootprintMap/PhotoMapViews.swift:130-150`

**Step 1: 修改 getT 函数增加安全阈值**
将 `max(a, 0.0001)` 修改为 `max(a, 1.0)`。在 MKMapPoint 坐标系下，1.0 是极小的距离，但足以防止数值抖动。

**Step 2: 实现向量外推逻辑替换复制逻辑**
修改 `buildSmoothSpline` 内部的 `pts` 初始化：
```swift
        // 替换 pts = [mapPoints[0]] + mapPoints + [mapPoints.last!]
        var pts: [MKMapPoint] = []
        let p0 = mapPoints[0]
        let p1 = mapPoints[1]
        // 向前推 25% 距离作为虚拟起点
        let head = MKMapPoint(x: p0.x - (p1.x - p0.x) * 0.25, y: p0.y - (p1.y - p0.y) * 0.25)
        pts.append(head)
        pts.append(contentsOf: mapPoints)
        
        let pn = mapPoints.last!
        let pn_1 = mapPoints[mapPoints.count - 2]
        // 向后推 25% 距离作为虚拟终点
        let tail = MKMapPoint(x: pn.x + (pn.x - pn_1.x) * 0.25, y: pn.y + (pn.y - pn_1.y) * 0.25)
        pts.append(tail)
```

**Step 3: 验证编译通过**
运行：`xcodebuild -project FootprintMap.xcodeproj -scheme FootprintMap -configuration Debug` (或直接在 IDE 检查)。

**Step 4: Commit**
```bash
git add FootprintMap/PhotoMapViews.swift
git commit -m "fix: resolve trajectory explosion by using vector extrapolation for endpoints"
```

---

### Task 2: 边界情况处理与验证

**Files:**
- Modify: `/Users/seven/Downloads/PhotoTrail/FootprintMap/FootprintMap/PhotoMapViews.swift:100-110`

**Step 1: 确保极近距离点被正确过滤**
检查 `SplineRouteBuilder` 顶部的去重逻辑，确保距离过近（< 100m）的点不会堆叠。

**Step 2: 运行项目进行视觉回归**
在模拟器中选择一个只有 2-3 个点的足迹集，观察轨迹线是否依然有“飞线”出现。

**Step 3: Commit**
```bash
git commit -m "test: verify trajectory fix with sparse waypoints"
```

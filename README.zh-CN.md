# MetalFX Movie Player

[日本語](README.md) | **简体中文** | [English](README.en.md)

具备 视频解码 → Metal 纹理 → MetalFX Spatial → 高分辨率显示
管线的 macOS / iOS 视频播放器。

## 源码发布

本仓库提供源代码。macOS 和 iOS 的构建步骤见下文。
目前尚未提供打包的应用程序版本。

## 管线

```
AVPlayer + AVPlayerItemVideoOutput   (VideoToolbox 解码, BGRA + Metal 兼容缓冲)
        │
        ▼
CVMetalTextureCache                  (零拷贝 CVPixelBuffer → MTLTexture)
        │
        ▼
MTLFXSpatialScaler                   (按显示所需的纹素密度放大)
        │
        ▼
Aspect-fit quad + preferredTransform UV 应用 + linear sampler
                                     (向 MTKView drawable 做 1:1 绘制)
```

- 以考虑窗口 backing scale 的**物理像素单位**进行放大，
  因此在 Retina 显示器上低分辨率视频也能以原生分辨率锐利显示
- MetalFX 是放大器(upscaler)，仅当输出尺寸小于输入时才
  直接绘制已解码纹理(downscale 路径，无伪装)
- `preferredTransform` 作为绘制时的 UV 映射应用，
  可正确显示 90°/270° 旋转、翻转及由 transform 产生的变形宽银幕。
  显示宽高比使用 `CMVideoFormatDescriptionGetPresentationDimensions`
  (含像素宽高比与 clean aperture)。
  90° 旋转时缩放器输出会被转置，
  从而保持每显示像素 1 纹素的密度
- 播放失败时错误信息会显示在窗口副标题
- 音频由 AVPlayer 直接播放

## MetalFX 的效果

将 640×360 输入放大 3 倍至 1920×1080 时的对比。
全部使用与 App 相同的 `MTLFXSpatialScaler`(perceptual 模式)生成。
输入素材为 ffmpeg `testsrc2` / `mandelbrot` 生成的合成图案
(无版权限制):

### 文字

![文字放大对比](docs/images/compare_testsrc2_text.png)

### 细节(棋盘格 + 斜边)

![细节放大对比](docs/images/compare_testsrc2_detail.png)

### 分形细线

![分形边缘放大对比](docs/images/compare_mandelbrot_edge.png)

nearest 有明显锯齿，bilinear 模糊，lanczos 虽然锐利但
边缘会残留振铃(ringing)；而 MetalFX 能重建小字号文字和
细微轮廓，锐利地绘制出来。

## 系统要求

- macOS 14 及以上
- Apple Silicon(需要 MetalFX Spatial)

## 从源码运行（开发者）

```sh
swift run MovieFXPlayer [video.mp4]
# 或者
swift build && .build/debug/MovieFXPlayer path/to/video.mp4
```

不带参数运行会打开文件面板。也支持拖放。

## iOS 版

`ios/` 目录下有 iPhone / iPad 版的 Xcode 工程。
与 macOS 版共享相同的 解码 → MetalFX 管线，
`Sources/MovieFXPlayer/MetalFXRenderer.swift` 与 `VideoPlayer.swift`
可直接被 iOS target 编译
(仅通过 `PlayerSeekUpdating` 协议将 seek UI 抽象到平台侧)。

### 功能

- **媒体库**: 以缩略图和时长列表显示已登记的视频。
  文件通过 security-scoped 书签**引用原件**(不复制)。
  仅拖放导入的文件无法引用原件，会保存到 `Documents/Media/`。
  长按行可「接着播放」「加入队列」「从媒体库删除」，
  编辑模式下可排序、删除。原件被删除或移动时显示「找不到文件」
- **队列**: 从媒体库播放时全部项目进入队列，播完自动前进。
  队列画面(右上角列表按钮)可跳转、排序、删除、清空。
  带上一首/下一首跳过按钮(上一首仅在播放位置 3 秒内回到上一项，
  否则回到开头)
- **循环**: 重复按钮在 关 → 单集 → 全部 之间循环
- **PiP**: 标准画中画(进入后台时自动开始)。
  PiP 窗口直接输出解码后的画面(不应用 MetalFX)
- **后台播放**: `UIBackgroundModes=audio` + Now Playing +
  远程命令(播放/暂停/±10秒/前后曲目/进度)+
  中断(来电等)处理，可从锁屏操作
- **MetalFX 开关**: 顶栏 FX 按钮(macOS 为 X 键 / View 菜单)。
  关闭时不创建缩放器，直接绘制已解码纹理，
  状态显示 `direct (MetalFX off)`
- **续播位置**: 按文件保存播放位置，下次打开时恢复
  (看完的项目会重置)
- **持久化**: 媒体库、队列、循环模式保存在
  `Application Support/` 的 JSON 中

### 系统要求

- iOS / iPadOS 17 及以上
- 支持 MetalFX Spatial 的设备。模拟器没有 MetalFX.framework，
  运行会显示不支持画面
- 安装到真机需要设置 Apple ID / Development Team

### 构建

```sh
open ios/MovieFXPlayerIOS.xcodeproj
# 工程由 XcodeGen 生成。需要重新生成时:
cd ios && xcodegen
```

### 画面结构

- 媒体库画面(起点)→ 点按视频进入全屏播放器
- 播放器顶栏: 关闭 / 打开 / 文件名 + 管线状态 /
  FX / PiP / 队列
- 播放器底栏第 1 行: 上一首 / 播放·暂停 / 下一首 / 进度 / 时间 / 速度
- 播放器底栏第 2 行: 静音 / 音量 / 循环 / 隐藏界面
- 点按切换控制显示(播放中 4 秒自动隐藏)
- 硬件键盘(iPad 等): 与 macOS 版相同的按键绑定 +
  X(MetalFX)、N/P(下一首/上一首)

## 操作

| 按键 | 动作 |
|---|---|
| Space | 播放/暂停 |
| ← / → | ±5秒跳转(Shift 为 ±30秒) |
| ⌘← / ⌘→ | 跳到开头 / 结尾 |
| , / . | 后退 / 前进 1 帧(暂停并逐帧) |
| ↑ / ↓ | 音量 |
| [ / ] | 降低 / 提高播放速度(0.5×〜2×) |
| = | 恢复 1× 速度 |
| M | 静音切换 |
| F / ⌃⌘F | 全屏 |
| L | 循环播放切换 |
| O / ⌘O | 打开文件 |
| 双击 | 全屏 |

窗口底部有控制条(播放按钮、进度条、时间显示、
播放速度弹出菜单、静音、音量滑块、全屏按钮)。
同样的操作也可从 Playback / View 菜单执行。
播放速度、音量、静音在暂停中修改或切换文件后都会保持。
播放到结尾暂停后再按播放会从头重播。
副标题显示 `输入分辨率 → 输出分辨率 MetalFX 倍率` 的管线状态。

## 测试

```sh
swift test
```

- `ScalerTests`: 在 GPU 上验证 MTLFXSpatialScaler 的 64×64 → 256×256(4x)放大
- `DecodePipelineTests`: 验证 AVPlayerItemVideoOutput → CVMetalTexture → MTLTexture 的实际解码路径
- `QuadCoverageTests`: 验证 aspect-fit 矩形外(黑边区域)没有绘制泄漏
- `TransformMappingTests`: 验证应用 preferredTransform 的 UV 映射(含旋转时的转置缩放器输出，有 GPU 渲染)

## 限制

- 解码输出为 BGRA8(不支持 HDR 色调映射。如需 HDR 可扩展为
  `kCVPixelFormatType_64RGBALE` + `rgba16Float` + `colorProcessingMode = .hdr`)

## 许可证

MIT License — [LICENSE](LICENSE)

`Tests/MovieFXPlayerTests/Resources/testclip.mp4` 以及
`docs/images/` 中的对比图像是用 ffmpeg `testsrc2` / `mandelbrot`
生成的合成素材，不包含任何第三方版权内容。

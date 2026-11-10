# MetalFX Movie Player

[日本語](README.md) | [简体中文](README.zh-CN.md) | **English**

A macOS / iOS video player with a pipeline of
video decode → Metal texture → MetalFX Spatial → high-resolution display.

## Source Distribution

This repository distributes source code. See the macOS and iOS build instructions below.
No packaged application releases are available yet.

## Pipeline

```
AVPlayer + AVPlayerItemVideoOutput   (VideoToolbox decode, BGRA + Metal-compatible buffers)
         │
         ▼
CVMetalTextureCache                  (zero-copy CVPixelBuffer → MTLTexture)
         │
         ▼
MTLFXSpatialScaler                   (upscale to the texel density needed for display)
         │
         ▼
Aspect-fit quad + preferredTransform UV + linear sampler
                                      (1:1 draw into MTKView drawable)
```

- Upscales in **physical pixels**, taking the window's backing scale into account,
  so low-resolution video appears sharp at native resolution on Retina displays
- MetalFX is an upscaler, so when the output size is smaller than the input,
  the decoded texture is drawn directly (downscale path, no faking)
- `preferredTransform` is applied as a UV map at draw time, correctly rendering
  90°/270° rotations, flips, and anamorphic content derived from transforms.
  Display aspect uses `CMVideoFormatDescriptionGetPresentationDimensions`
  (including pixel aspect ratio and clean aperture).
  On 90° rotation the scaler output is transposed, preserving a density of
  1 texel per display pixel
- Errors are shown in the window subtitle when playback fails
- Audio is played as-is by AVPlayer

## MetalFX Effect

Comparison of 640×360 input upscaled 3× to 1920×1080.
All images were generated with the same `MTLFXSpatialScaler` (perceptual mode) as the app.
The source material is a synthetic pattern generated with ffmpeg's
`testsrc2` / `mandelbrot` (free of copyright restrictions):

### Text

![Text upscaling comparison](docs/images/compare_testsrc2_text.png)

### Fine detail (checkerboard + diagonal edges)

![Detail upscaling comparison](docs/images/compare_testsrc2_detail.png)

### Thin fractal lines

![Fractal edge upscaling comparison](docs/images/compare_mandelbrot_edge.png)

nearest shows jaggies, bilinear is blurry, and lanczos is sharp but
leaves ringing on edges, whereas MetalFX reconstructs small text and
fine contours and renders them sharply.

## Requirements

- macOS 14 or later
- Apple Silicon (MetalFX Spatial required)

## Running and Building from Source (Developers)

```sh
swift run MovieFXPlayer [video.mp4]
# or
swift build && .build/debug/MovieFXPlayer path/to/video.mp4
```

Run without arguments to open a file panel. Drag & drop is also supported.

Run `scripts/build-macos-app.sh` to build an app bundle.
It produces `.build/app/MovieFX Player.app`.
Use `scripts/package-macos-release.sh` to generate the distribution DMG, ZIP,
and SHA-256 list; output goes to `.build/releases/<version>/`.

## iOS Version

`ios/` contains the Xcode project for the iPhone / iPad version.
It shares the same decode → MetalFX pipeline as the macOS version, and
`Sources/MovieFXPlayer/MetalFXRenderer.swift` and `VideoPlayer.swift` compile
as-is for the iOS target (only the seek UI is abstracted behind the
`PlayerSeekUpdating` protocol).

### Features

- **Library**: Lists registered videos with thumbnails and durations.
  Files are referenced from their **original location** via security-scoped bookmarks (no copying).
  Only files imported by drag & drop cannot reference the original, so they are kept in `Documents/Media/`.
  Long-press a row for "Play Next", "Add to Queue", and "Remove from Library";
  edit mode allows reordering and deletion. If the original file is deleted or moved, a "Not Found" indicator appears.
- **Queue**: Playing from the library enqueues all items and advances automatically at the end.
  The queue screen (list button at top right) allows jumping, reordering, deleting, and clearing.
  Previous/next skip buttons are included (the previous button only goes to the previous item within
  the first 3 seconds of playback; otherwise it returns to the start)
- **Loop**: The repeat button cycles off → one → all
- **PiP**: Standard Picture in Picture (starts automatically when entering the background).
  The PiP window shows the decoded video directly (MetalFX is not applied)
- **Background playback**: `UIBackgroundModes=audio` + Now Playing +
  remote commands (play/pause/±10s/prev-next track/seek) +
  interruption (phone call, etc.) handling, controllable from the lock screen
- **MetalFX on/off**: The FX button in the top bar (on macOS, the X key / View menu).
  When off, the scaler is not created and the decoded texture is drawn directly,
  with the status showing `direct (MetalFX off)`
- **Resume position**: Saves the playback position per file and restores it on next open
  (fully played items are reset)
- **Persistence**: The library, queue, and repeat mode are stored as JSON
  in `Application Support/`

### Requirements

- iOS / iPadOS 17 or later
- Devices supporting MetalFX Spatial. The simulator does not have MetalFX.framework,
  so running it shows an unsupported screen
- Installing to a physical device requires an Apple ID / Development Team configuration

### Build

```sh
open ios/MovieFXPlayerIOS.xcodeproj
# The project is generated with XcodeGen. To regenerate:
cd ios && xcodegen
```

### Screen Structure

- Library screen (starting point) → tap a video for the full-screen player
- Player top bar: close / open / file name + pipeline status /
  FX / PiP / queue
- Player bottom bar, row 1: previous / play·pause / next / seek / time / speed
- Player bottom bar, row 2: mute / volume / loop / hide chrome
- Tap to toggle control visibility (auto-hides after 4 seconds during playback)
- Hardware keyboard (iPad, etc.): the same key binds as the macOS version +
  X (MetalFX), N/P (next/previous)

## Controls

| Key | Action |
|---|---|
| Space | Play/pause |
| ← / → | Seek ±5 seconds (with Shift, ±30 seconds) |
| ⌘← / ⌘→ | Jump to start / end |
| , / . | Step back / forward 1 frame (pause and step) |
| ↑ / ↓ | Volume |
| [ / ] | Decrease / increase playback speed (0.5× to 2×) |
| = | Reset playback speed to 1× |
| M | Toggle mute |
| F / ⌃⌘F | Fullscreen |
| L | Toggle loop playback |
| O / ⌘O | Open file |
| Double-click | Fullscreen |

A control bar is at the bottom of the window (play button, seek bar, time display,
playback speed popup, mute, volume slider, fullscreen button).
The same actions are available from the Playback / View menus.
Playback speed, volume, and mute are preserved when changed while paused and across file switches.
Pressing play after pausing at the end replays from the beginning.
The subtitle shows the pipeline status as `input resolution → output resolution MetalFX ratio`.

## Tests

```sh
swift test
```

- `ScalerTests`: Verifies a 64×64 → 256×256 (4x) upscale by MTLFXSpatialScaler on the GPU
- `DecodePipelineTests`: Verifies the actual decode path of AVPlayerItemVideoOutput → CVMetalTexture → MTLTexture
- `QuadCoverageTests`: Verifies there is no draw leakage outside the aspect-fit rectangle (letterbox area)
- `TransformMappingTests`: Verifies the UV mapping with preferredTransform applied (including the transposed scaler output on rotation, with GPU rendering)

## Limitations

- Decode output is BGRA8 (no HDR tone mapping support. For HDR, extend to
  `kCVPixelFormatType_64RGBALE` + `rgba16Float` + `colorProcessingMode = .hdr`)

## License

MIT License — [LICENSE](LICENSE)

`Tests/MovieFXPlayerTests/Resources/testclip.mp4` and the comparison images in
`docs/images/` are synthetic materials generated with ffmpeg `testsrc2` / `mandelbrot`,
and contain no third-party copyrighted content.

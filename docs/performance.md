# Performance Guide

How to measure, profile, and optimize latency in Daylight Mirror.

## Architecture

```
Mac                              USB                 Daylight DC-1
┌──────────────────┐         ┌───────┐         ┌──────────────────┐
│ SCStream capture │──BGRA──▶│       │         │                  │
│ vImage greyscale │──grey──▶│       │  TCP    │ LZ4 decompress   │
│ LZ4 delta compress│─bytes─▶│  USB  │────────▶│ XOR delta apply  │
│                  │         │       │         │ NEON grey→RGBX   │
│                  │◀──ACK───│       │◀───ACK──│ ANativeWindow    │
└──────────────────┘         └───────┘         └──────────────────┘
```

Every frame follows this pipeline:

1. **Capture** — SCStream delivers a BGRA pixel buffer at 30fps
2. **Greyscale** — vImage SIMD converts BGRA→grey (1 byte/pixel)
3. **Compress** — LZ4 compresses either a full keyframe or XOR delta against the previous frame
4. **Transmit** — TCP over USB sends `[DA 7E][flags][seq][len][payload]`
5. **Decompress** — Android LZ4-decompresses into a buffer
6. **Delta apply** — NEON XOR reconstructs the current frame (skip for keyframes)
7. **Blit** — NEON expands grey→RGBX (4 bytes/pixel) into ANativeWindow buffer
8. **Display** — `ANativeWindow_unlockAndPost` presents to screen

Android sends an ACK `[DA 7A][seq]` back to Mac after step 5 (after decode, before blit). The Mac uses this to measure RTT and track inflight frames for backpressure.

## Measuring Latency

### Mac-side

```bash
# One-shot snapshot
daylight-mirror latency

# Live monitoring (refreshes every 2s)
daylight-mirror latency --watch
```

Output:
```
FPS:              28.5
Clients:          1
Total frames:     837
Skipped frames:   12

Mac processing:
  Greyscale:      0.4 ms
  LZ4 compress:   1.5 ms
  Jitter:         1.7 ms

Round-trip (Mac → Daylight → Mac):
  Average:        23.5 ms
  P95:            44.3 ms

Est. one-way:     ~11.8 ms
```

### Android-side

```bash
adb logcat -s DaylightMirror
```

Output:
```
FPS: 28.5 | recv: 20.0ms | lz4: 3.0ms | delta: 4.6ms | neon: 5.6ms | vsync: 0.7ms | 294KB delta | drops: 1 | total: 827
```

### What each metric means

| Metric | Source | What it measures |
|--------|--------|------------------|
| **FPS** | Both | Frames actually processed per second |
| **Greyscale** | Mac | vImage BGRA→grey conversion |
| **LZ4 compress** | Mac | Compression time (keyframe or delta) |
| **Jitter** | Mac | Deviation from expected 33ms frame interval |
| **RTT avg/P95** | Mac | Time from `broadcast()` to ACK received |
| **Skipped frames** | Mac | Frames dropped by backpressure (inflight > 1) |
| **recv** | Android | Time from start of `read()` to payload complete — mostly idle wait, not a bottleneck |
| **lz4** | Android | LZ4 decompression |
| **delta** | Android | NEON XOR delta apply |
| **neon** | Android | Grey→RGBX pixel expansion (the expensive blit step) |
| **vsync** | Android | Time in `ANativeWindow_unlockAndPost` after buffer is written |
| **drops** | Android | Sequence gaps (frames lost in transit) |

### Machine-readable

```bash
# Status file updated every 5s (CLI daemon only)
cat /tmp/daylight-mirror.status

# Control socket query (works with GUI app too)
daylight-mirror latency
```

## Current Baseline (v1.3, 1600x1200 Sharp)

| Stage | Time | % of pipeline |
|-------|------|---------------|
| Capture delay (avg) | 16.7 ms | 47% |
| Mac processing | 1.9 ms | 5% |
| USB transit | ~1.5 ms | 4% |
| LZ4 decompress | 3.0 ms | 9% |
| Delta apply | 4.6 ms | 13% |
| NEON grey→RGBX | 5.6 ms | 16% |
| Vsync wait | 0.7 ms | 2% |
| USB return (ACK) | ~1.5 ms | 4% |
| **Total** | **~35.5 ms** | |

Measured RTT: 23.5ms avg, 44.3ms P95 (ACK sent after decode, before blit).

## Where Time Is Spent

### Capture delay — 16.7ms (47%)

At 30fps, a screen change waits on average half a frame interval (16.7ms) before SCStream captures it. This is the single largest contributor and is inherent to 30fps.

**To reduce**: Increase capture FPS. But Android currently needs ~14ms to render each frame, so 60fps causes ~50% frame drops and visible stutter. This only becomes viable once Android render time drops below ~8ms.

### NEON grey→RGBX — 5.6ms (16%)

The Android blit expands 1 byte/pixel greyscale to 4 bytes/pixel RGBX using ARM NEON SIMD (`vst4q_u8`). At 1600x1200 that's writing 7.68MB of pixel data per frame. This is memory-bandwidth bound.

**To reduce**: See [R8_UNORM](#r8_unorm-single-channel-surface) and [GL shader pipeline](#gl-shader-pipeline) below.

### Delta apply — 4.6ms (13%)

NEON XOR of 1.92M bytes. Also memory-bandwidth bound (`veorq_u8` on 16 bytes/iteration).

**To reduce**: This is already optimal for CPU. Only way to improve is reducing pixel count (lower resolution) or doing the XOR in a GPU shader.

### LZ4 decompress — 3.0ms (9%)

LZ4 is already one of the fastest decompressors. Delta frames compress well (~300KB), keyframes less so (~1MB).

**To reduce**: Marginal. Could try LZ4 HC on Mac side for better compression ratios (smaller payloads → faster decompress), but HC compression is slower.

### Mac processing — 1.9ms (5%)

Already fast. vImage SIMD greyscale (0.4ms) + LZ4 compress (1.5ms).

## Optimization Opportunities

### GL shader pipeline

**Expected savings: ~5ms (eliminates NEON blit)**

Replace `ANativeWindow_lock` + CPU blit with an EGL/OpenGL pipeline:

1. Create an EGL context and bind to the ANativeWindow surface
2. Upload decompressed greyscale as a `GL_LUMINANCE` or `GL_R8` texture
3. Fragment shader expands grey→RGBX: `gl_FragColor = vec4(grey, grey, grey, 1.0)`
4. `eglSwapBuffers` presents

The GPU handles grey→RGBX expansion in parallel with zero CPU memory bandwidth cost. Also enables `eglSwapInterval(0)` to skip vsync blocking.

**Complexity**: Medium. Requires EGL setup (~100 lines), shader compilation, and texture upload per frame. The texture upload (`glTexImage2D`) itself takes time but should be faster than the CPU NEON expansion since GPU memory controllers are optimized for bulk transfers.

### Double-buffer decompress and blit

**Expected savings: ~5ms (overlaps blit with next frame's recv)**

Current pipeline is serial:
```
[recv][lz4][delta][blit]  [recv][lz4][delta][blit]
```

With double buffering:
```
[recv][lz4][delta][blit]
                  [recv][lz4][delta][blit]
```

While the current frame is being blitted, the next frame's recv+decompress happens in parallel. Requires two copies of `g_current_frame` and a mutex/condition variable for synchronization.

**Complexity**: Medium. Adds a second thread and synchronization, but the logic is straightforward producer-consumer.

### Lower resolution

At 1024x768 (Comfortable), pixel count drops from 1.92M to 786K (2.4x less). Expected per-frame savings:
- NEON blit: 5.6ms → ~2.3ms
- Delta apply: 4.6ms → ~1.9ms
- LZ4 decompress: 3.0ms → ~1.5ms

Total Android render: ~14ms → ~6ms. This would make 60fps viable.

## What We Tried and Why It Didn't Work

### R8_UNORM single-channel surface

**Goal**: Write 1 byte/pixel directly to ANativeWindow instead of 4 bytes/pixel RGBX.

`ANativeWindow_setBuffersGeometry(window, w, h, AHARDWAREBUFFER_FORMAT_R8_UNORM)` returns success, and `ANativeWindow_lock` works, but SurfaceFlinger cannot composite single-channel surfaces — the display shows blank. This is an Android compositor limitation, not a hardware limitation.

The code is still in `mirror_native.c` behind `g_r8_supported = 0` if a future Android version adds support.

### 60fps capture

**Goal**: Halve capture delay from 16.7ms to 8.3ms.

At 60fps, Mac sends frames every 16.7ms but Android needs ~14ms to render each one. The frame-skip logic drops ~50% of frames, causing the cursor to visibly jump instead of moving smoothly. Smooth 28fps is perceptually better than choppy 28fps-with-gaps.

Only viable once Android render time drops below ~8ms (e.g., after GL shader pipeline + lower resolution).

### queueDepth 1

**Goal**: Reduce SCStream buffering delay.

`SCStreamConfiguration.queueDepth = 1` causes SCStream to stall frame delivery entirely. The first frame renders but no subsequent frames arrive. queueDepth 3 (default) works reliably.

## Protocol Reference

### Frame packet
```
[0xDA 0x7E] [flags:1] [seq:4 LE] [len:4 LE] [LZ4 payload]
```
- `flags` bit 0: 1=keyframe (full frame), 0=delta (XOR with previous)
- `seq`: monotonically increasing frame sequence number
- `len`: byte length of LZ4 payload

### ACK packet
```
[0xDA 0x7A] [seq:4 LE]
```
Sent by Android after decompressing and applying the frame (before blit). Used by Mac for RTT measurement and inflight backpressure.

### Command packet
```
[0xDA 0x7F] [cmd:1] [value:1]
```
Mac→Android control commands (brightness, warmth, backlight, resolution).

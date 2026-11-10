# Experimental muxless native-Zink presentation profiling

Base: HighDelay/nvidia-macos-driver-nvk main @ `2e62ecc72379b0ad8d164e9edd0d1a12fa56eaac` (2026-11-10).

This branch is an **opt-in research prototype**, not a validated performance optimization.

- With `NVKZINK_PROFILE=1`, records native presentation CPU wall-clock timings every 120 frames: nextDrawable, Mesa blit, render finish, NVK import/command setup, queue submission, fence wait, and publication/retirement.
- With `NVKZINK_DRAWABLE_DEVICE=display`, asks CoreGraphics for the Metal GPU driving the window's display and assigns it to the window's CAMetalLayer. NVK *rendering* remains on NVIDIA. Compatibility, correctness, and speed are unknown.
- Default device selection and synchronization behavior remain unchanged. No Fence, IOSurface locking or CPU/GPU safety check is removed.
- Log: `~/Library/Logs/NVKZinkProfile-<PID>.log` (when enabled).
- Neither this source nor the experimental AMD drawable path has been compiled or tested on the target Mac. Test only against staged, matching libraries and a standalone probe; do not overwrite working system libraries.
- This work is separate from the independently planned GPU-local staging, buffering and async copies; none are implemented here.

Reference design: [NVIDIA egl-wayland2](https://github.com/NVIDIA/egl-wayland2/blob/main/src/wayland/wayland-swapchain.c); HighDelay's existing Stremio IOSurface synchronization / staging is documented in `docs/ZINK-STREMIO-SYNCHRONIZATION.md`.

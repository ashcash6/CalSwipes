# Phase 3 — photo capture and on-device pipeline scaffolding

The app now opens a camera flow from a fresh published menu, captures an upright photo, lets the user review/retake it, and runs an on-device pipeline interface. The production path explicitly reports missing analysis models. It does not claim food identification or portion measurement.

## What is implemented

- Camera authorization, denied/restricted access UI, portrait preview, still capture, interruption handling and retry.
- Camera configuration/start/stop on a serial queue; double-capture suppression and retained capture delegates.
- Orientation normalization and bounded 1600-pixel image preparation. Re-encoded JPEGs omit source EXIF/GPS dictionaries.
- In-memory photo review, retake, processing status, cancellation, error/missing-model state and result rendering.
- Immutable menu/revision and preselection snapshot for each scan. Expired or wrong-day menus cannot begin analysis.
- Four stage interfaces: segmentation, menu matching, metric portions and nutrition arithmetic. Unknown matches, inconsistent masks, nonfinite values and absent depth stop the pipeline instead of producing a total.
- A CoreML runner with bundled-model loading, feature-contract checks, serial prediction, one-model cache and per-prediction timing.
- A separately labeled **Debug-only** example result path. It uses preselected menu items at one source serving each, never examines the pixels and has no confidence range.

## Current expected behavior

1. Sign in, select a hall/meal and load a fresh published menu.
2. Optionally preselect expected foods, then tap **Photograph meal**.
3. Allow camera access, frame the full plate and tap **Take photo**.
4. Review the picture or retake it. **Analyze on this iPhone** currently returns **Analysis unavailable**, because real segmentation/classification/depth stages have not been installed.
5. In a Debug build, **Preview example results** shows a clearly labeled example using the preselected items. In Release, that button and implementation are not compiled.
6. Close the flow to discard the photo. Nothing is logged, uploaded or written to HealthKit.

Use a physical iPhone for camera acceptance checks. An iPhone simulator can build/run the shell and unit tests, but has no promised rear-camera feed. Tests construct synthetic images in memory; the runtime app does not replace failed camera access with a fake photo.

## Files

```text
BerkeleyPlate/Camera/
  CameraService.swift    Capture lifecycle and delegates
  CameraPreview.swift    AVCaptureVideoPreviewLayer bridge
  CapturedPhoto.swift    Upright pixels, metadata removal and photo hash
BerkeleyPlate/Inference/
  ScanPipeline.swift    Stage contracts, validation, missing-stage implementations, demo
  CoreMLRuntime.swift   Generic CoreML execution and diagnostic image adapter
BerkeleyPlate/Scan/
  ScanController.swift  Cancel-safe scan state with generation checks
  ScanScreen.swift      Capture/review/progress/results UI
Tools/
  export_smoke_model.py       Untrained diagnostic converter
  requirements-models.txt     Isolated conversion dependencies
Tests/
  CaptureTests.swift         Orientation/metadata preparation
  PipelineTests.swift        Pipeline failure gates and nutrition arithmetic
  ScanControllerTests.swift  Cancellation, retake and memory-state cleanup
  CoreMLRuntimeTests.swift   Missing model and optional real CoreML smoke inference
```

No new iOS runtime packages or backend endpoints were added. Frameworks used by this phase are AVFoundation, CoreGraphics, CoreML, CoreVideo, ImageIO, UniformTypeIdentifiers, Foundation, Combine and SwiftUI.

## Verification status

- All **20 Swift source/test files** passed a tree-sitter Swift syntax parse.
- The Python conversion script passed syntax compilation.
- The XCTest suite now defines **18 test methods** in a Debug build. These have **not run** in this Windows environment. The actual CoreML test skips explicitly when its diagnostic model has not been generated; the included Mac CI workflow generates it first.
- Xcode SDK type-checking, UI rendering, capture hardware, interruption behavior, real model conversion/inference and physical-device latency/memory are **not verified here**.
- The backend was not changed in this phase, so its previously passing 38-test suite was not rerun. Its Phase 2 report remains the record of that execution.

Syntax parsing is not a substitute for an Xcode build. Run the [Mac setup](README.md) and [CoreML diagnostic instructions](MODEL_INTEGRATION.md), then the acceptance checks below before treating Phase 3 as device-verified.

## Physical-device acceptance checklist

1. Build Debug on an iOS 17+ supported iPhone; use a real, fresh menu and configured Apple account.
2. Deny camera permission. Confirm a clear Settings path and no capture attempt. Allow permission and return; preview should start.
3. Capture portrait meals, including with the phone rotated before returning to portrait. Confirm the reviewed image is upright and contains the same food as the preview (the preview is aspect-fill; the reviewed still shows its full frame).
4. Tap capture rapidly; verify only one capture is active. Background/foreground during preview and capture; confirm session recovery and no late photo overwriting a retake.
5. Review, retake and close repeatedly. Use Instruments to check camera session release and memory recovery. Review images are downsampled; no full-resolution image persistence is intended.
6. Try the production Analyze path with models absent; verify that no calorie estimate appears. Preview the Debug example and confirm its label and lack of estimated confidence. Build Release and confirm the demo button is absent.
7. Cancel processing and close the flow; verify late task completion cannot resurrect results. A native CoreML call may finish before cooperative cancellation takes effect; its outputs are discarded and temporary memory is released when the call returns.
8. Enable airplane mode after downloading the menu; capture/review should still work. A missing/expired menu must not start a new scan.
9. Inspect network traffic and Photos: no image requests, photo-library writes or HealthKit writes should occur. Camera access should stop on leaving the flow.
10. Run the diagnostic model on an actual iPhone and record elapsed time plus Instruments peak memory. Those measurements validate plumbing only, not food recognition accuracy.

## Scope carried forward

Phase 4 must source/license and export a real segmentation model, implement its model-specific adapter and validate masks on-device. Stage B needs image/text embedding adapters and menu matching. Stage C must extend capture to supply synchronized calibrated metric depth. The current `CapturedPhoto.hasMetricDepth` is deliberately always false; selecting a two-camera iPhone or bundling a model does not change it. No physical baseline table, tray scale, plate-diameter scale or learned monocular scale is assumed.

Model downloading and durable deferred processing, item/portion corrections, real calibrated confidence bounds, meal history, HealthKit and release compliance remain later phases. Photos in this phase are transient in-memory data, not a persistent queue. No pretrained weights are included or claimed to have been converted.

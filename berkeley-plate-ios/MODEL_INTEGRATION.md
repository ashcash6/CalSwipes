# CoreML integration contract and diagnostic conversion

`CoreMLRuntime` remains the diagnostic loader/predictor. Phase 4 provides a separate trained `MobileSAM` adapter and guided mask UI; see [Phase 4](PHASE4.md) for its contract, provenance and conversion commands. Adding an arbitrary `.mlpackage` will not activate food analysis. The nutrition pipeline remains gated until classification and metric depth are implemented.

## Run the untrained diagnostic conversion on a Mac

The diagnostic computes the per-pixel average of RGB channels. It has **no learned food knowledge**. It only tests image input, an ML Program, tensor output and timing in the same runtime that future adapters can use.

From this iOS project directory with Python 3.11:

```sh
python3.11 -m venv .model-venv
source .model-venv/bin/activate
python -m pip install -r Tools/requirements-models.txt
python Tools/export_smoke_model.py --output Tests/Models/PlateSmoke.mlpackage
xcodegen generate
xcrun simctl list devices available
xcodebuild test \
  -project BerkeleyPlate.xcodeproj \
  -scheme BerkeleyPlate \
  -destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID' \
  CODE_SIGNING_ALLOWED=NO
```

For actual device inference, choose your signed physical iPhone test destination in Xcode and run the tests there. An unsigned simulator test does not establish iPhone latency or memory performance.

The pinned diagnostic toolchain is PyTorch 2.7.0, coremltools 8.3.0 and NumPy 1.26.4. It is isolated from backend dependencies. The converter uses `torch.jit.trace`, `ct.ImageType`, ML Program format, an iOS 17 minimum and fp16 compute precision. This script was syntax-checked here, but the conversion was not executed on this Windows host.

The generated artifact belongs to **the test target only** under `Tests/Models`; Xcode compiles it to `PlateSmoke.mlmodelc`. It is not included in the production app target. The generated model package is ignored by Git. CI regenerates it on macOS before creating the Xcode project.

Diagnostic contract:

| Feature | Type | Shape/meaning |
| --- | --- | --- |
| `image` | CoreML image | RGB, 256 × 256; input scaled by 1/255 in the converted model |
| `luma` | Float32 multi-array | `[1, 1, 256, 256]`, channel mean in approximately 0…1 |

`ImageTensor` uses a BGRA pixel buffer and aspect-fit black letterboxing for this diagnostic. Its transforms are not automatically appropriate for future segmentation or embedding models. The smoke test supplies an all-white square and checks the output shape and center value. It does not validate spatial mask alignment or recognition.

## Stage contracts

- `Segmenting`: consumes the prepared, upright photo and returns food masks plus an optional plate mask. Region bounds use a top-left normalized coordinate system in that prepared photo. Masks are probabilities in 0…1 within the supplied region; each adapter must map model coordinates explicitly. The plate mask is not a scale reference.
- `MenuClassifying`: receives regions, photo, the exact menu snapshot and optional expected item IDs. An unmatched region has `menuItemId: nil`; it must never be forced into a menu choice. Similarity is a cosine score, not a calibrated probability.
- `PortionEstimating`: receives identified regions and capture context. It cannot run until capture supplies actual metric depth. RGB capture in Phase 3 supplies none, so the production orchestrator stops before this stage.
- `NutritionMath`: multiplies published per-serving macros and propagates supplied lower/upper portion bounds, rejecting unknown or nonfinite values. Those bounds are not statistical confidence intervals until Stage C calibration establishes their meaning.

`ScanPipeline` validates stage outputs and checks cancellation between stages. `CoreMLRuntime` validates feature names/types and input constraints before calling `prediction(from:)`, checks cancellation before/after, and caches one model per runtime instance. A running synchronous CoreML call is not forcibly interrupted. Peak memory, warm/cold latency and Neural Engine placement require actual device profiling; no timings have been invented.

## Pretrained-model work still required

Phase 4 supplies pinned pretrained MobileSAM packages, learned prompt weights and a source conversion recipe. On-device execution and quality/performance acceptance remain pending. MobileCLIP classification and depth/portion work remain later phases. This grayscale diagnostic is not a substitute for segmentation validation.

References: Apple's [PyTorch conversion workflow](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html), [model input/output types](https://apple.github.io/coremltools/docs-guides/source/model-input-and-output-types.html), [MLModelConfiguration](https://developer.apple.com/documentation/coreml/mlmodelconfiguration) and [feature validation](https://developer.apple.com/documentation/coreml/mlfeaturedescription/isallowedvalue(_:)).

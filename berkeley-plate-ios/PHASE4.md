# Phase 4 — guided segmentation implementation

This build bundles trained MobileSAM CoreML encoder/decoder packages and implements tap-guided plate and food outlines. **Phase 4 is not accepted as working on-device yet:** authoring and checks ran on Windows; Xcode, CoreML execution, iPhone latency/memory and real-plate mask quality remain unverified.

## Try it on an iPhone

Follow README.md to configure your Apple team, App ID and HTTPS backend. The models are already included; no conversion or model download is required for the normal build.

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig
# Set your team, bundle ID and backend URL in Local.xcconfig.
xcodegen generate
open BerkeleyPlate.xcodeproj
```

Run on a supported iPhone. Sign in, load today's menu, choose Photograph meal and take a photo. Leave Plate selected, tap inside the plate and inspect the orange mask. Add positive taps or turn on exclusion for negative taps. Try another outline if needed, then Keep plate outline. Switch to Food, outline each food and keep it. Kept plate/food masks appear blue/green; remove mistaken food outlines or replace the plate. Nine taps per outline and eight saved foods are supported. Close/retake discards the image, masks and embedding; nothing is uploaded or logged.

MobileSAM is promptable, class-agnostic segmentation. It does not recognize plate, food or distinct dish identities. The user assigns roles and confirms boundaries. Automatically treating every SAM proposal as food would incorrectly count plate/table/garnish regions. This guided workflow is the practical interim alternative; automatic food-instance selection requires recognition/filtering and evaluation. Overlapping/touching foods and duplicate selections still require review; saved masks do not yet enter a nutrition calculation.

## Files and dependencies

```text
BerkeleyPlate/Inference/MobileSAM.swift       Models, prompt encoding, image embedding cache
BerkeleyPlate/Inference/SAMGeometry.swift     RGB normalization, transforms, mask decoding
BerkeleyPlate/Scan/RegionPhotoView.swift      Photo, masks and positive/negative taps
BerkeleyPlate/Scan/ScanController.swift       Prompt/candidate/confirmation state, cancellation
BerkeleyPlate/Scan/ScanScreen.swift           Guided plate and food outline controls
BerkeleyPlate/Resources/Models/              Two pretrained packages, learned prompt weights
BerkeleyPlate/Resources/Licenses/            Apache-2.0 licenses and attribution
Tests/SegmentationTests.swift                Geometry, padding, RGB/orientation, parity, runtime
Tests/prompt-reference.json                  Official PyTorch prompt-encoder fixture
Tools/model-lock.json                        Revisions, SHA-256 hashes and model contracts
Tools/verify_models.py                       Offline integrity and interface verification
Tools/export_mobilesam.py                    Source rebuild, trace and parity checks
Tools/requirements-mobilesam.txt             Pinned Mac conversion environment
```

No third-party iOS library is added. CoreML uses `.all` compute units. Python/PyTorch/coremltools are development-only. Bundled model resources total **24,461,929 bytes (23.33 MiB)** before compilation/packaging; this is not installed size or peak memory.

The MobileSAM actor serializes off-main model work. It releases the encoder after computing the image embedding; the decoder and embedding remain cached for later taps on that photo. A synchronous CoreML prediction cannot be forcibly interrupted. Cancellation is checked around inference; a generation guard discards old results. Release waits for in-flight work. No plate dimension or tray scale is assumed.

Input is upright RGB resized so its longest side is 1024, normalized by SAM channel mean/std, then padded bottom/right with normalized zero. Prompt coordinates use the separately rounded resized dimensions and SAM's +0.5 pixel-center shift. The decoder returns three 256-square logit masks; these are bilinearly sampled, padding is cropped, and binary masks are stored at up to 512 pixels with top-left normalized photo bounds. Mask arrays are tightly cropped to those bounds. Predicted IoU ranks candidates; it is not calibrated food or nutrition confidence.

## Model provenance

- Upstream: [ChaoningZhang/MobileSAM](https://github.com/ChaoningZhang/MobileSAM), inspected revision `f706ad9c4eb7f219c00d9050e46328518ffb65d2`, Apache-2.0.
- Original checkpoint SHA-256: `6dbb90523a35330fedd7f1d3dfc66f995213d81b29a5ca8108dbcdd4e37d6c2f`.
- Bundled conversion: [mlboydaisuke/MobileSAM-CoreML](https://huggingface.co/mlboydaisuke/MobileSAM-CoreML/tree/1a87f0e568226d4bb3f32c0b9d5cdda48408e4c4), pinned revision `1a87f0e568226d4bb3f32c0b9d5cdda48408e4c4`. Individual hashes are in model-lock.json. Model metadata identifies SAMKit, coremltools 9.0 and Torch 2.11.0. The model card identifies Apache-2.0 and credits Daisuke Majima/john-rocky.
- Converter/runtime reference: [SAMKit](https://github.com/john-rocky/SamKit/tree/e6e154cb86eafa56641a2997e806fedbc489dbf5). Our adapter follows original SAM normalized-zero bottom/right padding, rather than the centered black padding in the inspected sample.

The downloaded packages are not represented as a locally reproduced conversion. Prompt weights were compared exactly to the original checkpoint; numeric equivalence of the bundled encoder/decoder has not been established on CoreML. Keep bundled license/attribution files in distributions.

## Exact source conversion commands

Run on an Apple Silicon Mac with Python 3.11 and Xcode, from this iOS directory. This independent recipe produces adapter-compatible packages, not a bit-identical reproduction of the bundled conversion. Full CoreML export/parity has not run here. Export separately so failure leaves the bundled candidate intact.

```sh
python3.11 -m venv .model-venv
source .model-venv/bin/activate
python -m pip install -r Tools/requirements-mobilesam.txt
mkdir -p work
git clone https://github.com/ChaoningZhang/MobileSAM.git work/MobileSAM
git -C work/MobileSAM checkout f706ad9c4eb7f219c00d9050e46328518ffb65d2
curl -fL https://raw.githubusercontent.com/ChaoningZhang/MobileSAM/f706ad9c4eb7f219c00d9050e46328518ffb65d2/weights/mobile_sam.pt -o work/mobile_sam.pt
python Tools/export_mobilesam.py \
  --source work/MobileSAM --checkpoint work/mobile_sam.pt \
  --output work/rebuilt-mobilesam
```

The script verifies the checkpoint hash before loading, exports FP16-internal ML Programs with float32 interfaces, checks PyTorch traces for 1/2/9 taps and compares basic CoreML outputs to PyTorch on a synthetic input. Failures/NaNs stop the script. Synthetic parity cannot establish food accuracy. `--reference-only` exports the prompt fixture and checks bundled prompt weights; `--trace-only` checks trained traces without CoreML.

After successful conversion, compare rebuilt/bundled models on representative photos locally, then deliberately replace both packages and prompt JSON together. Update lock hashes, provenance and contracts to describe the chosen artifacts; do not bypass integrity failures. Generated work directories are not app resources.

## Verified here

- Seven bundled files passed SHA-256/length checks; protobuf inspection confirmed feature names, float32 interface shapes and 2–10 sparse tokens.
- Bundled learned prompt weights exactly equal corresponding official checkpoint tensors.
- Trained encoder/decoder and traced versions agree for 1, 2 and 9 prompts with the local CPU runtime: PyTorch 2.7.0+cpu, torchvision 0.22.0+cpu, timm 1.0.15. Fixed-size tracing warnings are expected; arbitrary resolutions are not supported.
- The fixture contains official prompt-encoder output; the Swift parity XCTest is supplied but unexecuted.
- Swift syntax parsing and Python source compilation passed. These do not verify Apple SDK types or rendering.
- Backend source is unchanged from Phase 2; its previously passing tests were not rerun for this iOS-only phase.

## Acceptance still required

1. Run Debug XCTests and Release build using README commands or supplied macOS CI. Missing trained models fail their integration test. Its synthetic image checks runtime/finite outputs, not accuracy. The optional grayscale diagnostic remains test-only.
2. Confirm portrait/landscape, rotated-photo and edge mask alignment. Run asymmetric RGB/orientation and normalized-padding tests first.
3. On supported non-LiDAR and LiDAR iPhones, measure cold/warm tap latency, peak memory with Instruments, thermal behavior and memory after ten open/retake/close cycles. Record device/iOS/build and median/p95 over 20 runs. Initial targets: warm tap under 3 seconds, cold tap under 6 seconds, peak memory under 400 MB. These are targets, not measurements.
4. Background/cancel/close during encoder/decoder work. No old mask may reappear after retake. Repeated loads must not crash or accumulate memory.
5. Test consented dining-plate examples across halls, lighting, disposable/glass plates, touching foods and sauces. Measure mask IoU against annotations, plate boundary error, failures and correction taps.
6. Test airplane mode after menu caching. Review accessibility text sizes and provide an accessible alternative to point placement before release.

Classification, metric depth, portions, meal saving and HealthKit remain later phases. `outlinedPlate` exposes confirmed regions for the future classification handoff. The nutrition pipeline remains gated; masks do not produce fabricated totals.

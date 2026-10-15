# MI-GAN Core ML inpainting - phase 0 bench

Host: Apple M4 Pro 48GB, macOS 27.0.1 (Darwin 27.0.0), Swift 6.2.3, coremltools 9.0 / torch 2.14.1 (conversion).
Models: `models/MIGAN_512.mlpackage`, `models/MIGAN_256.mlpackage` (mlprogram, fp16 weights/compute, macOS14 target).
Reproduce: `./convert_migan.sh`, `swiftc -O bench.swift -o bench && ./bench models/MIGAN_512.mlpackage models/MIGAN_256.mlpackage`,
`swiftc -O quality.swift -o quality && ./quality models/MIGAN_512.mlpackage out`.

## Latency (3 warmup + 20 timed `prediction(from:)`, batch 1, synthetic input, text-like rect hole)

Run 1 (a repeat run gave the same picture within ~10%; ranges in notes). Times in ms. compile = `MLModel.compileModel`; load = `MLModel(contentsOf:configuration:)` on the compiled model (ANE/GPU load includes on-device specialization).

| model | size | compute units | compile ms | load ms | median ms | p90 ms |
|---|---|---|---|---|---|---|
| MIGAN_512 | 14.2 MB | cpuOnly | 170 | 234 | 212.5 | 320.5 |
| MIGAN_512 | 14.2 MB | cpuAndGPU | 170 | 203 | 13.3 | 13.4 |
| MIGAN_512 | 14.2 MB | cpuAndNeuralEngine | 170 | 1467 | 20.0 | 20.3 |
| MIGAN_512 | 14.2 MB | all | 170 | 2248 | 55.3 | 64.1 |
| MIGAN_256 | 12.5 MB | cpuOnly | 90 | 150 | 103.8 | 121.5 |
| MIGAN_256 | 12.5 MB | cpuAndGPU | 90 | 144 | 12.0 | 89.1 (outlier) |
| MIGAN_256 | 12.5 MB | cpuAndNeuralEngine | 90 | 924 | 9.9 | 10.0 |
| MIGAN_256 | 12.5 MB | all | 90 | 908 | 16.1 | 17.8 |

Repeat runs (2 more): 512 cpuAndGPU 12.3-12.6 / p90 13.2-13.5; 512 ANE 20.1-20.2; 512 all 51-56; 512 cpuOnly 186-192;
256 cpuAndGPU 7.6 / p90 7.9 (the 12.0/89.1 above was a one-off); 256 ANE 9.9; 256 all 16.6; 256 cpuOnly 76.

Takeaways (measured): GPU is fastest at 512 (~12-13 ms), ANE is fastest at 256 (~10 ms; GPU ~7.6-12). `.all` is
*slower* than either alone here (51-56 ms at 512, 16 ms at 256) - do not use `.all`; pick `.cpuAndGPU` (512) or
`.cpuAndNeuralEngine` (256) explicitly. cpuOnly is too slow for live use (190-210 ms @512). Pure model time only:
excludes pixel pack/unpack (the Swift loop in quality.swift is not optimized) and screen capture.

## Quality sanity (quality.swift, cpuAndGPU)

Synthetic patch: diagonal colour gradient + sinusoidal texture (clean bg known), black bold Helvetica text
("Hello World" / "Translate me") drawn with CoreGraphics/CoreText; mask = text strokes dilated by r=3 px
(13.1% of the 512 patch, 17.6% of the 256 patch). Mean absolute error in 0-255 units over RGB pixels inside the mask,
output clamped to [-1,1] then mapped to 0-255:

| model | model output vs clean bg (in mask) | naive: mean border colour fill vs clean bg (in mask) | model output vs text-input (in mask) |
|---|---|---|---|
| MIGAN_512 | 1.87 | 18.98 | 92.04 (hole is really rewritten) |
| MIGAN_256 | 3.52 | 19.15 | 70.23 |

Outside the mask the **raw model output is NOT the input**: mean abs diff raw output vs input = 12.68 (512) / 7.34 (256).
So the app MUST composite: `result = known*input + (1-known)*output` (done in quality.swift; outside-mask diff is then 0 by construction).
Caveat: the background is smooth and easy (gradient + soft texture); this is a sanity check, not a photo/UI-screenshot benchmark.
Images: `out/before_512.png`, `mask_512.png` (white=hole), `after_512.png`, `naive_512.png`, `clean_512.png` (+ `_256`). After image looked clean by eye.
Parity vs PyTorch fp32 on random input: 512 max|diff| 0.086 / mean 0.0023; 256 max 0.068 / mean 0.0013 (in [-1,1] units).

## I/O contract (both models identical apart from H=W)

Input, one only:
- name `input`, type MLMultiArray float32, shape `[1, 4, H, W]` (NCHW), H=W=512 or 256. Fixed shape (no flexible shapes); patches must be resized/padded to the model size.
- channel 0 = `mask - 0.5`, where mask is **1 = KNOWN (keep), 0 = HOLE (to fill)** - opposite of the usual "1 = hole". So channel 0 is +0.5 on known pixels, -0.5 in the hole.
- channels 1..3 = RGB in order R,G,B, normalized to **[-1, 1]** (`v/127.5 - 1`), **multiplied by the mask** i.e. the hole must already be zeroed (0 = mid-grey in [-1,1]).
- Mask should be binary (0/1); the dilated text mask worked well.

Output: name `output`, MLMultiArray float32, shape `[1, 3, H, W]`, RGB, nominally [-1, 1] but measured to overshoot (e.g. [-1.69, 2.11] on random input) -> **clamp to [-1,1]** then `*127.5+127.5`. It is a full-frame reconstruction (differs from input outside the hole by ~7-13 levels) -> composite with the mask.
Not image/CVPixelBuffer I/O (a 4-channel mask+RGB input cannot be an image type). Upstream reference: `x = cat([mask-0.5, img*mask])`, `out = img*mask + model(x)*(1-mask)` (MI-GAN scripts/demo.py, scripts/export_inference_model.py).

## Files and licenses

| artifact | size | source | license |
|---|---|---|---|
| models/MIGAN_512.mlpackage | 14.2 MB | converted here from migan_512_places2.pt (fp16) | derived from weights below |
| models/MIGAN_256.mlpackage | 12.5 MB | converted here from migan_256_places2.pt (fp16) | derived from weights below |
| vendor/weights/migan_512_places2.pt | 29.6 MB | official Picsart MI-GAN Google Drive folder https://drive.google.com/drive/folders/1xNtvN2lto0p5yFKOEEg9RioMjGrYM74w (linked from https://github.com/Picsart-AI-Research/MI-GAN README) | MIT per `LICENSE-WEIGHTS` ("Copyright (c) 2024 Picsart AI Research (PAIR)"); code also MIT |
| vendor/weights/migan_256_places2.pt | 25.2 MB | same folder | same |
| vendor/weights/migan_256_ffhq.pt (downloaded, unused) | 25.2 MB | same folder | same |

MI-GAN commit used: 2b793c5ece43f4253e32d4afc257120a5deed6f5. Places2 training data has its own terms (research/non-commercial per Places2 site) - the weights'
MIT file does not address that; legal should confirm before shipping.
Prior art: https://github.com/tatsuya-ogawa/MI-GAN-CoreML ships pre-converted `migan_512_coreml.mlpackage` / `migan_coreml.mlpackage` committed in the repo (not in GitHub releases) and an iOS demo; cloned into vendor/ for reference only, not benchmarked, its export.sh (which loads via `strict=False` and an unverified path) not run. Our conversion loads state_dict with `weights_only=True`.
Not done: LaMa (CoreMLaMa) - skipped, optional.

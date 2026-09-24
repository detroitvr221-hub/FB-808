# Demucs → Core ML stem model (D1, full 4-stem)

Builds `StemSeparator.mlpackage` (htdemucs: drums / bass / other / vocals) for the FD-808 app's
"Split → 4 Stems" button (`FourStemSeparator.swift`). The shipped, quantized package is versioned in
`FB-808/StemSeparator.mlpackage` so a recursive checkout can build without conversion or an external
asset server. Its three files are pinned by SHA-256 in `model-checksums.json`; CI fails on missing,
truncated or changed files and runs Release app/AUv3 builds plus simulator unit/UI tests.

From the outer repository, run `git submodule update --init --recursive`, then
`python3 FB-808/tools/coreml-stems/verify_model.py`. Do not omit the model files when committing this
submodule. The conversion workflow below is for replacing the shipped model, not for normal builds.
A deliberate model replacement requires numerical verification and reviewed checksum updates.

## Why this is non-trivial
`coremltools` can't convert Demucs as-is: `torch.stft` produces **complex64** tensors it can't slice,
and the transformer uses the **fused `_native_multi_head_attention`** op. The fixes here:

- `realspec.py` — a real-valued (complex-free) STFT/ISTFT built from `conv1d`/`conv_transpose1d`,
  matching `torch.stft`/`istft` (normalized, centered, Hann) to ~5e-6. Represents the "complex
  spectrogram" as a real tensor with a trailing size-2 (re, im) dim.
- `convert2.py` — monkeypatches HTDemucs `_spec`/`_ispec`/`_magnitude`/`_mask` to use `realspec`
  (keeping every tensor ≤ rank 5, which Core ML requires), disables the MHA fastpath
  (`torch.backends.mha.set_fastpath_enabled(False)`), bakes Demucs's input normalization into the
  graph, traces, and converts at **fp32 compute** (fp16 overflows the 4096-tap STFT conv → NaN).
  Validates the patched torch model against the original (≈4e-6) before converting.

## Steps
```bash
python3 -m venv venv && ./venv/bin/pip install torch demucs coremltools soundfile
./venv/bin/python convert2.py htdemucs       # → StemSeparator.mlpackage  (fp32, ~333 MB)
./venv/bin/python quantize.py                # → StemSeparator_int8.mlpackage (~93 MB)
./venv/bin/python verify_cpu.py StemSeparator_int8.mlpackage   # CPU check vs torch + writes stem_*.wav
cp -R StemSeparator_int8.mlpackage ../../FB-808/StemSeparator.mlpackage   # drop into the app target
```
Verified numerics (CPU): fp32 ≈ **0.008 %** rel error vs torch htdemucs; int8 ≈ **3.7 %** (≈28 dB SNR,
well under Demucs's own separation artifacts) at ~1/3.5 the size. The app auto-discovers the model's
I/O names + segment length, so no `StemModelContract` edits are needed for this export.

`min_deployment_target=iOS17`, input `audio [1,2,343980]` f32 @ 44.1 kHz, output `stems [1,4,2,343980]`,
source order drums/bass/other/vocals.

#!/usr/bin/env python
"""Convert htdemucs to Core ML by replacing its complex STFT/ISTFT with the real conv-based equivalent
(realspec), which coremltools can convert. Validates the patched model against the original before convert."""
import sys, math, types, torch, numpy as np, torch.nn as nn, torch.nn.functional as F
from demucs.pretrained import get_model
from demucs.htdemucs import pad1d
import realspec as rs

torch.backends.mha.set_fastpath_enabled(False)   # force traceable attention (no fused _native MHA op)

NAME = sys.argv[1] if len(sys.argv) > 1 else "htdemucs"
bag = get_model(NAME); bag.eval()
sub = bag.models[0] if hasattr(bag, "models") and len(bag.models) else bag
sub.eval()
sources = list(getattr(bag, "sources", sub.sources))
sr = int(getattr(bag, "samplerate", 44100)); ch = int(getattr(bag, "audio_channels", 2))
seg = float(getattr(bag, "segment", 7.8) or 7.8)
L = int(sub.valid_length(int(round(seg * sr))))
print(f"{NAME}: sources={sources} sr={sr} ch={ch} L={L} ({L/sr:.2f}s)")


class Wrapped(nn.Module):
    def __init__(self, m): super().__init__(); self.m = m
    def forward(self, x):
        mono = x.mean(dim=1, keepdim=True)
        mean = mono.mean(dim=(1, 2), keepdim=True); std = mono.std(dim=(1, 2), keepdim=True)
        out = self.m((x - mean) / (1e-5 + std))
        return out * std.unsqueeze(1) + mean.unsqueeze(1)


wrapped = Wrapped(sub).eval()
example = torch.randn(1, ch, L)
with torch.no_grad():
    ref = wrapped(example)          # ORIGINAL (complex) output, before patching
print("reference output:", tuple(ref.shape))

# ---- monkeypatch the spectral front/back end to be complex-free ----
def _spec(self, x):
    hl, nfft = self.hop_length, self.nfft
    assert hl == nfft // 4
    le = int(math.ceil(x.shape[-1] / hl)); pad = hl // 2 * 3
    x = pad1d(x, (pad, pad + le * hl - x.shape[-1]), mode="reflect")
    z = rs.spectro_real(x, nfft, hl)[..., :-1, :, :]       # drop Nyquist (freq dim = -3)
    assert z.shape[-2] == le + 4, (z.shape, le)
    return z[..., 2:2 + le, :]                              # trim frames (dim -2)

def _magnitude(self, z):
    B, C, Fr, T, _ = z.shape
    return z.permute(0, 1, 4, 2, 3).reshape(B, C * 2, Fr, T)

def _mask(self, z, m):
    # m: [B, S, C*2, Fr, T] (complex-as-channels) → collapse S·C to stay <= rank 5: [B, S*C, Fr, T, 2].
    B, S, C2, Fr, T = m.shape
    C = C2 // 2
    m = m.reshape(B * S, C, 2, Fr, T).permute(0, 1, 3, 4, 2)   # [B*S, C, Fr, T, 2]
    return m.reshape(B, S * C, Fr, T, 2)

def _ispec(self, z, length=None, scale=0):
    hl = self.hop_length // (4 ** scale)
    z = F.pad(z, (0, 0, 0, 0, 0, 1))      # +1 freq bin (Nyquist)
    z = F.pad(z, (0, 0, 2, 2))            # +2/+2 frames
    pad = hl // 2 * 3
    le = hl * int(math.ceil(length / hl)) + 2 * pad
    x = rs.ispectro_real(z, hl, length=le)            # [B, S*C, samples]
    x = x[..., pad:pad + length]
    S = len(self.sources)
    return x.reshape(x.shape[0], S, -1, x.shape[-1])   # [B, S, C, length]

cls = type(sub)
for name, fn in [("_spec", _spec), ("_magnitude", _magnitude), ("_mask", _mask), ("_ispec", _ispec)]:
    setattr(cls, name, fn)

with torch.no_grad():
    patched = wrapped(example)
err = (patched - ref).abs().max().item()
rel = (patched - ref).abs().mean().item() / (ref.abs().mean().item() + 1e-9)
print(f"PATCHED vs ORIGINAL  max|err|={err:.3e}  rel={rel:.4%}")
if rel > 0.01:
    print("!! patched model diverged — aborting"); sys.exit(1)

print("tracing patched model…")
with torch.no_grad():
    traced = torch.jit.trace(wrapped, example, check_trace=False)

import coremltools as ct
print("converting…")
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="audio", shape=(1, ch, L), dtype=np.float32)],
    outputs=[ct.TensorType(name="stems", dtype=np.float32)],
    minimum_deployment_target=ct.target.iOS17,
    compute_units=ct.ComputeUnit.ALL,
    compute_precision=ct.precision.FLOAT32,   # fp16 overflows the 4096-tap STFT conv → NaN
    convert_to="mlprogram",
)
mlmodel.user_defined_metadata["sources"] = ",".join(sources)
mlmodel.user_defined_metadata["samplerate"] = str(sr)
mlmodel.short_description = f"Demucs {NAME} {len(sources)}-stem (real-STFT)"
mlmodel.save("StemSeparator.mlpackage")
print("saved StemSeparator.mlpackage")

pred = mlmodel.predict({"audio": example.numpy().astype(np.float32)})
key = "stems" if "stems" in pred else list(pred.keys())[0]
cm = pred[key]
e = np.abs(cm - patched.numpy())
print(f"CoreML vs torch  shape={cm.shape}  max|err|={e.max():.4e}  rel={e.mean()/(np.abs(patched.numpy()).mean()+1e-9):.4%}")
print("sources order:", sources)

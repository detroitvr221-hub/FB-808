#!/usr/bin/env python
"""Verify the saved StemSeparator.mlpackage on CPU against the patched torch model (no GPU watchdog)."""
import math, torch, numpy as np, torch.nn as nn, torch.nn.functional as F
from demucs.pretrained import get_model
from demucs.htdemucs import pad1d
import realspec as rs, coremltools as ct

torch.backends.mha.set_fastpath_enabled(False)
bag = get_model("htdemucs"); bag.eval()
sub = bag.models[0]; sub.eval()
sources = list(bag.sources); sr = 44100; ch = 2
L = int(sub.valid_length(int(round(float(sub.segment) * sr))))

def _spec(self, x):
    hl, nfft = self.hop_length, self.nfft
    le = int(math.ceil(x.shape[-1] / hl)); pad = hl // 2 * 3
    x = pad1d(x, (pad, pad + le * hl - x.shape[-1]), mode="reflect")
    z = rs.spectro_real(x, nfft, hl)[..., :-1, :, :]
    return z[..., 2:2 + le, :]
def _magnitude(self, z):
    B, C, Fr, T, _ = z.shape
    return z.permute(0, 1, 4, 2, 3).reshape(B, C * 2, Fr, T)
def _mask(self, z, m):
    B, S, C2, Fr, T = m.shape; C = C2 // 2
    m = m.reshape(B * S, C, 2, Fr, T).permute(0, 1, 3, 4, 2)
    return m.reshape(B, S * C, Fr, T, 2)
def _ispec(self, z, length=None, scale=0):
    hl = self.hop_length // (4 ** scale)
    z = F.pad(z, (0, 0, 0, 0, 0, 1)); z = F.pad(z, (0, 0, 2, 2))
    pad = hl // 2 * 3; le = hl * int(math.ceil(length / hl)) + 2 * pad
    x = rs.ispectro_real(z, hl, length=le)[..., pad:pad + length]
    return x.reshape(x.shape[0], len(self.sources), -1, x.shape[-1])
cls = type(sub)
for n, fn in [("_spec", _spec), ("_magnitude", _magnitude), ("_mask", _mask), ("_ispec", _ispec)]:
    setattr(cls, n, fn)

class W(nn.Module):
    def __init__(s, m): super().__init__(); s.m = m
    def forward(s, x):
        mono = x.mean(1, keepdim=True); mean = mono.mean((1, 2), keepdim=True); std = mono.std((1, 2), keepdim=True)
        return s.m((x - mean) / (1e-5 + std)) * std.unsqueeze(1) + mean.unsqueeze(1)
w = W(sub).eval()

# Synthetic mix: 220 Hz tone (tonal → bass/other) + periodic noise bursts (→ drums).
t = torch.arange(L) / sr
tone = 0.3 * torch.sin(2 * math.pi * 220 * t)
drums = torch.zeros(L)
for k in range(0, L, sr // 4):
    drums[k:k + 1500] += 0.6 * torch.randn(min(1500, L - k))
mix = (tone + drums).unsqueeze(0).repeat(2, 1).unsqueeze(0)   # [1,2,L]

with torch.no_grad():
    ref = w(mix).numpy()
print("torch out:", ref.shape, "finite:", np.isfinite(ref).all())

m = ct.models.MLModel(__import__("sys").argv[1] if len(__import__("sys").argv)>1 else "StemSeparator.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY)
pred = m.predict({"audio": mix.numpy().astype(np.float32)})
cm = pred[list(pred.keys())[0]]
print("coreml out:", cm.shape, "finite:", np.isfinite(cm).all())
e = np.abs(cm - ref)
print(f"CoreML vs torch  max|err|={e.max():.4e}  rel={e.mean()/(np.abs(ref).mean()+1e-9):.4%}")

# Per-stem energy of the synthetic mix — drums stem should grab the bursts, bass/other the tone.
for i, name in enumerate(sources):
    st = cm[0, i].mean(0)
    print(f"  {name:7s} rms={np.sqrt((st**2).mean()):.4f}")

# Save the CoreML stems to WAV so they can be auditioned.
import soundfile as sf
for i, name in enumerate(sources):
    sf.write(f"stem_{name}.wav", cm[0, i].T, sr)
print("wrote stem_*.wav")

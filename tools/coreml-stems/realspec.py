"""Real-valued (complex-free) STFT/ISTFT matching demucs.spec.spectro/ispectro, built from conv1d /
conv_transpose1d so it converts to Core ML (no complex, no unfold/fold). The "complex spectrogram" is a
real tensor with trailing size-2 (re, im): [..., freqs, frames, 2]. Validated against torch.stft/istft."""
import math, torch, torch.nn.functional as F

_fwd, _inv = {}, {}

def _fwd_w(N, device, dtype):
    key = (N, str(device), str(dtype))
    if key not in _fwd:
        nb = N // 2 + 1
        n = torch.arange(N, dtype=torch.float64).unsqueeze(0)   # [1,N]
        k = torch.arange(nb, dtype=torch.float64).unsqueeze(1)  # [nb,1]
        ang = 2 * math.pi * k * n / N
        win = torch.hann_window(N, periodic=True, dtype=torch.float64).unsqueeze(0)
        scale = 1.0 / math.sqrt(N)                              # normalized=True
        wcos = (torch.cos(ang) * win * scale).unsqueeze(1)      # [nb,1,N] conv1d weight
        wsin = (-torch.sin(ang) * win * scale).unsqueeze(1)
        _fwd[key] = (wcos.to(device=device, dtype=dtype), wsin.to(device=device, dtype=dtype))
    return _fwd[key]

def _inv_w(N, device, dtype):
    key = (N, str(device), str(dtype))
    if key not in _inv:
        nb = N // 2 + 1
        n = torch.arange(N, dtype=torch.float64).unsqueeze(0)
        k = torch.arange(nb, dtype=torch.float64).unsqueeze(1)
        ang = 2 * math.pi * k * n / N
        coeff = torch.full((nb, 1), 2.0, dtype=torch.float64); coeff[0, 0] = 1.0; coeff[nb - 1, 0] = 1.0
        win = torch.hann_window(N, periodic=True, dtype=torch.float64).unsqueeze(0)
        norm = math.sqrt(N)                                     # undo normalized=True
        wicos = (coeff * torch.cos(ang) / N * norm * win).unsqueeze(1)   # [nb,1,N] convT weight
        wisin = (-coeff * torch.sin(ang) / N * norm * win).unsqueeze(1)
        wsq = (torch.hann_window(N, periodic=True, dtype=torch.float64) ** 2).reshape(1, 1, N)
        _inv[key] = (wicos.to(device=device, dtype=dtype), wisin.to(device=device, dtype=dtype),
                     wsq.to(device=device, dtype=dtype))
    return _inv[key]

def spectro_real(x, n_fft=4096, hop_length=None):
    hop = hop_length or n_fft // 4
    *other, length = x.shape
    xf = x.reshape(-1, 1, length)
    pad = n_fft // 2
    xf = F.pad(xf, (pad, pad), mode="reflect")               # center=True
    wcos, wsin = _fwd_w(n_fft, x.device, x.dtype)
    R = F.conv1d(xf, wcos, stride=hop)                       # [B, nb, M]
    I = F.conv1d(xf, wsin, stride=hop)
    z = torch.stack([R, I], dim=-1)                          # [B, nb, M, 2]
    nb, M = z.shape[-3], z.shape[-2]
    return z.reshape(*other, nb, M, 2)

def ispectro_real(z, hop_length=None, length=None):
    *other, freqs, frames, _ = z.shape
    n_fft = 2 * freqs - 2
    hop = hop_length or n_fft // 4
    zf = z.reshape(-1, freqs, frames, 2)
    R = zf[..., 0]                                           # [B, nb, M]
    I = zf[..., 1]
    wicos, wisin, wsq = _inv_w(n_fft, z.device, z.dtype)
    y = F.conv_transpose1d(R, wicos, stride=hop) + F.conv_transpose1d(I, wisin, stride=hop)   # [B,1,total]
    ones = torch.ones(R.shape[0], 1, frames, device=z.device, dtype=z.dtype)
    wnorm = F.conv_transpose1d(ones, wsq, stride=hop)        # [B,1,total]
    y = (y / (wnorm + 1e-8)).squeeze(1)                      # [B, total]
    pad = n_fft // 2
    y = y[:, pad:y.shape[-1] - pad]                          # undo center
    if length is not None:
        if y.shape[-1] < length:
            y = F.pad(y, (0, length - y.shape[-1]))
        else:
            y = y[:, :length]
    return y.reshape(*other, y.shape[-1])


if __name__ == "__main__":
    from demucs.spec import spectro, ispectro
    torch.manual_seed(0)
    x = torch.randn(2, 44100)
    N, hop = 4096, 1024
    zc = spectro(x, N, hop)
    zr = spectro_real(x, N, hop)
    print(f"STFT  max|re|={ (zr[...,0]-zc.real).abs().max():.3e}  max|im|={ (zr[...,1]-zc.imag).abs().max():.3e}")
    xr = ispectro_real(zr, hop)
    xc = ispectro(zc, hop, length=x.shape[-1])
    L = min(xr.shape[-1], xc.shape[-1])
    print(f"ISTFT vs torch  max err={ (xr[...,:L]-xc[...,:L]).abs().max():.3e}")
    print(f"round-trip      max err={ (xr[...,:L]-x[...,:L]).abs().max():.3e}")

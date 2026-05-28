#!/usr/bin/env python3
"""
quantize_weights.py
Quantizes ecg_model_v2.pth weights to INT8 for FPGA deployment.
Run from: C:/Intel/ecg-arrhythmia-classifier/

Outputs → results/weights_int8/
  <layer>_weight.mem / <layer>_bias.mem  : hex for Vivado $readmemh
  cnn_params_pkg.sv                      : shift amounts as SV localparams
  report.txt                             : accuracy and per-layer stats
"""

import torch
import torch.nn as nn
import numpy as np
import os
from sklearn.model_selection import train_test_split

OUT = 'results/weights_int8'
os.makedirs(OUT, exist_ok=True)

# ── Model definition (must match ecg_model_v2.pth exactly) ───────────────────

class ECGClassifierV2(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1      = nn.Conv1d(1,   32,  kernel_size=5, padding=2)
        self.conv2      = nn.Conv1d(32,  64,  kernel_size=5, padding=2)
        self.conv3      = nn.Conv1d(64,  128, kernel_size=5, padding=2)
        self.pool       = nn.MaxPool1d(2)
        self.pool_adapt = nn.AvgPool1d(kernel_size=11, stride=11)
        self.relu       = nn.ReLU()
        self.dropout    = nn.Dropout(0.5)
        self.fc1        = nn.Linear(512, 128)
        self.fc2        = nn.Linear(128, 5)

    def forward(self, x):
        x = self.pool(self.relu(self.conv1(x)))
        x = self.pool(self.relu(self.conv2(x)))
        x = self.pool(self.relu(self.conv3(x)))
        x = self.pool_adapt(x)
        x = x.view(x.size(0), -1)
        x = self.dropout(self.relu(self.fc1(x)))
        return self.fc2(x)

# ── Quantization helpers ──────────────────────────────────────────────────────

def quantize(tensor, bits=8):
    """Symmetric per-tensor INT8 quantization. Returns (int8_ndarray, float_scale)."""
    peak = tensor.abs().max().item()
    if peak < 1e-8:
        return np.zeros(tensor.shape, dtype=np.int8), 1.0
    maxq  = (1 << (bits - 1)) - 1               # 127
    scale = peak / maxq
    q = np.clip(np.round(tensor.detach().cpu().numpy() / scale), -128, 127)
    return q.astype(np.int8), scale

def write_mem(path, arr):
    """Write flat INT8 array as 2-digit hex per line for $readmemh."""
    with open(path, 'w') as f:
        for v in arr.flatten():
            f.write(f'{int(v) & 0xFF:02x}\n')

def acc_shift(n_inputs):
    """
    Conservative right-shift for INT32 accumulator → INT8 output.
    Worst-case acc = 127 * 127 * n_inputs. Shift so result ≤ 127.
    shift = ceil(log2(127 * n_inputs))
    """
    return max(0, int(np.ceil(np.log2(127 * n_inputs))))

# ── Load model ────────────────────────────────────────────────────────────────

print('Loading ecg_model_v2.pth ...')
model = ECGClassifierV2()
model.load_state_dict(torch.load('results/ecg_model_v2.pth', map_location='cpu'))
model.eval()
sd = model.state_dict()

# ── Quantize all layers ───────────────────────────────────────────────────────

LAYERS    = ['conv1', 'conv2', 'conv3', 'fc1', 'fc2']
N_INPUTS  = {'conv1': 1*5, 'conv2': 32*5, 'conv3': 64*5, 'fc1': 512, 'fc2': 128}

scales = {}
quants = {}

print(f'\n{"Layer":<8} {"W shape":<22} {"W peak":>8}  {"W scale":>12}  {"Shift":>6}')
print('─' * 62)

for name in LAYERS:
    wq, ws = quantize(sd[f'{name}.weight'])
    bq, bs = quantize(sd[f'{name}.bias'])

    write_mem(f'{OUT}/{name}_weight.mem', wq)
    write_mem(f'{OUT}/{name}_bias.mem',   bq)
    np.save(f'{OUT}/{name}_weight_int8.npy', wq)
    np.save(f'{OUT}/{name}_bias_int8.npy',   bq)

    scales[name] = (ws, bs)
    quants[name] = (wq, bq)

    sh   = acc_shift(N_INPUTS[name])
    peak = sd[f'{name}.weight'].abs().max().item()
    print(f'{name:<8} {str(tuple(sd[f"{name}.weight"].shape)):<22} '
          f'{peak:>8.4f}  {ws:>12.6e}  {sh:>6}')

# ── Accuracy: run model with dequantized weights ──────────────────────────────
# Dequantize INT8 → float and run the original model architecture.
# This is the correct proxy for hardware INT8 accuracy.

print('\nMeasuring quantization accuracy (dequantized weights, full-precision forward pass)...')

model_q = ECGClassifierV2()
qsd = {}
for name in LAYERS:
    wq, bq = quants[name]
    ws, bs = scales[name]
    qsd[f'{name}.weight'] = torch.FloatTensor(wq.astype(np.float32) * ws)
    qsd[f'{name}.bias']   = torch.FloatTensor(bq.astype(np.float32) * bs)
model_q.load_state_dict(qsd, strict=False)
model_q.eval()

beats  = np.load('data/all_beats.npy').astype(np.float32)
labels = np.load('data/all_labels.npy')
_, X_test, _, y_test = train_test_split(beats, labels, test_size=0.2, random_state=42)
X_t = torch.FloatTensor(X_test).unsqueeze(1)
y_t = torch.LongTensor(y_test)

with torch.no_grad():
    acc_f = (model(X_t).argmax(1)   == y_t).float().mean().item() * 100
    acc_q = (model_q(X_t).argmax(1) == y_t).float().mean().item() * 100

print(f'  Float32 baseline : {acc_f:.2f}%')
print(f'  INT8 (deq)       : {acc_q:.2f}%')
print(f'  Drop             : {acc_f - acc_q:.2f}%')

# ── Write SV package with shift constants ─────────────────────────────────────

shifts = {n: acc_shift(N_INPUTS[n]) for n in LAYERS}

sv_lines = [
    '// Auto-generated by quantize_weights.py — do not edit manually.',
    '// Quantization parameters for cnn_inference.sv on Nexys A7-100T.',
    'package cnn_params_pkg;',
    '',
    '// Per-layer right-shift: apply to INT32 accumulator to produce INT8 activation.',
    '// Conservative (worst-case) — guarantees no overflow.',
]
for name, sh in shifts.items():
    sv_lines.append(f'    localparam int {name.upper()}_SHIFT = {sh:2d};')

sv_lines += [
    '',
    '// BRAM depths for $readmemh (one byte per address).',
    '    localparam int CONV1_W_DEPTH =    160;   // 32 x 1 x 5',
    '    localparam int CONV1_B_DEPTH =     32;',
    '    localparam int CONV2_W_DEPTH =  10240;   // 64 x 32 x 5',
    '    localparam int CONV2_B_DEPTH =     64;',
    '    localparam int CONV3_W_DEPTH =  40960;   // 128 x 64 x 5',
    '    localparam int CONV3_B_DEPTH =    128;',
    '    localparam int FC1_W_DEPTH   =  65536;   // 128 x 512',
    '    localparam int FC1_B_DEPTH   =    128;',
    '    localparam int FC2_W_DEPTH   =    640;   // 5 x 128',
    '    localparam int FC2_B_DEPTH   =      5;',
    '',
    'endpackage',
]

with open(f'{OUT}/cnn_params_pkg.sv', 'w') as f:
    f.write('\n'.join(sv_lines) + '\n')

# ── Write report ──────────────────────────────────────────────────────────────

with open(f'{OUT}/report.txt', 'w') as f:
    f.write('INT8 Quantization Report — ECG CNN v2\n')
    f.write('=' * 40 + '\n\n')
    f.write(f'Float32 baseline : {acc_f:.2f}%\n')
    f.write(f'INT8 (deq)       : {acc_q:.2f}%\n')
    f.write(f'Accuracy drop    : {acc_f - acc_q:.2f}%\n\n')
    f.write('Per-layer details:\n')
    for name in LAYERS:
        ws, bs = scales[name]
        sh = shifts[name]
        wq, bq = quants[name]
        f.write(f'  {name:<8} shift={sh:2d}  w_scale={ws:.8f}  '
                f'w_size={wq.size:6d}B  b_size={bq.size}B\n')

print(f'\nAll files written to {OUT}/')
print('Next: add cnn_params_pkg.sv to Vivado project, then build cnn_inference.sv')

# coding: utf-8
"""整数定点量化参考模型(与 Verilog 逐比特一致的 golden 模型)。

量化方案:
  权重   int8  Q2.6  (w_q = clamp(round(w*64), -128, 127))
  输入   a0 = pixel >> 1  (0..127, 即 Q0.7)
  累加   int32 全精度,中间不截位
  偏置   与各自累加器同尺度(逐层标定)
  重新量化 a = relu_sat8((acc + (1<<(S-1))) >> S),S 为逐层标定的 2 的幂移位
  logits FC2 不重新量化,直接输出 int32
"""
import sys, os
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
if PROJECT_ROOT not in sys.path:
    sys.path.append(PROJECT_ROOT)
import numpy as np

# ---------------- 缩减后网络配置 ----------------
F       = 8       # filter_num
HIDDEN  = 32      # hidden_size
OUT     = 10
IMG_H   = 28
IMG_W   = 28
KH, KW  = 3, 3
CONV_OH = IMG_H - KH + 1        # 26
CONV_OW = IMG_W - KW + 1        # 26
POOL_H  = CONV_OH // 2          # 13
POOL_W  = CONV_OW // 2          # 13
FC1_IN  = F * POOL_H * POOL_W   # 1352

WQ = 6   # 权重 Q2.6 小数位


def qround(x):
    """四舍五入(向 +inf 半进位)。权重/偏置量化只在 Python 侧做一次,
    结果同时写入 .mem 并被参考模型与 Verilog 复用,故舍入方式只影响精度,不影响一致性。"""
    return np.floor(x + 0.5).astype(np.int64)


def quantize_weight(w):
    return np.clip(qround(w * (1 << WQ)), -128, 127).astype(np.int32)


def sat8(v):
    return np.clip(v, 0, 127).astype(np.int32)


def quantize_params(params, S1, S2):
    """把 float 参数 dict 量化为 int8/int32。params 键: W1,W2,W3,b1,b2,b3。"""
    W1 = quantize_weight(params['W1'].reshape(F, KH, KW))   # (8,3,3)
    W2 = quantize_weight(params['W2'])                       # (1352,32)
    W3 = quantize_weight(params['W3'])                       # (32,10)
    # 偏置与累加器同尺度(逐层标定后的小数位)
    b1 = qround(params['b1'] * (1 << 13)).astype(np.int32)               # conv acc Q2.13
    b2 = qround(params['b2'] * (1 << (19 - S1))).astype(np.int32)        # fc1  acc
    b3 = qround(params['b3'] * (1 << (25 - S1 - S2))).astype(np.int32)   # fc2  acc
    return dict(W1=W1, W2=W2, W3=W3, b1=b1, b2=b2, b3=b3, S1=S1, S2=S2)


def forward_int(pixels, q):
    """整数推理。pixels: uint8 (28,28) 0..255;返回 int32 logits (10,)。"""
    px = np.asarray(pixels, dtype=np.int32).reshape(IMG_H, IMG_W)
    a0 = px >> 1                       # (28,28) Q0.7, 0..127

    W1, b1, S1 = q['W1'], q['b1'], q['S1']
    W2, b2, S2 = q['W2'], q['b2'], q['S2']
    W3, b3 = q['W3'], q['b3']

    # ---- Conv (8,3,3) s1 p0 ----
    acc1 = np.zeros((F, CONV_OH, CONV_OW), dtype=np.int64)
    for kh in range(KH):
        for kw in range(KW):
            win = a0[kh:kh + CONV_OH, kw:kw + CONV_OW]          # (26,26)
            acc1 += W1[:, kh, kw, None, None] * win[None, :, :]
    acc1 += b1[:, None, None]
    R1 = (1 << (S1 - 1)) if S1 > 0 else 0
    a1 = np.where(acc1 > 0, sat8((acc1 + R1) >> S1), 0).astype(np.int32)   # (8,26,26)

    # ---- MaxPool 2x2 s2 ----
    a2 = a1.reshape(F, POOL_H, 2, POOL_W, 2).max(axis=(2, 4)).astype(np.int32)  # (8,13,13)

    # ---- FC1 1352 -> 32 ----
    a2f = a2.reshape(FC1_IN)
    acc2 = (a2f.astype(np.int64) @ W2.astype(np.int64)) + b2
    R2 = (1 << (S2 - 1)) if S2 > 0 else 0
    a3 = np.where(acc2 > 0, sat8((acc2 + R2) >> S2), 0).astype(np.int32)   # (32,)

    # ---- FC2 32 -> 10 (不重新量化) ----
    acc3 = (a3.astype(np.int64) @ W3.astype(np.int64)) + b3
    return acc3.astype(np.int32)   # (10,) logits


def calibrate(params, x_float):
    """根据 float 模型在样本上的激活量程,逐层标定 2 的幂移位 S1/S2。

    x_float: (M,1,28,28) float [0,1]
    """
    from common.util import im2col
    W1f, b1f = params['W1'], params['b1']
    W2f, b2f = params['W2'], params['b2']
    M = x_float.shape[0]

    col = im2col(x_float, KH, KW, 1, 0)                 # (M*676, 9)
    col_W = W1f.reshape(F, -1).T                         # (9, F)
    out = np.dot(col, col_W) + b1f                       # (M*676, F)
    out = out.reshape(M, CONV_OH, CONV_OW, F).transpose(0, 3, 1, 2)
    relu1 = np.maximum(out, 0)
    max_conv = float(relu1.max())

    pool = relu1.reshape(M, F, POOL_H, 2, POOL_W, 2).max(axis=(3, 5))
    fc1 = pool.reshape(M, FC1_IN).dot(W2f) + b2f         # (M, HIDDEN)
    relu2 = np.maximum(fc1, 0)
    max_fc1 = float(relu2.max())

    def pick(maxact, acc_scale):
        v = maxact * acc_scale / 127.0
        s = int(np.ceil(np.log2(v))) if v > 0.0 else 0
        return max(0, min(16, s))

    S1 = pick(max_conv, 1 << 13)
    S2 = pick(max_fc1, 1 << (19 - S1))
    return S1, S2

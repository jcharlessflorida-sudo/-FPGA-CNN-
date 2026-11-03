# coding: utf-8
"""把训练好的 params_fpga.pkl 量化为 int8 权重,导出:
   - user_source/hdl_source/cnn/weights/*.mem   (权重/偏置,$readmemh 用)
   - user_source/hdl_source/cnn/cnn_params.vh   (网络常量 + 逐层移位 S1/S2)
   - user_source/hdl_source/cnn/sim/tb_images.mem        (N 张测试图)
   - user_source/hdl_source/cnn/sim/expected_logits.txt  (量化参考算出的期望 logits)
"""
import sys, os
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
if PROJECT_ROOT not in sys.path:
    sys.path.append(PROJECT_ROOT)
import numpy as np
import pickle
import quantized_model as qm

CNN_DIR     = os.path.join(PROJECT_ROOT, 'user_source', 'hdl_source', 'cnn')
WEIGHTS_DIR = os.path.join(CNN_DIR, 'weights')
SIM_DIR     = os.path.join(CNN_DIR, 'sim')

N_TEST = 100   # 导出的仿真测试图数量(需与 cnn_tb.v 的 N 一致)


def write_hex8(path, arr):
    with open(path, 'w') as f:
        for v in arr:
            f.write('%02X\n' % (int(v) & 0xFF))


def write_hex32(path, arr):
    with open(path, 'w') as f:
        for v in arr:
            f.write('%08X\n' % (int(v) & 0xFFFFFFFF))


def main():
    from dataset.mnist import load_mnist

    params_path = os.path.join(PROJECT_ROOT, 'a', 'params_fpga.pkl')
    if not os.path.exists(params_path):
        raise SystemExit('未找到 params_fpga.pkl,请先运行: python train_convnet_fpga.py')

    with open(params_path, 'rb') as f:
        params = pickle.load(f)

    # 原始像素(0..255)用于导出;前 2000 张转 float 用于标定
    (_, _), (x_test, t_test) = load_mnist(normalize=False, flatten=False)
    x_float = x_test[:2000].astype(np.float32) / 255.0
    S1, S2 = qm.calibrate(params, x_float)
    q = qm.quantize_params(params, S1, S2)
    print('S1=%d  S2=%d' % (S1, S2))

    os.makedirs(WEIGHTS_DIR, exist_ok=True)
    os.makedirs(SIM_DIR, exist_ok=True)

    # ---- 权重/偏置 .mem ----
    write_hex8(os.path.join(WEIGHTS_DIR, 'w1.mem'), q['W1'].reshape(-1))   # f*9 + kh*3 + kw
    write_hex8(os.path.join(WEIGHTS_DIR, 'w2.mem'), q['W2'].reshape(-1))   # i*HIDDEN + j
    write_hex8(os.path.join(WEIGHTS_DIR, 'w3.mem'), q['W3'].reshape(-1))   # j*OUT + k
    write_hex32(os.path.join(WEIGHTS_DIR, 'b1.mem'), q['b1'])
    write_hex32(os.path.join(WEIGHTS_DIR, 'b2.mem'), q['b2'])
    write_hex32(os.path.join(WEIGHTS_DIR, 'b3.mem'), q['b3'])

    # ---- cnn_params.vh ----
    vh = [
        '`ifndef CNN_PARAMS_VH',
        '`define CNN_PARAMS_VH',
        'localparam CNN_F       = %d;' % qm.F,
        'localparam CNN_HIDDEN  = %d;' % qm.HIDDEN,
        'localparam CNN_OUT     = %d;' % qm.OUT,
        'localparam CNN_IMG_H   = %d;' % qm.IMG_H,
        'localparam CNN_IMG_W   = %d;' % qm.IMG_W,
        'localparam CNN_KH      = %d;' % qm.KH,
        'localparam CNN_KW      = %d;' % qm.KW,
        'localparam CNN_CONV_OH = %d;' % qm.CONV_OH,
        'localparam CNN_CONV_OW = %d;' % qm.CONV_OW,
        'localparam CNN_POOL_H  = %d;' % qm.POOL_H,
        'localparam CNN_POOL_W  = %d;' % qm.POOL_W,
        'localparam CNN_FC1_IN  = %d;' % qm.FC1_IN,
        'localparam CNN_S1      = %d;' % S1,
        'localparam CNN_S2      = %d;' % S2,
        '`endif',
        '',
    ]
    with open(os.path.join(CNN_DIR, 'cnn_params.vh'), 'w') as f:
        f.write('\n'.join(vh))

    # ---- 测试图 + 期望 logits ----
    idxs = list(range(N_TEST))
    with open(os.path.join(SIM_DIR, 'tb_images.mem'), 'w') as fim, \
         open(os.path.join(SIM_DIR, 'expected_logits.txt'), 'w') as fexp:
        for n, idx in enumerate(idxs):
            img = x_test[idx]                     # (1,28,28) uint8
            for v in img.reshape(-1):
                fim.write('%02X\n' % int(v))
            logits = qm.forward_int(img.reshape(28, 28), q)
            fexp.write('%d %d' % (n, int(t_test[idx])))
            for v in logits:
                fexp.write(' %d' % int(v))
            fexp.write('\n')

    print('export done: N_TEST=%d' % N_TEST)


if __name__ == '__main__':
    main()

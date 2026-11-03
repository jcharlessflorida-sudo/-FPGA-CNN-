# coding: utf-8
"""把 ModelSim 跑出来的 784 字节(video_to_cnn 的预处理结果)与 Python 参考模型逐字节比对。

数据来源全部是文件,模型参数**从 RTL 源码里读**:
  - sim/frame720p.mem : a/frame_gen.py 生成的输入帧(真实 1280x720)
  - sim/v2c_out.mem   : video_to_cnn_frame_tb.v 导出的 RTL 输出(784 行 %02X)
  - video_to_cnn.v    : 正则抓 parameter 默认值(INVERT/IMG_W/.../BIN_TH/MIN_RANGE)

这样"参考模型"和"被测 RTL"用的是同一组常数,参数一改比对自动跟上,
不会出现改了 RTL 忘了改脚本的假通过。

参考模型严格按 RTL 的运算顺序:
  逐像素反色 -> 16x16 累加 -> >>8(向下取整)-> 用同一帧的 min/max 得 rng
  -> off = max(p-lo, 0) -> off > (rng >> TH_SHIFT) ? 255 : 0
注意"逐像素反色后再平均"与"平均后再反色"相差最多 1 LSB,但边界值会被阈值翻转,
所以必须按 RTL 的顺序来,不能图省事。

用法(在仓库根目录):
    python a/check_v2c_frame.py
"""
import sys, os, re
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))

import numpy as np

V2C_V   = os.path.join(PROJECT_ROOT, 'user_source', 'hdl_source', 'cnn', 'video_to_cnn.v')
FRAME   = os.path.join(PROJECT_ROOT, 'user_source', 'hdl_source', 'cnn', 'sim', 'frame720p.mem')
V2C_OUT = os.path.join(PROJECT_ROOT, 'user_source', 'hdl_source', 'cnn', 'sim', 'v2c_out.mem')


def rtl_params(path):
    txt = open(path, 'r', encoding='utf-8', errors='replace').read()
    def get(name):
        m = re.search(r'parameter\s+%s\s*=\s*(\d+)' % name, txt)
        if not m:
            raise SystemExit('在 %s 里找不到 parameter %s' % (path, name))
        return int(m.group(1))
    return {n: get(n) for n in ('INVERT', 'IMG_W', 'IMG_H', 'ROI_SZ',
                                'GRID', 'CELL_LOG2', 'TH_SHIFT', 'MIN_RANGE')}


def read_mem8(path, n):
    with open(path, 'r') as f:
        vals = [int(line, 16) for line in f if line.strip()]
    if len(vals) != n:
        raise SystemExit('%s 里有 %d 个字节,期望 %d' % (path, len(vals), n))
    return np.array(vals, dtype=np.uint8)


def model(frame, P):
    """返回 (28,28) uint8 —— 应当与 RTL 输出逐字节相同。"""
    cell = 1 << P['CELL_LOG2']
    x0 = (P['IMG_W'] - P['ROI_SZ']) // 2
    y0 = (P['IMG_H'] - P['ROI_SZ']) // 2
    roi = frame[y0:y0 + P['ROI_SZ'], x0:x0 + P['ROI_SZ']].astype(np.int32)

    # 1) 逐像素极性(video_to_cnn.v:  S_gray)
    if P['INVERT']:
        roi = 255 - roi

    # 2) col_sum 累加 + >>8
    g = roi.reshape(P['GRID'], cell, P['GRID'], cell)
    bins = g.sum(axis=(1, 3)) >> 8                      # (28,28) int32

    # 3) 用整帧 min/max 得量程(与 S_prev_lo/hi 对应)。TB 连发两帧相同内容,
    #    所以"上一帧的 lo/hi"就等于本帧自己的 min/max。
    lo, hi = int(bins.min()), int(bins.max())
    rng = hi - lo
    if rng < P['MIN_RANGE']:
        return np.zeros((P['GRID'], P['GRID']), dtype=np.uint8)

    # 4) 按量程中点二值化
    th  = rng >> P['TH_SHIFT']
    off = np.maximum(bins - lo, 0)                      # RTL 里有显式下界钳位
    return np.where(off > th, 255, 0).astype(np.uint8)


def show(a, tag):
    print('  %s:' % tag)
    for r in range(a.shape[0]):
        print('    ' + ''.join('#' if v else '.' for v in a[r]))


def main():
    P = rtl_params(V2C_V)
    print('RTL 参数: ' + '  '.join('%s=%d' % kv for kv in sorted(P.items())))

    frame = read_mem8(FRAME, P['IMG_W'] * P['IMG_H']).reshape(P['IMG_H'], P['IMG_W'])
    got = read_mem8(V2C_OUT, P['GRID'] * P['GRID']).reshape(P['GRID'], P['GRID'])
    exp = model(frame, P)

    diff = int(np.count_nonzero(got != exp))
    print('')
    print('RTL 输出: 非零 bin = %d / %d' % (int(np.count_nonzero(got)), got.size))
    print('参考模型: 非零 bin = %d / %d' % (int(np.count_nonzero(exp)), exp.size))
    print('不一致字节 = %d / %d' % (diff, exp.size))

    if diff == 0:
        print('PASS: RTL 的 784 字节与 Python 参考模型逐字节一致')
        return 0

    print('FAIL: 逐字节不一致')
    idx = np.argwhere(got != exp)[:16]
    for r, c in idx:
        print('  idx %3d (row %2d col %2d): got 0x%02X  exp 0x%02X'
              % (r * P['GRID'] + c, r, c, got[r, c], exp[r, c]))
    show(exp, '参考模型')
    show(got, 'RTL 输出')
    return 1


if __name__ == '__main__':
    sys.exit(main())

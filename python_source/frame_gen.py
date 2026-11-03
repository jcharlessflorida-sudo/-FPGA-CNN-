# coding: utf-8
"""生成一帧"摄像头风格"的 1280x720 灰度帧,给 ModelSim 的 video_to_cnn_frame_tb.v 用。

为什么需要它:
  旧的 video_to_cnn_tb.v 用 8 位渐变合成图案验证**地址/时序**;
  但它覆盖 IMG_W/IMG_H,而且图案与真实数据无关。
  本脚本产出真实分辨率、真实内容的一帧,让 frame TB 用**默认参数**跑,
  再把 RTL 吐出的 784 字节交给 a/check_v2c_frame.py 与 Python 参考模型逐字节比对
  —— 这样才能证明"RTL 实现的预处理"和"离线研究里那套算法"是同一个东西。

输出:
  user_source/hdl_source/cnn/sim/frame720p.mem
      921600 行,每行 2 位十六进制(8 位灰度),行主序 1280*720。
      TB 读进 reg [7:0] 数组后塞到 24bit 视频数据的 G 通道(video_to_cnn 取 [15:8])。

用法(在仓库根目录):
    python a/frame_gen.py
"""
import sys, os
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
if PROJECT_ROOT not in sys.path:
    sys.path.append(PROJECT_ROOT)

import numpy as np
from hw_preproc_study import render_roi, ROI_SZ

IMG_W, IMG_H = 1280, 720
ROI_X0 = (IMG_W - ROI_SZ) // 2      # 416,与 video_to_cnn.v 的 localparam 一致
ROI_Y0 = (IMG_H - ROI_SZ) // 2      # 136

OUT_MEM = os.path.join(PROJECT_ROOT, 'user_source', 'hdl_source', 'cnn',
                       'sim', 'frame720p.mem')


def build_frame(img28, bg=200, ink=50, digit_px=448, blur=2, grad=8.0):
    """白纸黑字的一帧:纸亮、墨暗,纸面有轻微亮度不均。

    grad 不均匀光照是**故意**加的:它让 784 个 bin 的 min/max 落在任意值上
    (量程不是 2 的幂),从而真正走到 F_msb9 + 移位那一级;
    若整帧只有 0/255 两个电平,移位器的系数怎么算都能过,测不出错。
    """
    w = np.full((IMG_H, IMG_W), float(bg), dtype=np.float32)
    gx = np.linspace(-1.0, 1.0, IMG_W, dtype=np.float32)
    gy = np.linspace(-1.0, 1.0, IMG_H, dtype=np.float32)
    w = w + grad * 0.5 * (gx[None, :] + gy[:, None])

    roi = render_roi(img28, digit_px, bg, ink, blur=blur).astype(np.float32)
    w[ROI_Y0:ROI_Y0 + ROI_SZ, ROI_X0:ROI_X0 + ROI_SZ] = roi

    return np.clip(w, 0, 255).astype(np.uint8)


def write_frame_mem(frame, path):
    with open(path, 'w') as f:
        # 逐行 join 写,别用 92 万次 f.write
        f.write('\n'.join('%02X' % v for v in frame.reshape(-1)))
        f.write('\n')


def main():
    from dataset.mnist import load_mnist

    (_, _), (x_test, t_test) = load_mnist(normalize=False, flatten=False)
    img28 = x_test[0].reshape(28, 28).astype(np.uint8)
    label = int(t_test[0])

    frame = build_frame(img28)
    write_frame_mem(frame, OUT_MEM)

    inroi = frame[ROI_Y0:ROI_Y0 + ROI_SZ, ROI_X0:ROI_X0 + ROI_SZ]
    print('MNIST #0 标签=%d' % label)
    print('写入 %s' % OUT_MEM)
    print('  帧 %dx%d,ROI (%d,%d)-(%d,%d)' % (
        IMG_W, IMG_H, ROI_X0, ROI_Y0, ROI_X0 + ROI_SZ, ROI_Y0 + ROI_SZ))
    print('  ROI 灰度 min=%d max=%d  (纸亮墨暗,期望 min 接近 ink、max 接近纸面+梯度)'
          % (int(inroi.min()), int(inroi.max())))


if __name__ == '__main__':
    main()

# coding: utf-8
"""离线研究:摄像头帧 -> video_to_cnn 降采样 -> CNN 这条链的预处理到底该怎么修。

零 TD 成本地回答三个问题:
  1. 现状(INVERT=0、无任何归一化)准确率有多低?
  2. 只把 INVERT 打开(极性修正)能恢复多少?
  3. INVERT=1 + 上一帧统计的对比度拉伸 + 二值化 能到多少?
     并且:数字在 ROI 里至少要占多少像素?(这条直接决定上板时的取景要求)

用法(在仓库根目录):
    python a/hw_preproc_study.py
"""
import sys, os
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
if PROJECT_ROOT not in sys.path:
    sys.path.append(PROJECT_ROOT)

import numpy as np
import pickle
import quantized_model as qm

# ---------------- 与 video_to_cnn.v 对齐的常量 ----------------
ROI_SZ  = 448      # parameter ROI_SZ  = 448
GRID    = 28       # parameter GRID    = 28
CELL    = ROI_SZ // GRID          # 16
MIN_RANGE_DEFAULT = 24   # 建议的 "画面太平" 保护门限


# ==================== 1. 渲染一帧 "摄像头看到的 ROI" ====================
def render_roi(img28, digit_px, bg, ink, blur=0, noise=0.0, grad=0.0, seed=0):
    """把一张 MNIST 图渲染成摄像头拍到的 448x448 灰度 ROI。

    物理约定:摄像头对着**白纸黑字** —— 纸亮(背景亮)、墨暗(笔画暗)。
    MNIST 的 0=背景、255=笔画,所以映射为:
        scene = bg*(1 - m/255) + ink*(m/255)
    即 MNIST 背景 -> bg(亮),MNIST 笔画 -> ink(暗)。这与 MNIST 的极性**相反**,
    正是 INVERT 参数存在的理由。

    digit_px: 数字在 ROI 里的边长(像素)。448 = 理想(每个 bin 恰好等于一个 MNIST 像素)。
    blur    : 高斯模糊 sigma(像素),模拟镜头/对焦。
    noise   : 高斯噪声 sigma(灰度级)。
    grad    : 光照梯度幅度(灰度级),模拟纸面亮度不均。
    """
    m = img28.astype(np.float32)

    # 最近邻放大到 digit_px,再居中贴到 ROI_SZ 的画布上
    idx = (np.arange(digit_px) * GRID) // digit_px
    idx = np.clip(idx, 0, GRID - 1)
    big = m[np.ix_(idx, idx)]

    canvas = np.full((ROI_SZ, ROI_SZ), 0.0, dtype=np.float32)
    off = (ROI_SZ - digit_px) // 2
    canvas[off:off + digit_px, off:off + digit_px] = big

    # MNIST 值域 -> 场景亮度
    scene = bg * (1.0 - canvas / 255.0) + ink * (canvas / 255.0)

    if grad:
        gy = np.linspace(-1.0, 1.0, ROI_SZ, dtype=np.float32)
        gx = np.linspace(-1.0, 1.0, ROI_SZ, dtype=np.float32)
        scene = scene + grad * 0.5 * (gx[None, :] + gy[:, None])

    if blur > 0:
        scene = _box_blur(scene, max(1, int(round(blur))))

    if noise > 0:
        rng = np.random.RandomState(seed)
        scene = scene + rng.normal(0.0, noise, scene.shape).astype(np.float32)

    return np.clip(scene, 0, 255).astype(np.uint8)


def _box_blur(a, r):
    """可分离的均值模糊(用积分图实现,避免 scipy 依赖)。"""
    k = 2 * r + 1
    pad = np.pad(a, r, mode='edge')
    c = np.cumsum(np.cumsum(pad, axis=0), axis=1)
    c = np.pad(c, ((1, 0), (1, 0)), mode='constant')
    h, w = a.shape
    ys = np.arange(h) + k
    xs = np.arange(w) + k
    s = (c[np.ix_(ys, xs)] - c[np.ix_(ys - k, xs)]
         - c[np.ix_(ys, xs - k)] + c[np.ix_(ys - k, xs - k)])
    return (s / float(k * k)).astype(np.float32)


# ==================== 2. 与 RTL 逐比特一致的降采样 ====================
def rtl_bins(roi):
    """复刻 video_to_cnn.v:col_sum 累加 16x16 后 >>8(算术右移,即 floor(mean))。
    行主序 addr = by*28 + bx,与 cnn_top.v:96 的 (row*28+col) 一致。"""
    g = roi.reshape(GRID, CELL, GRID, CELL).astype(np.int32)
    return (g.sum(axis=(1, 3)) >> 8).astype(np.int32)   # (28,28) 0..255


# ==================== 3. 候选预处理 ====================
def pp_raw(bins, invert):
    """现状:只做(或不做的)反色,无归一化。"""
    b = bins
    if invert:
        b = 255 - b
    return np.clip(b, 0, 255).astype(np.uint8)


def pp_stretch_bin(bins, invert, T=128, min_range=MIN_RANGE_DEFAULT):
    """INVERT + 用整帧 lo/hi 做移位拉伸 + 二值化。

    与计划中的 RTL 完全一致:
        p = INV ? 255-b : b
        k = 7 - msb(hi-lo)          # hi-lo 左移 k 后落在 [128,255]
        s = min(255, (p-lo) << k)
        out = (s >= T) ? 255 : 0
    外加保护:hi-lo < min_range 时整幅输出 0(对着白墙不会出雪花)。
    注:上板时 lo/hi 取**上一帧**的统计量(60fps 滞后 16ms);本脚本单帧比较,
    用本帧统计量即可代表第 2 帧以后的行为。
    """
    p = bins.astype(np.int32)
    if invert:
        p = 255 - p
    lo, hi = int(p.min()), int(p.max())
    rng = hi - lo
    if rng < min_range:
        return np.zeros((GRID, GRID), dtype=np.uint8)
    msb = int(np.floor(np.log2(rng)))
    k = 7 - msb
    s = (p - lo) << k
    s = np.clip(s, 0, 255)
    return np.where(s >= T, 255, 0).astype(np.uint8)


def pp_mid(bins, invert, min_range=MIN_RANGE_DEFAULT):
    """INVERT + 用整帧 lo/hi 拉伸 + **阈值取量程中点**(替代固定 T)。

    与 pp_stretch_bin 的唯一区别:判定条件是 "偏离 lo 超过半个量程",而不是
    "拉伸后的值超过固定 T"。硬件上更省:不需要移位器、不需要饱和到 255,
    只要 `(p - lo) > (rng >> 1)` 一个比较器。

    为什么它应当更好:场景近似二值(纸 / 墨),16x16 平均后 bin 分布是双峰的
    (纯纸 -> lo,纯墨 -> hi,边缘 bin 落在中间),分母量中点就是自然判决面。
    而固定 T 的物理含义随量程漂移 —— 同一帧 rng=150 时 s 只到 150,
    rng=210 时 s 到 210,于是 T=128 在一个场景里是"前 15%",在另一个里是"前 40%"。
    模糊会压低笔画峰值,中点跟着 hi 一起降,固定 T 不会。
    """
    p = bins.astype(np.int32)
    if invert:
        p = 255 - p
    lo, hi = int(p.min()), int(p.max())
    rng = hi - lo
    if rng < min_range:
        return np.zeros((GRID, GRID), dtype=np.uint8)
    return np.where((p - lo) > (rng >> 1), 255, 0).astype(np.uint8)


def pp_frac(bins, invert, num=1, den=2, min_range=MIN_RANGE_DEFAULT):
    """pp_mid 的可调比例推广:判定条件 `(p - lo) > rng * num / den`。

    num/den = 1/2 时与 pp_mid **逐比特等价**(`(rng*1)//2 == rng>>1`),
    因此这一行同时是 pp_mid 的回归自检。

    比例越大 ⇒ 阈值越高 ⇒ 判成"墨"的 bin 越少 ⇒ 笔画越细。

    动机(只是假设,必须用实验 G 的数据判):量程中点对**细笔画偏松**。
    若整幅没有任何一个 bin 被笔画填满(笔画比 16px 还窄,或对焦偏软),
    `hi` 就低于真实墨色,阈值跟着被压低 ⇒ 整条笔画变粗 ⇒
    **闭合数字(0/6/8/9)的圈/洞被糊死** —— 正好是用户报告的差类。
    """
    p = bins.astype(np.int32)
    if invert:
        p = 255 - p
    lo, hi = int(p.min()), int(p.max())
    rng = hi - lo
    if rng < min_range:
        return np.zeros((GRID, GRID), dtype=np.uint8)
    return np.where((p - lo) > (rng * num) // den, 255, 0).astype(np.uint8)


# 实验 G 要扫的比例。全部分母为 2 的幂 ⇒ 上板时可用"乘常数 + 移位"实现。
FRACTIONS = [(1, 2), (9, 16), (5, 8), (11, 16), (3, 4)]


# ==================== 4. 评测 ====================
def evaluate(pipeline, imgs, labels, **kw):
    """imgs: (N,28,28) uint8 的 MNIST 图。返回 top-1 准确率。"""
    correct = 0
    for i in range(len(labels)):
        roi = render_roi(imgs[i], **kw)
        bins = rtl_bins(roi)
        px = pipeline(bins)
        if int(qm.forward_int(px, Q).argmax()) == int(labels[i]):
            correct += 1
    return correct / float(len(labels))


def evaluate_detail(pipeline, imgs, labels, **kw):
    """同 evaluate,但额外返回每类召回率(长度 10)。

    recall[c] = 真值为 c 且被预测为 c 的样本数 / 真值为 c 的样本数。

    为什么必须分类别看:总准确率会把问题平摊掉。用户报告的差类是
    0/6/8/9(闭合数字),它们只占 40% 样本 —— 就算这几类全崩,
    总数也只掉十几个点,在总准确率里看不出"是哪一类坏了",
    更看不出某个改动是**救了 0/6/8/9 还是拉平了别的类**。
    """
    nc = 10
    hit = [0] * nc
    tot = [0] * nc
    for i in range(len(labels)):
        roi = render_roi(imgs[i], **kw)
        bins = rtl_bins(roi)
        px = pipeline(bins)
        pred = int(qm.forward_int(px, Q).argmax())
        c = int(labels[i])
        tot[c] += 1
        if pred == c:
            hit[c] += 1
    acc = sum(hit) / float(sum(tot))
    recall = [(hit[c] / float(tot[c])) if tot[c] else float('nan')
              for c in range(nc)]
    return acc, recall


def main():
    from dataset.mnist import load_mnist
    global Q

    with open(os.path.join(PROJECT_ROOT, 'a', 'params_fpga.pkl'), 'rb') as f:
        params = pickle.load(f)

    (_, _), (x_test, t_test) = load_mnist(normalize=False, flatten=False)
    N = 300
    imgs = x_test[:N].reshape(N, 28, 28).astype(np.uint8)
    labels = t_test[:N].astype(np.int64)

    x_float = x_test[:2000].astype(np.float32) / 255.0
    S1, S2 = qm.calibrate(params, x_float)
    Q = qm.quantize_params(params, S1, S2)
    print('S1=%d S2=%d  评测样本 N=%d' % (S1, S2, N))

    # --- 基线:直接把 MNIST 原图喂进量化模型,确认评测链路本身是对的 ---
    base = sum(1 for i in range(N)
               if int(qm.forward_int(imgs[i], Q).argmax()) == labels[i])
    print('基线(直接喂 MNIST 原图)                 : %.4f' % (base / float(N)))

    # ================= 实验 A:理想取景,扫各条流水线 =================
    print('\n=== A. 理想取景(digit=448, bg=200, ink=50),扫流水线 ===')
    ideal = dict(digit_px=448, bg=200, ink=50)
    Cfgs = [
        ('现状: INVERT=0, 无归一化',      lambda b: pp_raw(b, False)),
        ('只开反色: INVERT=1',            lambda b: pp_raw(b, True)),
        ('INVERT=1 + 拉伸 + 二值化 T=96',  lambda b: pp_stretch_bin(b, True, T=96)),
        ('INVERT=1 + 拉伸 + 二值化 T=128', lambda b: pp_stretch_bin(b, True, T=128)),
        ('INVERT=1 + 拉伸 + 二值化 T=160', lambda b: pp_stretch_bin(b, True, T=160)),
    ]
    for name, fn in Cfgs:
        print('  %-34s: %.4f' % (name, evaluate(fn, imgs, labels, **ideal)))

    # ================= 实验 B:取景大小(数字占 ROI 多大才够)=================
    print('\n=== B. 取景大小(bg=200, ink=50, INVERT=1+拉伸+二值化 T=128)===')
    print('  数字边长 / ROI 占比 / 笔画跨度(格) / 准确率')
    fn = lambda b: pp_stretch_bin(b, True, T=128)
    for d in (448, 384, 320, 256, 224, 192, 160, 112):
        acc = evaluate(fn, imgs, labels, digit_px=d, bg=200, ink=50)
        print('  %4d px   %5.1f%%   %5.1f 格      %.4f'
              % (d, 100.0 * d / ROI_SZ, d / float(CELL), acc))

    # ================= 实验 C:光照 / 对比度(固定理想取景,单独看对比度)=================
    print('\n=== C. 光照与对比度(digit=448, INVERT=1+拉伸+二值化 T=128)===')
    print('  纸(背景) / 墨(笔画) / 原始对比度 / 准确率')
    for bg, ink in ((200, 50), (160, 60), (120, 70), (100, 80),
                    (90, 82), (240, 30), (140, 130), (60, 45)):
        acc = evaluate(fn, imgs, labels, digit_px=448, bg=bg, ink=ink)
        print('  bg=%3d   ink=%3d   %3d        %.4f' % (bg, ink, bg - ink, acc))

    # ================= 实验 D:噪声 / 模糊 / 光照不均 =================
    print('\n=== D. 鲁棒性(digit=320, bg=200, ink=50, INVERT=1+拉伸+二值化 T=128)===')
    for kw, tag in (
        (dict(noise=5.0),  '噪声 sigma=5'),
        (dict(noise=15.0), '噪声 sigma=15'),
        (dict(blur=3),     '模糊 r=3'),
        (dict(blur=6),     '模糊 r=6'),
        (dict(grad=20.0),  '光照梯度 ±10'),
        (dict(noise=10.0, blur=3, grad=15.0), '噪声+模糊+梯度'),
    ):
        acc = evaluate(fn, imgs, labels, digit_px=320, bg=200, ink=50, **kw)
        print('  %-24s: %.4f' % (tag, acc))

    # ================= 实验 E:阈值 T 的敏感性 =================
    print('\n=== E. 阈值 T 敏感性(bg=200, ink=50)===')
    print('   T      digit=448   digit=384   digit=320')
    for T in (64, 80, 96, 112, 128, 144, 160):
        row = []
        for d in (448, 384, 320):
            row.append(evaluate(lambda b, T=T: pp_stretch_bin(b, True, T=T),
                                imgs, labels, digit_px=d, bg=200, ink=50))
        print('  T=%3d :   %.4f      %.4f      %.4f' % (T, row[0], row[1], row[2]))

    # ================= 实验 F:固定 T vs 量程中点(跨条件)=================
    # 这一表决定 RTL 里到底用哪种判决。固定 T 只能在一种量程下调好;
    # 中点应当在整个条件网格上都不掉队。
    print('\n=== F. 固定阈值 vs 量程中点(同一批条件下横向比较)===')
    conds = [
        ('理想 448',          dict(digit_px=448, bg=200, ink=50)),
        ('取景 384',          dict(digit_px=384, bg=200, ink=50)),
        ('取景 320',          dict(digit_px=320, bg=200, ink=50)),
        ('低对比 160/60',     dict(digit_px=448, bg=160, ink=60)),
        ('低对比 120/70',     dict(digit_px=448, bg=120, ink=70)),
        ('高对比 240/30',     dict(digit_px=448, bg=240, ink=30)),
        ('模糊 r=3 @320',     dict(digit_px=320, bg=200, ink=50, blur=3)),
        ('模糊 r=6 @320',     dict(digit_px=320, bg=200, ink=50, blur=6)),
        ('噪声 15 @320',      dict(digit_px=320, bg=200, ink=50, noise=15.0)),
        ('光照梯度 @320',     dict(digit_px=320, bg=200, ink=50, grad=20.0)),
    ]
    pipes = [
        ('T=80',  lambda b: pp_stretch_bin(b, True, T=80)),
        ('T=96',  lambda b: pp_stretch_bin(b, True, T=96)),
        ('T=128', lambda b: pp_stretch_bin(b, True, T=128)),
        ('中点',  lambda b: pp_mid(b, True)),
    ]
    print('  %-18s %8s %8s %8s %8s' % ('条件', 'T=80', 'T=96', 'T=128', '中点'))
    tot = [0.0] * 4
    for cname, kw in conds:
        vals = [evaluate(fn, imgs, labels, **kw) for _, fn in pipes]
        for j in range(4):
            tot[j] += vals[j]
        print('  %-18s %8.4f %8.4f %8.4f %8.4f%s'
              % (cname, vals[0], vals[1], vals[2], vals[3],
                 '   <= 最好' if max(vals) == vals[3] else ''))
    print('  %-18s %8.4f %8.4f %8.4f %8.4f' % ('平均', tot[0]/len(conds),
                                               tot[1]/len(conds),
                                               tot[2]/len(conds), tot[3]/len(conds)))

    # ================= 实验 G:阈值比例扫描 + 分类别召回 =================
    # 这是本轮"便宜调参"的判决性实验,决策规则先写死(见下文注释),不许事后找理由。
    # 重点看 0/6/8/9 的召回 —— 用户报的差类就这四个闭合数字。
    HI = (0, 6, 8, 9)

    # G0 自检:1/2 必须与 pp_mid 逐比特相同(两条代码路径不同,容易悄悄分叉)
    print('\n=== G0. pp_frac(1/2) vs pp_mid 等价性自检 ===')
    roi = render_roi(imgs[0], digit_px=448, bg=200, ink=50)
    b = rtl_bins(roi)
    if np.array_equal(pp_frac(b, True, 1, 2), pp_mid(b, True)):
        print('  OK: pp_frac(b,1,2) == pp_mid(b) 逐比特相同')
    else:
        print('  ** 不一致! 下面的 1/2 行不能当作 pp_mid 的参考 **')

    print('\n=== G. 阈值比例扫描(bg=200, ink=50, INVERT=1)===')
    print('  比例越大 => 阈值越高 => 笔画越细。 * 标出 0/6/8/9 召回。')
    for d in (448, 384):
        print('\n  --- 数字边长 digit_px=%d (占 ROI %.1f%%)---'
              % (d, 100.0 * d / ROI_SZ))
        hdr = '  %-8s %-8s' % ('比例', '总准确率')
        for c in range(10):
            hdr += '  %4d' % c
        print(hdr + '   <- 每类召回(%)')
        for num, den in FRACTIONS:
            acc, rec = evaluate_detail(
                lambda b, n=num, d_=den: pp_frac(b, True, n, d_),
                imgs, labels, digit_px=d, bg=200, ink=50)
            row = '  %-8s %-8.4f' % ('%d/%d' % (num, den), acc)
            for c in range(10):
                mark = '*' if c in HI else ' '
                row += ' %3.0f%s' % (100.0 * rec[c], mark)
            print(row)
        # 闭合类的平均召回,单独拎出来看(总准确率会把它稀释掉)
        for num, den in FRACTIONS:
            _, rec = evaluate_detail(
                lambda b, n=num, d_=den: pp_frac(b, True, n, d_),
                imgs, labels, digit_px=d, bg=200, ink=50)
            avg_hi = sum(rec[c] for c in HI) / 4.0
            print('    %d/%d 闭合类(0/6/8/9)平均召回: %.4f' % (num, den, avg_hi))

    # 决策规则(先写死):
    #   若某比例让 0/6/8/9 召回明显上升、且总准确率不降
    #     => 改 RTL: video_to_cnn.v 的 TH_SHIFT 换成 TH_NUM/TH_DEN,
    #        然后重跑 a/check_v2c_frame.py + cnn/sim/video_to_cnn_frame_tb.v;
    #   若各比例都差不多
    #     => 阈值不是主因,RTL **不动**。剩下的差距来自"手写数字 != MNIST 归一化几何",
    #        要再往上必须做"本次不做"里的自动归一化(COM 居中 + 缩放到 20/28)。
    print('\n  判读见源码 main() 末尾的决策规则注释。')


if __name__ == '__main__':
    main()

# coding: utf-8
"""统计 anlogic_logo_rom.v 的稀疏度与 ink 包围盒。

目的:评估"把 logo 放回去"到底要花多少逻辑。
  该 ROM 是 160x160 x 25bit 的**稀疏组合 case**(只有 6387 条非零项),
  TD 会为它造一个 15bit 全译码器 —— 上板实测这占了约 9% 的 slices(1918 个),
  把利用率从 73.75% 推到 82.79%,进而让 CNN 的 100MHz 域从 14 个违规端点涨到 136 个。

本脚本回答两个决定性问题:
  1. ink 包围盒有多大? 如果远小于 160x160,窗口/地址可以收紧(纯裁剪,不动图像)。
  2. 2 倍降采样后还剩多少条非零项? 这直接决定"缩小 logo"能省下多少逻辑。

用法(仓库根目录):
    python a/logo_rom_stats.py
"""
import os
import re

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
ROM = os.path.join(PROJECT_ROOT, 'user_source', 'hdl_source', 'anlogic_logo_rom.v')

W = 160
H = 160

rx = re.compile(r"15'd(\d+)\s*:\s*O_pixel\s*=\s*25'h([0-9a-fA-F]+)")


def load():
    px = {}
    with open(ROM, 'r', encoding='utf-8', errors='replace') as f:
        for m in rx.finditer(f.read()):
            px[int(m.group(1))] = int(m.group(2), 16)
    return px


def main():
    px = load()
    print('ROM 文件: %s' % os.path.basename(ROM))
    print('地址空间      : %d x %d = %d' % (W, H, W * H))
    print('非零项(带墨)  : %d (%.1f%% of 地址空间)'
          % (len(px), 100.0 * len(px) / (W * H)))

    xs = [a % W for a in px]
    ys = [a // W for a in px]
    print('ink 包围盒    : x %d..%d (宽 %d)   y %d..%d (高 %d)'
          % (min(xs), max(xs), max(xs) - min(xs) + 1,
             min(ys), max(ys), max(ys) - min(ys) + 1))

    bw = max(xs) - min(xs) + 1
    bh = max(ys) - min(ys) + 1
    print('  => 若把窗口裁到包围盒: 地址空间 %d -> %d (%.0f%%),非零项不变'
          % (W * H, bw * bh, 100.0 * bw * bh / (W * H)))

    # ---- 2 倍降采样: 2x2 取平均(RGB) + OR(不透明位) ----
    def at(x, y):
        return px.get(y * W + x, None)

    ds = {}
    for by in range(0, H, 2):
        for bx in range(0, W, 2):
            acc = [0, 0, 0]
            op = 0
            n = 0
            for dy in (0, 1):
                for dx in (0, 1):
                    v = at(bx + dx, by + dy)
                    if v is None:
                        continue
                    n += 1
                    op |= (v >> 24) & 1
                    acc[0] += (v >> 16) & 0xFF
                    acc[1] += (v >> 8) & 0xFF
                    acc[2] += v & 0xFF
            if n == 0 or op == 0:
                continue
            # 只在"有墨"的 2x2 块里平均,避免把背景拉进来冲淡颜色
            r, g, b = (c // n for c in acc)
            ds[(by // 2) * (W // 2) + (bx // 2)] = (1 << 24) | (r << 16) | (g << 8) | b

    print('')
    print('2倍降采样(80x80):')
    print('  地址空间      : %d' % ((W // 2) * (H // 2)))
    print('  非零项        : %d (原 %d, 降到 %.0f%%)'
          % (len(ds), len(px), 100.0 * len(ds) / len(px)))
    print('  => 组合 case 的逻辑量大致按"非零项数"走,若 1918 slices -> 约 %d slices'
          % (1918 * len(ds) // len(px)))


if __name__ == '__main__':
    main()

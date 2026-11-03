# coding: utf-8
"""校对 roi_overlay.v 画的框 与 video_to_cnn.v 真正采样的 ROI 是不是同一个矩形。

为什么值得单独写个脚本:
  画的框是给操作者看的,CNN 采的是 RTL 里的常数。两者一旦漂移(改了一个忘了另一个),
  框就变成**骗人的** —— 数字明明在框里却认不出,而操作者会以为问题在别处。
  参数在两个文件里各写一遍,靠人眼保证一致是不靠谱的,这里机器校对。

另外一个交叉检查:roi_overlay.v 的 S_x/S_y 计数器必须与 video_to_cnn.v 同构,
  否则框和采样区在**时间**上错开(框看着对、采的却是别的区域)。
  这里做的是文本级结构比对,不是逐比特等价 —— 足以抓住"改了一处忘了另一处"。

用法(在仓库根目录):
    python a/check_roi_overlay.py
"""
import os, re, sys

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
HDL = os.path.join(PROJECT_ROOT, 'user_source', 'hdl_source')

V2C = os.path.join(HDL, 'cnn', 'video_to_cnn.v')
ROI = os.path.join(HDL, 'roi_overlay.v')


def txt(path):
    return open(path, 'r', encoding='utf-8', errors='replace').read()


def params(path):
    t = txt(path)
    out = {}
    for m in re.finditer(r'parameter\s+(\w+)\s*=\s*([^,\n)]+)', t):
        out[m.group(1)] = m.group(2).strip()
    return out


def localparams(path):
    t = txt(path)
    out = {}
    for m in re.finditer(r'localparam\s+(\w+)\s*=\s*([^;\n]+)', t):
        out[m.group(1)] = m.group(2).strip()
    return out


def main():
    a = params(V2C)
    b = params(ROI)
    la = localparams(V2C)

    bad = 0

    # ---- 1. 尺寸必须一致 ----
    for k in ('IMG_W', 'IMG_H'):
        va, vb = a.get(k), b.get(k)
        ok = (va == vb)
        bad += 0 if ok else 1
        print('  %-8s video_to_cnn=%-6s roi_overlay=%-6s  %s'
              % (k, va, vb, 'OK' if ok else '不一致 <-- 修'))

    # ---- 2. ROI 矩形:video_to_cnn 是从 IMG 推出来的 localparam,roi_overlay 是显式参数 ----
    exp_x0 = '(%s - %s) / 2' % (a['IMG_W'], a['ROI_SZ'])
    exp_y0 = '(%s - %s) / 2' % (a['IMG_H'], a['ROI_SZ'])
    pairs = [('ROI_SZ', a.get('ROI_SZ'), b.get('ROI_SZ')),
             ('ROI_X0', exp_x0,           b.get('ROI_X0')),
             ('ROI_Y0', exp_y0,           b.get('ROI_Y0'))]
    for k, va, vb in pairs:
        # 把 '((1280 - 448) / 2)' 这类式子求值后比数字
        try:
            na = eval(re.sub(r'/(?=\d)', '/', va)) if va else None
        except Exception:
            na = None
        try:
            nb = eval(vb) if vb else None
        except Exception:
            nb = None
        if k == 'ROI_SZ':
            ok = (str(va) == str(vb))
        else:
            ok = (na == nb)
        bad += 0 if ok else 1
        print('  %-8s video_to_cnn=%-18s -> %-5s roi_overlay=%-6s -> %-5s  %s'
              % (k, va, na, vb, nb, 'OK' if ok else '不一致 <-- 修'))

    # ---- 3. video_to_cnn 里真正的 ROI 判定常数(局部参数)也报出来 ----
    print('  video_to_cnn 的 localparam: %s'
          % ', '.join('%s=%s' % kv for kv in sorted(la.items())))

    # ---- 4. 计数器同构 ----
    cnt = "if (I_video_de) begin"
    ok_de = (cnt in txt(V2C)) and (cnt in txt(ROI))
    ok_last = ('if (I_video_last) begin' in txt(V2C)) and \
              ('if (I_video_last) begin' in txt(ROI))
    bad += 0 if (ok_de and ok_last) else 1
    print('  x/y 计数器同构(都在 de 上自增、在 last 上 y+1): %s'
          % ('OK' if (ok_de and ok_last) else '不一致 <-- 框会和采样区错位'))

    print('')
    if bad == 0:
        print('PASS: 取景框就是 CNN 实际采样区')
        return 0
    print('FAIL: %d 处不一致' % bad)
    return 1


if __name__ == '__main__':
    sys.exit(main())

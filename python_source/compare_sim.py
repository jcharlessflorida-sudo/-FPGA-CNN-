# coding: utf-8
"""对比 ModelSim 输出 sim_logits.txt 与量化参考 expected_logits.txt 是否逐比特一致。"""
import sys, os
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
if PROJECT_ROOT not in sys.path:
    sys.path.append(PROJECT_ROOT)
import numpy as np

SIM_DIR = os.path.join(PROJECT_ROOT, 'user_source', 'hdl_source', 'cnn', 'sim')


def main():
    exp_path = os.path.join(SIM_DIR, 'expected_logits.txt')
    sim_path = os.path.join(SIM_DIR, 'sim_logits.txt')

    exp = {}
    with open(exp_path) as f:
        for line in f:
            if not line.strip():
                continue
            parts = line.split()
            n = int(parts[0])
            label = int(parts[1])
            logs = np.array([int(x) for x in parts[2:12]], dtype=np.int32)
            exp[n] = (label, logs)

    sim = {}
    with open(sim_path) as f:
        for line in f:
            if not line.strip():
                continue
            parts = line.split()
            n = int(parts[0])
            cls = int(parts[1])
            logs = np.array([int(x) for x in parts[2:12]], dtype=np.int32)
            sim[n] = (cls, logs)

    if set(exp.keys()) != set(sim.keys()):
        print('数量不一致: expected=%d  sim=%d' % (len(exp), len(sim)))
        print('expected 缺:', sorted(set(exp.keys()) - set(sim.keys())))
        print('sim 缺:', sorted(set(sim.keys()) - set(exp.keys())))
        return

    mism = 0
    correct = 0
    total = 0
    for n in sorted(exp):
        label, logs_e = exp[n]
        cls_s, logs_s = sim[n]
        total += 1
        if not np.array_equal(logs_s, logs_e):
            mism += 1
            if mism <= 5:
                print('logit mismatch @ image %d' % n)
                print('  sim:', logs_s.tolist())
                print('  exp:', logs_e.tolist())
        exp_cls = int(logs_e.argmax())
        if cls_s != exp_cls:
            print('class mismatch @ image %d (sim %d exp %d)' % (n, cls_s, exp_cls))
        if exp_cls == label:
            correct += 1

    print('bit-exact logits: %d/%d' % (total - mism, total))
    print('subset accuracy : %d/%d = %.4f' % (correct, total, correct / total))
    if mism == 0:
        print('ALL LOGITS MATCH (bit-exact)')


if __name__ == '__main__':
    main()

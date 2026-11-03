# coding: utf-8
"""在完整 MNIST 测试集(10k)上评估量化后参考模型的 top-1 准确率。"""
import sys, os
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
if PROJECT_ROOT not in sys.path:
    sys.path.append(PROJECT_ROOT)
import numpy as np
import pickle
import quantized_model as qm


def main():
    from dataset.mnist import load_mnist

    params_path = os.path.join(PROJECT_ROOT, 'a', 'params_fpga.pkl')
    with open(params_path, 'rb') as f:
        params = pickle.load(f)

    (_, _), (x_test, t_test) = load_mnist(normalize=False, flatten=False)
    x_float = x_test[:2000].astype(np.float32) / 255.0
    S1, S2 = qm.calibrate(params, x_float)
    q = qm.quantize_params(params, S1, S2)
    print('S1=%d  S2=%d' % (S1, S2))

    correct = 0
    N = x_test.shape[0]
    for i in range(N):
        logits = qm.forward_int(x_test[i].reshape(28, 28), q)
        if int(logits.argmax()) == int(t_test[i]):
            correct += 1
    print('quantized accuracy: %d/%d = %.4f' % (correct, N, correct / N))


if __name__ == '__main__':
    main()

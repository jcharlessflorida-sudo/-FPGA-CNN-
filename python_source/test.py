# coding: utf-8
import os
import sys

import cv2
import numpy as np

PROJECT_ROOT = os.path.abspath(os.path.dirname(__file__))
if PROJECT_ROOT not in sys.path:
    sys.path.append(PROJECT_ROOT)

from simple_convnet import SimpleConvNet

MODEL_PATH = os.path.join(PROJECT_ROOT, "params.pkl")


def load_network():
    """加载已训练好的卷积网络参数；如果不存在则提示用户先训练。"""
    net = SimpleConvNet(
        input_dim=(1, 28, 28),
        conv_param={'filter_num': 30, 'filter_size': 3, 'pad': 0, 'stride': 1},
        hidden_size=100,
        output_size=10,
        weight_init_std=0.01,
    )

    if not os.path.exists(MODEL_PATH):
        print("未找到 params.pkl")
        print("请先执行：python train_convnet.py")
        print("并确保训练完成后，当前目录下会生成 params.pkl")
        return None

    net.load_params(MODEL_PATH)
    print("已加载模型参数：", MODEL_PATH)
    return net


def preprocess_frame(frame):
    """将摄像头帧裁成中心区域，然后转成 28x28 灰度图，适配你当前的 CNN 输入。"""
    h, w = frame.shape[:2]
    box = min(h, w)
    x0 = (w - box) // 2
    y0 = (h - box) // 2
    roi = frame[y0:y0 + box, x0:x0 + box]

    gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)

    # 根据当前 ROI 的整体亮度自动选择暗底/亮底策略。
    # MNIST 训练样本的标准规律是：背景亮、前景暗，因此最终需要把分割结果
    # 映射成“白背景 + 黑数字”的形式。
    if np.mean(gray) > 127:
        _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    else:
        _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)

    # 去除小噪点，减少亮背景/皮肤导致的“整体白化”
    kernel = np.ones((3, 3), np.uint8)
    binary = cv2.morphologyEx(binary, cv2.MORPH_OPEN, kernel)

    if np.count_nonzero(binary) < 50:
        return None, (x0, y0, box)

    # 把分割出的前景转换成与 MNIST 一致的亮背景/暗数字形式
    img = 255 - binary
    resized = cv2.resize(img, (28, 28), interpolation=cv2.INTER_AREA)
    x = resized.astype(np.float32) / 255.0
    x = x.reshape(1, 1, 28, 28)
    cv2.imshow("Processed Input", resized)
    return x, (x0, y0, box)


def draw_ui(frame, pred, prob, box_info):
    x0, y0, box = box_info
    cv2.rectangle(frame, (x0, y0), (x0 + box, y0 + box), (0, 255, 255), 2)
    cv2.putText(
        frame,
        f"Pred: {pred}  Conf: {prob:.3f}",
        (20, 40),
        cv2.FONT_HERSHEY_SIMPLEX,
        1.0,
        (0, 255, 0),
        2,
    )
    cv2.putText(
        frame,
        "Press Q to quit",
        (20, frame.shape[0] - 20),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.7,
        (255, 255, 255),
        2,
    )


def main():
    net = load_network()
    if net is None:
        return

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("无法打开摄像头，请确认摄像头已连接并可用。")
        return

    print("正在启动实时识别，屏幕中央区域请放数字。按 Q 键退出。")

    while True:
        ret, frame = cap.read()
        if not ret:
            print("摄像头读取失败")
            break

        frame = cv2.flip(frame, 1)
        x, box_info = preprocess_frame(frame)
        
        if x is not None:
            logits = net.predict(x)
            pred = int(np.argmax(logits[0]))
            confidence = pred
            draw_ui(frame, pred, confidence, box_info)
        else:
            cv2.putText(
                frame,
                "Put a number in the box",
                (20, 40),
                cv2.FONT_HERSHEY_SIMPLEX,
                1.0,
                (0, 0, 255),
                2,
            )
            cv2.rectangle(frame, (box_info[0], box_info[1]), (box_info[0] + box_info[2], box_info[1] + box_info[2]), (0, 0, 255), 2)

        cv2.imshow("Real-time MNIST Digit Recognition", frame)

        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()

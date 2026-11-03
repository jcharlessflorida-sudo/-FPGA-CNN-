# run_v2c_frame.do — 真实 1280x720 帧 + 默认参数的预处理算术验证(需在 cnn/ 目录下执行)
#
# 前置:先跑 `python a/frame_gen.py` 生成 sim/frame720p.mem。
# 跑完:sim/v2c_out.mem 里是 RTL 输出的 784 字节,交给
#       `python a/check_v2c_frame.py` 与 Python 参考模型逐字节比对。
#
# 注意:eram_model.v 提供 PH1P_LOGIC_ERAM 行为模型(ModelSim 无真实原语)。
vlib work
vmap work work
vlog video_to_cnn.v
vlog sim/eram_model.v
vlog sim/video_to_cnn_frame_tb.v
vsim -c work.video_to_cnn_frame_tb
run -all
quit -f

# run_v2c.do — 验证 video_to_cnn 降采样 + 双时钟 ERAM 读回(需在 cnn/ 目录下执行)
# 注意:eram_model.v 提供 PH1P_LOGIC_ERAM 行为模型(ModelSim 无真实原语)。
vlib work
vmap work work
vlog video_to_cnn.v
vlog sim/eram_model.v
vlog sim/video_to_cnn_tb.v
vsim -c work.video_to_cnn_tb
run -all
quit -f

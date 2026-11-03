# run_msim.do — 编译并运行 CNN 测试台(需在 cnn/ 目录下执行,使相对路径生效)
vlib work
vmap work work
vlog cnn_mac.v
vlog +define+SIM cnn_top.v
vlog sim/cnn_tb.v
vsim -c work.cnn_tb
run -all
quit -f

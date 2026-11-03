# run_probe.do - 需要 cnn/ 目录下执行(相对路径)
vlib work
vmap work work
vlog cnn_mac.v
vlog +define+SIM cnn_top.v
vlog sim/cnn_probe_tb.v
vsim -c work.cnn_probe_tb
run -all
quit -f

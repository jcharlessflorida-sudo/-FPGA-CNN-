# run_logo_half.do — 用全分辨率原厂 ROM 交叉验证 2 倍降采样版
# 需在 cnn/ 目录下执行: vsim -c -do run_logo_half.do
# (vlog 之前必须先 vlib work,否则报 vlog-19 Failed to access library 'work')
vlib work
vmap work work
vlog ../anlogic_logo_rom.v
vlog ../anlogic_logo_rom_half.v
vlog sim/logo_half_tb.v
vsim -c work.logo_half_tb
run -all
quit -f

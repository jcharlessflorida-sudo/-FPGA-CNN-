# run_gamma.do — 验证显示 gamma 校正模块(gamma_corr.v,纯组合零延迟)
# 需在 cnn/ 目录下执行: vsim -c -do run_gamma.do
vlib work
vmap work work
vlog ../gamma_corr.v
vlog sim/gamma_corr_tb.v
vsim -c work.gamma_corr_tb
run -all
quit -f

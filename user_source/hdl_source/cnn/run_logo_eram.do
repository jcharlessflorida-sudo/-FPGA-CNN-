# run_logo_eram.do - cnn/ 目录下跑:验证 weights/logo_80x80.dat(ERAM 的 INIT_FILE)
# 与已验证的 anlogic_logo_rom_half 逐字相同。用法(在 cnn/ 下):
#   vsim -c -do run_logo_eram.do
vlib work
vmap work work
vlog ../anlogic_logo_rom_half.v
vlog sim/logo_eram_tb.v
vsim -c work.logo_eram_tb
run -all
quit -f

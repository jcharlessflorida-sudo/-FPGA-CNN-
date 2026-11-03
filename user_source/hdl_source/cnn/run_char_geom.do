# run_char_geom.do - 字模几何自检(需在 cnn/ 目录下执行)
vlib work
vmap work work
vlog ../osd_char_lib.v
vlog sim/char_lib_geom_tb.v
vsim -c work.char_lib_geom_tb
run -all
quit -f

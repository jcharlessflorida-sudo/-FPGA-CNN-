# run_fps.do - FPS 显示逻辑仿真(需在 cnn/ 目录下执行,相对路径)
vlib work
vmap work work
vlog sim/eram_model.v
vlog logo_rom_eram.v
vlog ../hdmi_mixer.v
vlog ../osd_char_lib.v
vlog sim/fps_mixer_tb.v
vsim -c work.fps_mixer_tb
run -all
quit -f

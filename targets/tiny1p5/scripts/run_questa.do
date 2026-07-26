transcript on
if {[file exists work]} { vdel -lib work -all }
vlib work
vlog -sv ../../rtl/supervisor/fpst_sync_bit.sv \
         ../../rtl/supervisor/fpst_sync_rise_pulse.sv \
         ../../rtl/supervisor/fpst_ms_tick.sv \
         ../../rtl/supervisor/fpst_debounce_active_low.sv \
         ../../rtl/supervisor/fpst_heartbeat_watchdog.sv \
         ../../rtl/supervisor/fpst_supervisor_core.sv \
         ../../tb/supervisor/tb_fpst_heartbeat_watchdog.sv \
         ../../tb/supervisor/tb_fpst_debounce_active_low.sv \
         ../../tb/supervisor/tb_fpst_supervisor_core.sv
foreach tb {tb_fpst_heartbeat_watchdog tb_fpst_debounce_active_low tb_fpst_supervisor_core} {
    vsim -c work.$tb -do "run -all; quit -f"
}
quit -f

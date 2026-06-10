# Headless ILA capture of the fmap_dm_acp M_AXI_MM2S AR+R channel during a single
# DataMover transfer (dbg_step_03). Touches only the PL device (xck26_0) / ILA —
# never the APU DAP (arm_dap_1) — so the JTAG Reset Catch cannot bite.
# Trigger: fmap_acp ARVALID rising. This capture only proves the MM2S AXI read
# side; it does not observe the downstream MM2S AXIS stream or status channel.
set t0 [clock seconds]
open_hw_manager
catch {connect_hw_server}
open_hw_target
current_hw_device [get_hw_devices xck26_0]
set dev [current_hw_device]
set_property PROBES.FILE /home/hwkim/v9.ltx $dev
set_property FULL_PROBES.FILE /home/hwkim/v9.ltx $dev
refresh_hw_device $dev
set ila [get_hw_ilas -of_objects $dev hw_ila_1]
set arv [get_hw_probes {pccx_v002_system_i/system_ila_0/inst/net_slot_0_axi_arvalid} -of_objects $ila]
set_property TRIGGER_COMPARE_VALUE eq1'bR $arv
set_property CONTROL.TRIGGER_POSITION 64 $ila
run_hw_ila $ila
after 1000
puts "ARMED at [expr {[clock seconds]-$t0}]s; firing stimulus over SSH..."
exec ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no ubuntu@192.168.219.108 \
    {cd /home/ubuntu/pccx-gemma-deploy && sudo env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/home/ubuntu/pccx-gemma-deploy python3 -B debug/dbg_step_03_cmdsts_single_acp.py} \
    >& /tmp/stim_local.log &
set ta [clock seconds]
set ok [expr {![catch {wait_on_hw_ila -timeout 1 $ila} e]}]
puts "WAIT returned after [expr {[clock seconds]-$ta}]s ok=$ok note=\"$e\""
if {$ok} {
    puts "TRIGGERED=YES"
    set d [upload_hw_ila_data $ila]
    catch {write_hw_ila_data -force -csv_file /tmp/cap_fmap_acp.csv $d}
    catch {write_hw_ila_data -force /tmp/cap_fmap_acp.ila $d}
    puts "WROTE /tmp/cap_fmap_acp.csv + .ila"
} else {
    puts "TRIGGERED=NO  => no MM2S ARVALID observed in the capture window"
}
catch {close_hw_target}
catch {disconnect_hw_server}
puts "CAPTURE_DONE"

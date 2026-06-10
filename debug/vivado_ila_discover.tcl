# Headless discovery: open the JTAG target for ILA capture WITHOUT touching the
# APU processor targets (ILA lives on the PL fabric TAP, so Reset Catch can't bite).
# Lists devices / ILAs / arvalid probes so the capture script uses exact names.
puts "STEP open_hw_manager"
open_hw_manager
if {[catch {connect_hw_server} e]} { puts "connect_hw_server note: $e" }
puts "HWSERVER [current_hw_server]"
if {[catch {open_hw_target} e]} { puts "OPEN_TARGET_ERR $e"; exit 2 }
puts "TARGET [current_hw_target]"
puts "DEVICES_BEGIN"
foreach d [get_hw_devices] { puts "  dev=$d" }
puts "DEVICES_END"
set dev [lindex [get_hw_devices xck26*] 0]
if {$dev eq ""} { set dev [lindex [get_hw_devices] end] }
puts "SELECTED_DEV $dev"
current_hw_device $dev
if {[catch {
    set_property PROBES.FILE /home/hwkim/v9.ltx $dev
    set_property FULL_PROBES.FILE /home/hwkim/v9.ltx $dev
    refresh_hw_device $dev
} e]} { puts "LTX_REFRESH_ERR $e" }
puts "ILAS_BEGIN"
foreach ila [get_hw_ilas] {
    puts "  ILA=$ila"
    if {[catch {get_hw_probes -of_objects $ila} pr]} { set pr "ERR:$pr" }
    foreach p $pr { puts "    probe= $p" }
}
puts "ILAS_END"
catch {close_hw_target}
catch {disconnect_hw_server}
puts "DISCOVERY_DONE"

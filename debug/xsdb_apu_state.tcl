# Read-only ZynqMP target/core state via the already-running hw_server.
# Purpose: determine if the APU (Cortex-A53) cores are halted/held by the JTAG
# debugger (explains silent APU console while SC prints Pwr-On) vs genuinely
# not booting. NO state-changing commands (no stop/rst/con).
puts "xsdb-diag: connecting to hw_server..."
if {[catch {connect} res]} { puts "CONNECT_ERR: $res"; exit 1 }
puts "CONNECTED: $res"
after 500
if {[catch {targets} res]} { puts "TARGETS_ERR: $res"; exit 1 }
puts "=== TARGETS (state in parens) ==="
puts $res
puts "=== per-core state ==="
foreach pat {"Cortex-A53 #0" "Cortex-A53 #1" "Cortex-A53 #2" "Cortex-A53 #3"} {
    if {[catch {targets -set -nocase -filter "name =~ \"*$pat*\""} e]} {
        puts "$pat: no-target ($e)"; continue
    }
    if {[catch {state} st]} { set st "?" }
    if {[catch {rrd pc} pc]} { set pc "?" }
    puts "$pat: state=$st  pc=$pc"
}
exit 0

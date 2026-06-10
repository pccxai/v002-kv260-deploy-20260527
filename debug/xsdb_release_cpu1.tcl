# Release Cortex-A53 #1 from the JTAG "Reset Catch" that froze it, which made the
# kernel's kick_all_cpus_sync() IPI wait forever (the documented SMP soft-lockup).
# Resuming #1 lets the pending all-CPU sync complete so boot can proceed.
connect
puts "=== before ==="
targets
targets -set -nocase -filter {name =~ "*Cortex-A53 #1*"}
if {[catch {con} e]} { puts "CON_ERR #1: $e" } else { puts "resumed Cortex-A53 #1" }
after 3000
puts "=== after (did #1 enter kernel space ffff8000..?) ==="
targets
exit

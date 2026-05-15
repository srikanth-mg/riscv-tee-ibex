## ============================================================================
## create_project.tcl
##
## One-shot Vivado project creation for TEE standalone RTL sim + synthesis.
## Run from Vivado TCL console:
##   cd C:/Users/srika/OneDrive/Desktop/Capstone_Project
##   source create_project.tcl
##
## What this script does:
##   1. Creates a new project targeting Artix-7 (xc7a35ticsg324-1L)
##   2. Adds all 6 TEE RTL modules
##   3. Adds tee_rtl_tb.sv as the simulation top
##   4. Sets simulator settings and runtime
##   5. Ready for "Run Simulation" or "Run Synthesis"
## ============================================================================

# --- Configuration ----------------------------------------------------------
set project_name  "tee_standalone"
set project_dir   [pwd]
set src_dir       [pwd]
set part_name     "xc7z020clg400-1"

# --- Create / overwrite project ---------------------------------------------
if {[file exists "$project_dir/$project_name"]} {
    puts "Removing existing project directory: $project_dir/$project_name"
    file delete -force "$project_dir/$project_name"
}

create_project $project_name $project_dir/$project_name -part $part_name -force

# --- Add RTL sources (package first, then leaves, then top) -----------------
# Order matters in Vivado for SystemVerilog packages
add_files -norecurse [list \
    "$src_dir/tee_pkg.sv"             \
    "$src_dir/tee_pmp_controller.sv"  \
    "$src_dir/tee_csr_unit.sv"        \
    "$src_dir/tee_register_file.sv"   \
    "$src_dir/tee_security_engine.sv" \
    "$src_dir/tee_top.sv"             \
]

# Mark all .sv files as SystemVerilog
set_property file_type SystemVerilog [get_files *.sv]

# Set tee_top as synthesis top (used for synth runs)
set_property top tee_top [current_fileset]

# --- Add simulation source --------------------------------------------------
add_files -fileset sim_1 -norecurse "$src_dir/tee_rtl_tb.sv"
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1] *.sv]
set_property top tee_rtl_tb [get_filesets sim_1]

# --- Simulation settings ----------------------------------------------------
set_property -name {xsim.simulate.runtime} -value {2us} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {true} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.saif_scope} -value {tee_rtl_tb/u_dut} -objects [get_filesets sim_1]

# --- Update compile order ---------------------------------------------------
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts ""
puts "============================================================"
puts " Project created: $project_dir/$project_name"
puts " Top (synth): tee_top"
puts " Top (sim):   tee_rtl_tb"
puts ""
puts " Next steps:"
puts "   launch_simulation                  ; # run behavioral sim"
puts "   launch_runs synth_1 -jobs 4        ; # run synthesis"
puts "   wait_on_run synth_1                ; # wait for synth"
puts "   open_run synth_1                   ; # open synth results"
puts "   report_utilization -file util.rpt  ; # area report"
puts "   report_timing_summary -file tim.rpt; # timing report"
puts "============================================================"

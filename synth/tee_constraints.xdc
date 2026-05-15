## ============================================================================
## tee_constraints.xdc - Timing constraints for TEE standalone synthesis
## What this file does (interview knowledge):
##   - create_clock      : defines the master clock and its period
##   - clock_uncertainty : accounts for jitter + skew in real silicon
##   - input/output_delay: budgets I/O setup/hold time at FPGA pins
##   - set_false_path    : excludes paths that don't need timing analysis
## ============================================================================

## ----------------------------------------------------------------------------
## Primary clock definition
## ----------------------------------------------------------------------------
## clk_i is the master clock for the entire TEE design.

create_clock -period 20.000 -name sys_clk -waveform {0.000 10.000} [get_ports clk_i]

## ----------------------------------------------------------------------------
## Clock uncertainty (jitter + skew margin)
## ----------------------------------------------------------------------------
## Setup uncertainty: pessimism for setup analysis
##   = clock jitter + clock skew + margin

set_clock_uncertainty -setup 0.500 [get_clocks sys_clk]
set_clock_uncertainty -hold  0.050 [get_clocks sys_clk]

## ----------------------------------------------------------------------------
## Input/output delays
## ----------------------------------------------------------------------------

set_input_delay  -clock sys_clk 2.000 [all_inputs]
set_output_delay -clock sys_clk 2.000 [all_outputs]

## ----------------------------------------------------------------------------
## Async reset - false path
## ----------------------------------------------------------------------------
## rst_ni is asynchronously asserted, synchronously de-asserted.
## Its timing is NOT a data-path concern - exclude it from STA.

set_false_path -from [get_ports rst_ni]

## ----------------------------------------------------------------------------
## Exclude clk_i itself from input_delay analysis
## ----------------------------------------------------------------------------
## clk_i is the clock source, not a data input.
## set_input_delay on all_inputs would otherwise wrongly include it.

set_input_delay 0 -clock sys_clk [get_ports clk_i]


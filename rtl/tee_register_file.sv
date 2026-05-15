// ============================================================================
// tee_register_file.sv — Register File with TEE Extensions
//
// Standard 32x32 RISC-V register file (x0 hardwired to 0) with:
//   1. Shadow register bank — parallel save/restore for host context
//   2. Hardware scrub — zero all registers in one cycle
//   3. Two read ports (rs1, rs2) + one write port (rd) for pipeline
//   4. Bulk read port (all 31 regs) for SE context save
//
// x0 is always 0 — writes to x0 are discarded.
// ============================================================================

module tee_register_file
  import tee_pkg::*;
#(
  parameter int unsigned DATA_WIDTH = TEE_DATA_WIDTH,
  parameter int unsigned NUM_REGS   = TEE_NUM_REGS    // 32
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // --------------------------------------------------------------------------
  // Pipeline read ports (combinational — reads in same cycle)
  // --------------------------------------------------------------------------
  input  logic [4:0]              rs1_addr_i,
  output logic [DATA_WIDTH-1:0]   rs1_data_o,

  input  logic [4:0]              rs2_addr_i,
  output logic [DATA_WIDTH-1:0]   rs2_data_o,

  // --------------------------------------------------------------------------
  // Pipeline write port
  // --------------------------------------------------------------------------
  input  logic [4:0]              rd_addr_i,
  input  logic [DATA_WIDTH-1:0]   rd_data_i,
  input  logic                    rd_we_i,

  // --------------------------------------------------------------------------
  // TEE bulk interface (Security Engine)
  // --------------------------------------------------------------------------
  // Bulk read — all registers at once (for context save)
  output logic [DATA_WIDTH-1:0]   bulk_rdata_o [1:31],

  // Hardware scrub — zero all registers in one cycle
  input  logic                    scrub_i,

  // Restore from shadow bank
  input  logic                    restore_i,
  input  logic [DATA_WIDTH-1:0]   shadow_data_i [1:31]
);

  // ==========================================================================
  // Register Storage
  // ==========================================================================
  logic [DATA_WIDTH-1:0] regs_q [NUM_REGS];  // x0-x31
  //
  // x0 is hardwired to 0 by gating: writes to rd_addr_i==0 are blocked, and
  // regs_q[0] is initialized to 0 on reset and never updated thereafter. The
  // synthesizer will optimize regs_q[0] to a constant tie (no FF inferred).
  // No continuous assignment is used here — that would conflict with the
  // flip-flops inferred by the always_ff block, producing a multi-driver
  // warning.


  // ==========================================================================
  // Register Write Logic
  //
  // Priority (highest to lowest):
  //   1. Reset → all zeros
  //   2. Scrub → all zeros (one cycle, from SE)
  //   3. Restore → load from shadow bank (one cycle, from SE)
  //   4. Normal pipeline write → single register
  // ==========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Reset all 32 registers (x0 stays 0 forever after this)
      for (int i = 0; i < NUM_REGS; i++) begin
        regs_q[i] <= '0;
      end
    end else if (scrub_i) begin
      // HARDWARE SCRUB: Zero all registers in one cycle
      // This is a security feature — prevents information leakage
      // between host and enclave during context switches.
      //
      // Implementation: one AND gate per register bit, gated by scrub signal.
      // When scrub=1, all write ports are driven to zero simultaneously.
      // Cost: negligible (one gate per flip-flop)
      // Benefit: 31 cycles (software loop) → 1 cycle (hardware)
      for (int i = 1; i < NUM_REGS; i++) begin
        regs_q[i] <= '0;
      end
    end else if (restore_i) begin
      // SHADOW RESTORE: Load all registers from shadow bank in one cycle
      // Used during enclave exit to restore host context.
      // Shadow bank is part of the Security Engine, protected by PMP0 LOCKED.
      for (int i = 1; i < NUM_REGS; i++) begin
        regs_q[i] <= shadow_data_i[i];
      end
    end else if (rd_we_i && rd_addr_i != 5'd0) begin
      // Normal pipeline write (single register)
      regs_q[rd_addr_i] <= rd_data_i;
    end
  end

  // ==========================================================================
  // Read Ports (combinational — data available same cycle)
  // ==========================================================================
  // Pipeline read port 1 (rs1)
  assign rs1_data_o = (rs1_addr_i == 5'd0) ? '0 : regs_q[rs1_addr_i];

  // Pipeline read port 2 (rs2)
  assign rs2_data_o = (rs2_addr_i == 5'd0) ? '0 : regs_q[rs2_addr_i];

  // Bulk read for SE context save
  generate
    for (genvar i = 1; i < NUM_REGS; i++) begin : gen_bulk_read
      assign bulk_rdata_o[i] = regs_q[i];
    end
  endgenerate

endmodule

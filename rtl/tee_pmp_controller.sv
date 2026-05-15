// ============================================================================
// tee_pmp_controller.sv — Physical Memory Protection Controller
//
// Modified PMP implementation for TEE:
//   1. Parallel address matching (all 16 entries checked simultaneously)
//   2. Fixed-latency priority encoder (constant-time, no timing side-channel)
//   3. Fast-path activation port for atomic PMP reconfiguration
//
// Interfaces with Ibex pipeline at IF stage (fetch check) and EX stage 
// (load/store check). PMP check runs in parallel with memory access — 
// NOT an extra pipeline stage.
//
// RISC-V Privileged Spec v1.12, Section 3.7
// ============================================================================

module tee_pmp_controller
  import tee_pkg::*;
#(
  parameter int unsigned NUM_ENTRIES = TEE_NUM_PMP,
  parameter int unsigned ADDR_WIDTH  = TEE_ADDR_WIDTH
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // --------------------------------------------------------------------------
  // Address check interface (from pipeline — two ports: IF and EX)
  // --------------------------------------------------------------------------
  // Instruction fetch check (IF stage)
  input  logic [ADDR_WIDTH-1:0]   if_addr_i,
  input  logic                    if_valid_i,
  output logic                    if_granted_o,
  output logic                    if_fault_o,

  // Data access check (EX stage)
  input  logic [ADDR_WIDTH-1:0]   ex_addr_i,
  input  logic                    ex_valid_i,
  input  logic                    ex_read_i,
  input  logic                    ex_write_i,
  output logic                    ex_granted_o,
  output logic                    ex_fault_o,

  // Current privilege level (from CSR unit)
  input  priv_lvl_e               priv_lvl_i,

  // --------------------------------------------------------------------------
  // PMP CSR read/write interface (from CSR unit)
  // --------------------------------------------------------------------------
  input  logic                    csr_pmp_wr_i,
  input  logic [3:0]              csr_pmp_idx_i,
  input  logic [7:0]              csr_pmp_cfg_i,
  input  logic [ADDR_WIDTH-1:0]   csr_pmp_addr_i,
  input  logic                    csr_pmp_cfg_wr_i,    // writing config
  input  logic                    csr_pmp_addr_wr_i,   // writing address

  // CSR read-back
  output logic [7:0]              csr_pmp_cfg_o  [NUM_ENTRIES],
  output logic [ADDR_WIDTH-1:0]   csr_pmp_addr_o [NUM_ENTRIES],

  // --------------------------------------------------------------------------
  // Fast-path activation from Security Engine
  // --------------------------------------------------------------------------
  input  logic                    fast_activate_i,
  input  logic [3:0]              fast_pmp_idx_i,
  input  logic [7:0]              fast_pmp_cfg_i,

  // --------------------------------------------------------------------------
  // Enclave status (for enclave-aware checking)
  // --------------------------------------------------------------------------
  input  logic                    enclave_active_i,
  input  logic [3:0]              active_enclave_id_i
);

  // ==========================================================================
  // PMP Register Bank
  // ==========================================================================
  pmp_cfg_t                    pmp_cfg_q   [NUM_ENTRIES];
  logic [ADDR_WIDTH-1:0]       pmp_addr_q  [NUM_ENTRIES];

  // Expose for CSR reads
  generate
    for (genvar i = 0; i < NUM_ENTRIES; i++) begin : gen_csr_readback
      assign csr_pmp_cfg_o[i]  = {pmp_cfg_q[i].lock,
                                   pmp_cfg_q[i].reserved,
                                   pmp_cfg_q[i].addr_mode,
                                   pmp_cfg_q[i].x,
                                   pmp_cfg_q[i].w,
                                   pmp_cfg_q[i].r};
      assign csr_pmp_addr_o[i] = pmp_addr_q[i];
    end
  endgenerate

  // ==========================================================================
  // PMP Register Write Logic
  // ==========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Reset: all PMP entries disabled
      for (int i = 0; i < NUM_ENTRIES; i++) begin
        pmp_cfg_q[i]  <= '{lock: 1'b0, reserved: 2'b00, 
                            addr_mode: PMP_MODE_OFF,
                            x: 1'b0, w: 1'b0, r: 1'b0};
        pmp_addr_q[i] <= '0;
      end
    end else begin
      // Fast-path activation (from Security Engine) — highest priority
      if (fast_activate_i) begin
        // Only write if entry is not locked
        if (!pmp_cfg_q[fast_pmp_idx_i].lock) begin
          pmp_cfg_q[fast_pmp_idx_i] <= pmp_cfg_t'(fast_pmp_cfg_i);
        end
      end
      // Normal CSR write path
      else if (csr_pmp_wr_i) begin
        if (csr_pmp_cfg_wr_i && !pmp_cfg_q[csr_pmp_idx_i].lock) begin
          pmp_cfg_q[csr_pmp_idx_i] <= pmp_cfg_t'(csr_pmp_cfg_i);
        end
        if (csr_pmp_addr_wr_i && !pmp_cfg_q[csr_pmp_idx_i].lock) begin
          pmp_addr_q[csr_pmp_idx_i] <= csr_pmp_addr_i;
        end
      end
    end
  end

  // ==========================================================================
  // STEP 1: Compute Region Bounds (TOR mode)
  //
  // For TOR addressing: region i covers [pmpaddr[i-1], pmpaddr[i])
  // For entry 0: lower bound is 0
  // ==========================================================================
  logic [ADDR_WIDTH-1:0] region_lower [NUM_ENTRIES];
  logic [ADDR_WIDTH-1:0] region_upper [NUM_ENTRIES];

  assign region_lower[0] = '0;
  generate
    for (genvar i = 1; i < NUM_ENTRIES; i++) begin : gen_lower
      assign region_lower[i] = pmp_addr_q[i-1];
    end
    for (genvar i = 0; i < NUM_ENTRIES; i++) begin : gen_upper
      assign region_upper[i] = pmp_addr_q[i];
    end
  endgenerate

  // ==========================================================================
  // STEP 2: Parallel Address Matching
  //
  // All 16 comparisons happen simultaneously in one gate delay.
  // This is the key security improvement over Ibex's cascading MUX.
  // ==========================================================================
  logic [NUM_ENTRIES-1:0] if_match;
  logic [NUM_ENTRIES-1:0] ex_match;

  generate
    for (genvar i = 0; i < NUM_ENTRIES; i++) begin : gen_match
      logic entry_active;
      assign entry_active = (pmp_cfg_q[i].addr_mode != PMP_MODE_OFF);

      // IF stage match
      assign if_match[i] = entry_active &&
                           (if_addr_i >= region_lower[i]) &&
                           (if_addr_i <  region_upper[i]);

      // EX stage match
      assign ex_match[i] = entry_active &&
                           (ex_addr_i >= region_lower[i]) &&
                           (ex_addr_i <  region_upper[i]);
    end
  endgenerate

  // ==========================================================================
  // STEP 3: Fixed-Latency Priority Encoder
  //
  // Find the lowest-numbered matching entry.
  // Logic depth = log2(NUM_ENTRIES) = 4 levels for 16 entries.
  // Constant timing regardless of which entry matches.
  //
  // This is implemented as a reverse loop — the last assignment wins,
  // but since we go from high to low index, the lowest match takes priority.
  // Synthesis produces a fixed-depth priority tree.
  // ==========================================================================
  logic [$clog2(NUM_ENTRIES)-1:0] if_winner_idx;
  logic                           if_any_match;
  logic [$clog2(NUM_ENTRIES)-1:0] ex_winner_idx;
  logic                           ex_any_match;

  // IF stage priority encoder
  always_comb begin
    if_winner_idx = '0;
    if_any_match  = 1'b0;
    for (int i = NUM_ENTRIES - 1; i >= 0; i--) begin
      if (if_match[i]) begin
        if_winner_idx = i[$clog2(NUM_ENTRIES)-1:0];
        if_any_match  = 1'b1;
      end
    end
  end

  // EX stage priority encoder
  always_comb begin
    ex_winner_idx = '0;
    ex_any_match  = 1'b0;
    for (int i = NUM_ENTRIES - 1; i >= 0; i--) begin
      if (ex_match[i]) begin
        ex_winner_idx = i[$clog2(NUM_ENTRIES)-1:0];
        ex_any_match  = 1'b1;
      end
    end
  end

  // ==========================================================================
  // STEP 4: Permission Check
  //
  // Rules (RISC-V Privileged Spec v1.12, Section 3.7.1):
  //   - M-mode: access always granted UNLESS entry is locked (L=1)
  //   - S/U-mode: access granted only if matching entry has required permission
  //   - No match for S/U-mode: access DENIED (deny-by-default)
  //   - No match for M-mode: access GRANTED (M-mode has full access by default)
  // ==========================================================================

  // IF stage (instruction fetch — needs X permission)
  always_comb begin
    if (!if_valid_i) begin
      if_granted_o = 1'b0;
      if_fault_o   = 1'b0;
    end else if (priv_lvl_i == PRIV_M) begin
      // M-mode: always granted unless locked entry denies it
      if (if_any_match && pmp_cfg_q[if_winner_idx].lock && 
          !pmp_cfg_q[if_winner_idx].x) begin
        if_granted_o = 1'b0;
        if_fault_o   = 1'b1;
      end else begin
        if_granted_o = 1'b1;
        if_fault_o   = 1'b0;
      end
    end else begin
      // S/U-mode
      if (if_any_match) begin
        if_granted_o = pmp_cfg_q[if_winner_idx].x;
        if_fault_o   = !pmp_cfg_q[if_winner_idx].x;
      end else begin
        // No match → deny by default
        if_granted_o = 1'b0;
        if_fault_o   = 1'b1;
      end
    end
  end

  // EX stage (data access — needs R or W permission)
  always_comb begin
    if (!ex_valid_i) begin
      ex_granted_o = 1'b0;
      ex_fault_o   = 1'b0;
    end else if (priv_lvl_i == PRIV_M) begin
      // M-mode: always granted unless locked entry denies it
      if (ex_any_match && pmp_cfg_q[ex_winner_idx].lock) begin
        logic perm_ok;
        perm_ok = (ex_read_i  && pmp_cfg_q[ex_winner_idx].r) ||
                  (ex_write_i && pmp_cfg_q[ex_winner_idx].w) ||
                  (!ex_read_i && !ex_write_i);
        ex_granted_o = perm_ok;
        ex_fault_o   = !perm_ok;
      end else begin
        ex_granted_o = 1'b1;
        ex_fault_o   = 1'b0;
      end
    end else begin
      // S/U-mode
      if (ex_any_match) begin
        logic perm_ok;
        perm_ok = (ex_read_i  && pmp_cfg_q[ex_winner_idx].r) ||
                  (ex_write_i && pmp_cfg_q[ex_winner_idx].w) ||
                  (!ex_read_i && !ex_write_i);
        ex_granted_o = perm_ok;
        ex_fault_o   = !perm_ok;
      end else begin
        // No match → deny by default
        ex_granted_o = 1'b0;
        ex_fault_o   = 1'b1;
      end
    end
  end

endmodule

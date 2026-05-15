// ============================================================================
// tee_top.sv — Top-Level TEE Integration
//
// Integrates all TEE components into a single module that interfaces
// with the Ibex pipeline (or simplified standalone pipeline for testing).
//
// Module hierarchy:
//   tee_top
//   ├── tee_security_engine   — Hardware SM FSM
//   ├── tee_pmp_controller    — Parallel-match PMP
//   ├── tee_csr_unit          — Standard + custom CSRs
//   └── tee_register_file     — Register file with shadow bank + scrub
//
// Integration points with Ibex:
//   1. IF stage → PMP fetch check (if_addr, if_valid → if_granted/if_fault)
//   2. EX stage → PMP data check (ex_addr, ex_valid → ex_granted/ex_fault)
//   3. EX stage → ecall detection → routes to Security Engine
//   4. CSR instructions → CSR unit (standard + custom CSR access)
//   5. mret instruction → CSR unit privilege restore + pipeline redirect
// ============================================================================

module tee_top
  import tee_pkg::*;
#(
  parameter int unsigned DATA_WIDTH   = TEE_DATA_WIDTH,
  parameter int unsigned ADDR_WIDTH   = TEE_ADDR_WIDTH,
  parameter int unsigned NUM_PMP      = TEE_NUM_PMP,
  parameter int unsigned NUM_ENCLAVES = TEE_NUM_ENCLAVES
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // --------------------------------------------------------------------------
  // Instruction fetch interface (IF stage)
  // --------------------------------------------------------------------------
  input  logic [ADDR_WIDTH-1:0]   if_addr_i,
  input  logic                    if_valid_i,
  output logic                    if_granted_o,
  output logic                    if_fault_o,

  // --------------------------------------------------------------------------
  // Data access interface (EX stage)
  // --------------------------------------------------------------------------
  input  logic [ADDR_WIDTH-1:0]   ex_addr_i,
  input  logic                    ex_valid_i,
  input  logic                    ex_read_i,
  input  logic                    ex_write_i,
  output logic                    ex_granted_o,
  output logic                    ex_fault_o,

  // --------------------------------------------------------------------------
  // Pipeline control
  // --------------------------------------------------------------------------
  input  logic                    ecall_insn_i,
  input  logic [DATA_WIDTH-1:0]   ecall_a3_i,     // enclave size for CREATE (a3)
  input  logic                    mret_insn_i,
  input  logic [ADDR_WIDTH-1:0]   pc_i,           // current PC (for trap)
  output logic                    pipeline_flush_o,
  output logic                    mret_trigger_o,
  output logic [ADDR_WIDTH-1:0]   trap_target_o,   // mtvec or mepc for redirect

  // --------------------------------------------------------------------------
  // Register file pipeline interface
  // --------------------------------------------------------------------------
  input  logic [4:0]              rs1_addr_i,
  output logic [DATA_WIDTH-1:0]   rs1_data_o,
  input  logic [4:0]              rs2_addr_i,
  output logic [DATA_WIDTH-1:0]   rs2_data_o,
  input  logic [4:0]              rd_addr_i,
  input  logic [DATA_WIDTH-1:0]   rd_data_i,
  input  logic                    rd_we_i,

  // --------------------------------------------------------------------------
  // CSR interface (from decode stage)
  // --------------------------------------------------------------------------
  input  logic [11:0]             csr_addr_i,
  input  logic [DATA_WIDTH-1:0]   csr_wdata_i,
  input  logic                    csr_we_i,
  input  logic                    csr_re_i,
  output logic [DATA_WIDTH-1:0]   csr_rdata_o,
  output logic                    csr_illegal_o,

  // --------------------------------------------------------------------------
  // Memory interface (simplified — for standalone testing)
  // --------------------------------------------------------------------------
  output logic [ADDR_WIDTH-1:0]   dmem_addr_o,
  output logic [DATA_WIDTH-1:0]   dmem_wdata_o,
  output logic                    dmem_we_o,
  output logic                    dmem_re_o,
  input  logic [DATA_WIDTH-1:0]   dmem_rdata_i,

  // --------------------------------------------------------------------------
  // Status outputs
  // --------------------------------------------------------------------------
  output logic                    enclave_active_o,
  output logic [3:0]              active_enclave_id_o,
  output se_state_e               se_state_o,
  output priv_lvl_e               current_priv_o
);

  // ==========================================================================
  // Internal Wires
  // ==========================================================================

  // Security Engine ↔ Register File
  logic [DATA_WIDTH-1:0]  rf_bulk_rdata [1:31];
  logic                   rf_scrub;
  logic                   rf_restore;
  logic [DATA_WIDTH-1:0]  rf_shadow_data [1:31];

  // Security Engine ↔ PMP Controller (fast-path)
  logic                   se_pmp_fast_activate;
  logic [3:0]             se_pmp_fast_idx;
  logic [7:0]             se_pmp_fast_cfg;

  // Security Engine ↔ PMP Controller (CSR write path)
  logic                   se_pmp_csr_wr;
  logic [3:0]             se_pmp_csr_idx;
  logic [ADDR_WIDTH-1:0]  se_pmp_csr_addr;
  logic                   se_pmp_csr_addr_wr;
  logic                   se_pmp_csr_cfg_wr;
  logic [7:0]             se_pmp_csr_cfg;

  // Security Engine ↔ CSR Unit
  logic [ADDR_WIDTH-1:0]  se_mepc_wr;
  logic                   se_mepc_wr_en;
  logic [1:0]             se_mpp_wr;
  logic                   se_mpp_wr_en;
  logic [ADDR_WIDTH-1:0]  csr_mepc;
  logic [1:0]             csr_mpp;

  // CSR Unit ↔ PMP Controller
  logic                   csr_pmp_wr;
  logic [3:0]             csr_pmp_idx;
  logic [7:0]             csr_pmp_cfg;
  logic [ADDR_WIDTH-1:0]  csr_pmp_addr;
  logic                   csr_pmp_cfg_wr;
  logic                   csr_pmp_addr_wr;
  logic [7:0]             pmp_cfg_readback  [NUM_PMP];
  logic [ADDR_WIDTH-1:0]  pmp_addr_readback [NUM_PMP];

  // CSR outputs
  logic [ADDR_WIDTH-1:0]  mtvec;
  logic                   mie;
  priv_lvl_e              priv_lvl;

  // Security Engine outputs
  logic                   se_pipeline_flush;
  logic                   se_mret_trigger;
  logic                   se_busy;
  logic                   se_enclave_active;
  logic [3:0]             se_active_id;
  se_state_e              se_state;
  logic                   se_forward_syscall;
  logic [DATA_WIDTH-1:0]  se_return_val;

  // Enclave metadata
  enclave_meta_t          enc_meta [NUM_ENCLAVES];

  // Trap generation
  logic                   trap_gen;
  logic [4:0]             trap_cause;

  // Mux between SE PMP write and CSR PMP write
  logic                   pmp_wr_muxed;
  logic [3:0]             pmp_idx_muxed;
  logic [7:0]             pmp_cfg_muxed;
  logic [ADDR_WIDTH-1:0]  pmp_addr_muxed;
  logic                   pmp_cfg_wr_muxed;
  logic                   pmp_addr_wr_muxed;

  // ==========================================================================
  // PMP Write MUX: Security Engine has priority over CSR writes
  // ==========================================================================
  always_comb begin
    if (se_pmp_fast_activate || se_pmp_csr_wr) begin
      // SE has priority
      pmp_wr_muxed      = 1'b1;
      pmp_idx_muxed     = se_pmp_fast_activate ? se_pmp_fast_idx : se_pmp_csr_idx;
      pmp_cfg_muxed     = se_pmp_fast_activate ? se_pmp_fast_cfg : se_pmp_csr_cfg;
      pmp_addr_muxed    = se_pmp_csr_addr;
      pmp_cfg_wr_muxed  = se_pmp_fast_activate || se_pmp_csr_cfg_wr;
      pmp_addr_wr_muxed = se_pmp_csr_addr_wr;
    end else begin
      // Normal CSR write path
      pmp_wr_muxed      = csr_pmp_wr;
      pmp_idx_muxed     = csr_pmp_idx;
      pmp_cfg_muxed     = csr_pmp_cfg;
      pmp_addr_muxed    = csr_pmp_addr;
      pmp_cfg_wr_muxed  = csr_pmp_cfg_wr;
      pmp_addr_wr_muxed = csr_pmp_addr_wr;
    end
  end

  // ==========================================================================
  // Trap generation (PMP faults → trap to M-mode)
  // ==========================================================================
  always_comb begin
    trap_gen   = 1'b0;
    trap_cause = 5'd0;

    if (if_fault_o) begin
      trap_gen   = 1'b1;
      trap_cause = TRAP_INST_ACCESS;
    end else if (ex_fault_o) begin
      trap_gen   = 1'b1;
      trap_cause = ex_read_i ? TRAP_LOAD_ACCESS : TRAP_STORE_ACCESS;
    end else if (ecall_insn_i) begin
      trap_gen   = 1'b1;
      case (priv_lvl)
        PRIV_U:  trap_cause = TRAP_ECALL_U;
        PRIV_S:  trap_cause = TRAP_ECALL_S;
        PRIV_M:  trap_cause = TRAP_ECALL_M;
        default: trap_cause = TRAP_ECALL_U;
      endcase
    end
  end

  // ==========================================================================
  // Pipeline control output
  // ==========================================================================
  assign pipeline_flush_o = se_pipeline_flush || trap_gen;
  assign mret_trigger_o   = se_mret_trigger || mret_insn_i;
  assign trap_target_o    = mret_insn_i ? csr_mepc : mtvec;

  // ==========================================================================
  // MODULE INSTANTIATIONS
  // ==========================================================================

  // ---- Register File ----
  tee_register_file #(
    .DATA_WIDTH (DATA_WIDTH),
    .NUM_REGS   (TEE_NUM_REGS)
  ) u_regfile (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .rs1_addr_i   (rs1_addr_i),
    .rs1_data_o   (rs1_data_o),
    .rs2_addr_i   (rs2_addr_i),
    .rs2_data_o   (rs2_data_o),
    .rd_addr_i    (rd_addr_i),
    .rd_data_i    (rd_data_i),
    .rd_we_i      (rd_we_i && !se_busy),  // block writes when SE is active
    .bulk_rdata_o (rf_bulk_rdata),
    .scrub_i      (rf_scrub),
    .restore_i    (rf_restore),
    .shadow_data_i(rf_shadow_data)
  );

  // ---- PMP Controller ----
  tee_pmp_controller #(
    .NUM_ENTRIES (NUM_PMP),
    .ADDR_WIDTH  (ADDR_WIDTH)
  ) u_pmp (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .if_addr_i         (if_addr_i),
    .if_valid_i        (if_valid_i),
    .if_granted_o      (if_granted_o),
    .if_fault_o        (if_fault_o),
    .ex_addr_i         (ex_addr_i),
    .ex_valid_i        (ex_valid_i),
    .ex_read_i         (ex_read_i),
    .ex_write_i        (ex_write_i),
    .ex_granted_o      (ex_granted_o),
    .ex_fault_o        (ex_fault_o),
    .priv_lvl_i        (priv_lvl),
    .csr_pmp_wr_i      (pmp_wr_muxed),
    .csr_pmp_idx_i     (pmp_idx_muxed),
    .csr_pmp_cfg_i     (pmp_cfg_muxed),
    .csr_pmp_addr_i    (pmp_addr_muxed),
    .csr_pmp_cfg_wr_i  (pmp_cfg_wr_muxed),
    .csr_pmp_addr_wr_i (pmp_addr_wr_muxed),
    .csr_pmp_cfg_o     (pmp_cfg_readback),
    .csr_pmp_addr_o    (pmp_addr_readback),
    .fast_activate_i   (se_pmp_fast_activate),
    .fast_pmp_idx_i    (se_pmp_fast_idx),
    .fast_pmp_cfg_i    (se_pmp_fast_cfg),
    .enclave_active_i  (se_enclave_active),
    .active_enclave_id_i(se_active_id)
  );

  // ---- Security Engine ----
  tee_security_engine #(
    .NUM_ENCLAVES (NUM_ENCLAVES),
    .DATA_WIDTH   (DATA_WIDTH),
    .ADDR_WIDTH   (ADDR_WIDTH)
  ) u_se (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),
    .ecall_insn_i        (ecall_insn_i),
    .ecall_a0_i          (rs1_data_o),  // a0 = x10
    .ecall_a1_i          (rs2_data_o),  // a1 = x11 (via register read)
    .ecall_a2_i          (rd_data_i),   // a2 passed via data bus
    .ecall_a3_i          (ecall_a3_i),  // a3 = enclave size (CREATE)
    .current_priv_i      (priv_lvl),
    .pipeline_flush_o    (se_pipeline_flush),
    .mret_trigger_o      (se_mret_trigger),
    .se_busy_o           (se_busy),
    .rf_rdata_i          (rf_bulk_rdata),
    .rf_scrub_o          (rf_scrub),
    .rf_restore_o        (rf_restore),
    .rf_shadow_o         (rf_shadow_data),
    .pmp_fast_activate_o (se_pmp_fast_activate),
    .pmp_fast_idx_o      (se_pmp_fast_idx),
    .pmp_fast_cfg_o      (se_pmp_fast_cfg),
    .pmp_csr_wr_o        (se_pmp_csr_wr),
    .pmp_csr_idx_o       (se_pmp_csr_idx),
    .pmp_csr_addr_o      (se_pmp_csr_addr),
    .pmp_csr_addr_wr_o   (se_pmp_csr_addr_wr),
    .pmp_csr_cfg_wr_o    (se_pmp_csr_cfg_wr),
    .pmp_csr_cfg_o       (se_pmp_csr_cfg),
    .mepc_wr_o           (se_mepc_wr),
    .mepc_wr_en_o        (se_mepc_wr_en),
    .mpp_wr_o            (se_mpp_wr),
    .mpp_wr_en_o         (se_mpp_wr_en),
    .mepc_rd_i           (csr_mepc),
    .mpp_rd_i            (csr_mpp),
    .enclave_active_o    (se_enclave_active),
    .active_enclave_id_o (se_active_id),
    .se_state_o          (se_state),
    .enclave_meta_o      (enc_meta),
    .return_val_o        (se_return_val),
    .forward_to_smode_o  (se_forward_syscall)
  );

  // ---- CSR Unit ----
  tee_csr_unit #(
    .DATA_WIDTH   (DATA_WIDTH),
    .ADDR_WIDTH   (ADDR_WIDTH),
    .NUM_ENCLAVES (NUM_ENCLAVES),
    .NUM_PMP      (NUM_PMP)
  ) u_csr (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),
    .csr_addr_i          (csr_addr_i),
    .csr_wdata_i         (csr_wdata_i),
    .csr_we_i            (csr_we_i),
    .csr_re_i            (csr_re_i),
    .priv_lvl_i          (priv_lvl),
    .csr_rdata_o         (csr_rdata_o),
    .csr_illegal_o       (csr_illegal_o),
    .se_mepc_wr_i        (se_mepc_wr),
    .se_mepc_wr_en_i     (se_mepc_wr_en),
    .se_mpp_wr_i         (se_mpp_wr),
    .se_mpp_wr_en_i      (se_mpp_wr_en),
    .trap_i              (trap_gen),
    .trap_pc_i           (pc_i),
    .trap_cause_i        (trap_cause),
    .trap_priv_i         (priv_lvl),
    .mepc_o              (csr_mepc),
    .mtvec_o             (mtvec),
    .mpp_o               (csr_mpp),
    .mie_o               (mie),
    .priv_lvl_o          (priv_lvl),
    .menclaveid_o        (),
    .menclavebase_o      (),
    .menclavebound_o     (),
    .enclave_meta_i      (enc_meta),
    .enclave_active_i    (se_enclave_active),
    .active_enclave_id_i (se_active_id),
    .pmp_csr_wr_o        (csr_pmp_wr),
    .pmp_csr_idx_o       (csr_pmp_idx),
    .pmp_csr_cfg_o       (csr_pmp_cfg),
    .pmp_csr_addr_o      (csr_pmp_addr),
    .pmp_csr_cfg_wr_o    (csr_pmp_cfg_wr),
    .pmp_csr_addr_wr_o   (csr_pmp_addr_wr),
    .pmp_cfg_rd_i        (pmp_cfg_readback),
    .pmp_addr_rd_i       (pmp_addr_readback),
    .mret_insn_i         (mret_insn_i),
    .mret_priv_restore_o ()
  );

  // ==========================================================================
  // Status Outputs
  // ==========================================================================
  assign enclave_active_o    = se_enclave_active;
  assign active_enclave_id_o = se_active_id;
  assign se_state_o          = se_state;
  assign current_priv_o      = priv_lvl;

  // Memory interface passthrough (simplified)
  assign dmem_addr_o  = ex_addr_i;
  assign dmem_wdata_o = rd_data_i;
  assign dmem_we_o    = ex_write_i && ex_granted_o;
  assign dmem_re_o    = ex_read_i && ex_granted_o;

endmodule

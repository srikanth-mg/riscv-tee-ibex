// ============================================================================
// tee_csr_unit.sv — Control and Status Register Unit
//
// Implements:
//   - Standard M-mode CSRs: mstatus, mtvec, mepc, mcause, medeleg
//   - PMP CSRs: pmpcfg0-3, pmpaddr0-15
//   - Custom TEE CSRs: menclaveid, menclave_activate, menclavebase, menclavebound
//
// Privilege enforcement:
//   - M-mode CSRs (0x300-0x3FF, 0x700-0x7FF) only accessible from M-mode
//   - S/U-mode access to M-mode CSR → illegal instruction exception
//
// RISC-V Privileged Spec v1.12, Chapter 2 (CSR access) and Chapter 3 (M-mode)
// ============================================================================

module tee_csr_unit
  import tee_pkg::*;
#(
  parameter int unsigned DATA_WIDTH   = TEE_DATA_WIDTH,
  parameter int unsigned ADDR_WIDTH   = TEE_ADDR_WIDTH,
  parameter int unsigned NUM_ENCLAVES = TEE_NUM_ENCLAVES,
  parameter int unsigned NUM_PMP      = TEE_NUM_PMP
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // --------------------------------------------------------------------------
  // CSR read/write interface (from decode/execute stage)
  // --------------------------------------------------------------------------
  input  logic [11:0]             csr_addr_i,
  input  logic [DATA_WIDTH-1:0]   csr_wdata_i,
  input  logic                    csr_we_i,        // CSR write enable
  input  logic                    csr_re_i,        // CSR read enable
  input  priv_lvl_e               priv_lvl_i,      // current privilege

  output logic [DATA_WIDTH-1:0]   csr_rdata_o,
  output logic                    csr_illegal_o,   // privilege violation

  // --------------------------------------------------------------------------
  // Security Engine write ports (SE can update CSRs directly)
  // --------------------------------------------------------------------------
  input  logic [ADDR_WIDTH-1:0]   se_mepc_wr_i,
  input  logic                    se_mepc_wr_en_i,
  input  logic [1:0]              se_mpp_wr_i,
  input  logic                    se_mpp_wr_en_i,

  // --------------------------------------------------------------------------
  // Trap interface (hardware writes on trap)
  // --------------------------------------------------------------------------
  input  logic                    trap_i,
  input  logic [ADDR_WIDTH-1:0]   trap_pc_i,      // PC of trapping instruction
  input  logic [4:0]              trap_cause_i,    // trap cause code
  input  priv_lvl_e               trap_priv_i,     // privilege at time of trap

  // --------------------------------------------------------------------------
  // CSR value outputs (used by pipeline and SE)
  // --------------------------------------------------------------------------
  output logic [ADDR_WIDTH-1:0]   mepc_o,
  output logic [ADDR_WIDTH-1:0]   mtvec_o,
  output logic [1:0]              mpp_o,           // mstatus.MPP
  output logic                    mie_o,           // mstatus.MIE
  output priv_lvl_e               priv_lvl_o,      // current privilege level

  // --------------------------------------------------------------------------
  // TEE CSR outputs
  // --------------------------------------------------------------------------
  output logic [3:0]              menclaveid_o,
  output logic [ADDR_WIDTH-1:0]   menclavebase_o,
  output logic [ADDR_WIDTH-1:0]   menclavebound_o,

  // Enclave metadata input (from SE, for CSR reads)
  input  enclave_meta_t           enclave_meta_i [NUM_ENCLAVES],
  input  logic                    enclave_active_i,
  input  logic [3:0]              active_enclave_id_i,

  // --------------------------------------------------------------------------
  // PMP CSR interface (directly to PMP controller)
  // --------------------------------------------------------------------------
  output logic                    pmp_csr_wr_o,
  output logic [3:0]              pmp_csr_idx_o,
  output logic [7:0]              pmp_csr_cfg_o,
  output logic [ADDR_WIDTH-1:0]   pmp_csr_addr_o,
  output logic                    pmp_csr_cfg_wr_o,
  output logic                    pmp_csr_addr_wr_o,

  // PMP config read-back
  input  logic [7:0]              pmp_cfg_rd_i  [NUM_PMP],
  input  logic [ADDR_WIDTH-1:0]   pmp_addr_rd_i [NUM_PMP],

  // --------------------------------------------------------------------------
  // mret interface
  // --------------------------------------------------------------------------
  input  logic                    mret_insn_i,     // mret instruction detected
  output logic                    mret_priv_restore_o  // signal to restore privilege
);

  // ==========================================================================
  // CSR Registers
  // ==========================================================================
  
  // Standard M-mode CSRs
  logic [DATA_WIDTH-1:0]  mstatus_q;     // Machine Status
  logic [ADDR_WIDTH-1:0]  mtvec_q;       // Machine Trap Vector
  logic [ADDR_WIDTH-1:0]  mepc_q;        // Machine Exception PC
  logic [DATA_WIDTH-1:0]  mcause_q;      // Machine Cause
  logic [DATA_WIDTH-1:0]  medeleg_q;     // Machine Exception Delegation
  logic [DATA_WIDTH-1:0]  mideleg_q;     // Machine Interrupt Delegation

  // Current privilege level
  priv_lvl_e              priv_q;

  // Custom TEE CSRs
  logic [3:0]             menclaveid_q;
  // menclavebase and menclavebound are derived from enclave metadata

  // mstatus field extraction
  // Bit layout (RV32): [12:11]=MPP, [7]=MPIE, [3]=MIE
  logic [1:0]  mstatus_mpp;
  logic        mstatus_mpie;
  logic        mstatus_mie;

  assign mstatus_mpp  = mstatus_q[12:11];
  assign mstatus_mpie = mstatus_q[7];
  assign mstatus_mie  = mstatus_q[3];

  // ==========================================================================
  // Privilege Check — M-mode CSRs require M-mode access
  // ==========================================================================
  logic csr_priv_ok;
  always_comb begin
    // CSR address [9:8] encodes minimum privilege level required
    // 0x3xx, 0x7xx = M-mode only (bits [9:8] = 2'b11)
    logic [1:0] csr_min_priv;
    csr_min_priv = csr_addr_i[9:8];
    csr_priv_ok = (priv_q >= priv_lvl_e'(csr_min_priv));
  end

  assign csr_illegal_o = (csr_we_i || csr_re_i) && !csr_priv_ok;

  // ==========================================================================
  // CSR Read Logic
  // ==========================================================================
  always_comb begin
    csr_rdata_o = '0;

    if (csr_re_i && csr_priv_ok) begin
      case (csr_addr_i)
        // Standard M-mode CSRs
        CSR_MSTATUS:  csr_rdata_o = mstatus_q;
        CSR_MTVEC:    csr_rdata_o = mtvec_q;
        CSR_MEPC:     csr_rdata_o = mepc_q;
        CSR_MCAUSE:   csr_rdata_o = mcause_q;
        CSR_MEDELEG:  csr_rdata_o = medeleg_q;

        // PMP config CSRs (4 entries per register on RV32)
        CSR_PMPCFG0: csr_rdata_o = {pmp_cfg_rd_i[3], pmp_cfg_rd_i[2],
                                     pmp_cfg_rd_i[1], pmp_cfg_rd_i[0]};
        CSR_PMPCFG1: csr_rdata_o = {pmp_cfg_rd_i[7], pmp_cfg_rd_i[6],
                                     pmp_cfg_rd_i[5], pmp_cfg_rd_i[4]};
        CSR_PMPCFG2: csr_rdata_o = {pmp_cfg_rd_i[11], pmp_cfg_rd_i[10],
                                     pmp_cfg_rd_i[9],  pmp_cfg_rd_i[8]};
        CSR_PMPCFG3: csr_rdata_o = {pmp_cfg_rd_i[15], pmp_cfg_rd_i[14],
                                     pmp_cfg_rd_i[13], pmp_cfg_rd_i[12]};

        // PMP address CSRs
        12'h3B0, 12'h3B1, 12'h3B2, 12'h3B3,
        12'h3B4, 12'h3B5, 12'h3B6, 12'h3B7,
        12'h3B8, 12'h3B9, 12'h3BA, 12'h3BB,
        12'h3BC, 12'h3BD, 12'h3BE, 12'h3BF:
          csr_rdata_o = pmp_addr_rd_i[csr_addr_i[3:0]];

        // Custom TEE CSRs
        CSR_MENCLAVEID:   csr_rdata_o = {28'b0, menclaveid_q};
        CSR_MENCLAVEBASE: begin
          if (enclave_active_i && active_enclave_id_i < NUM_ENCLAVES[3:0])
            csr_rdata_o = enclave_meta_i[active_enclave_id_i].base_addr;
        end
        CSR_MENCLAVEBOUND: begin
          if (enclave_active_i && active_enclave_id_i < NUM_ENCLAVES[3:0])
            csr_rdata_o = enclave_meta_i[active_enclave_id_i].base_addr +
                          enclave_meta_i[active_enclave_id_i].size;
        end

        default: csr_rdata_o = '0;
      endcase
    end
  end

  // ==========================================================================
  // CSR Write Logic + PMP CSR routing
  // ==========================================================================
  logic pmp_cfg_write, pmp_addr_write;

  always_comb begin
    pmp_csr_wr_o      = 1'b0;
    pmp_csr_idx_o     = '0;
    pmp_csr_cfg_o     = '0;
    pmp_csr_addr_o    = '0;
    pmp_csr_cfg_wr_o  = 1'b0;
    pmp_csr_addr_wr_o = 1'b0;
    pmp_cfg_write     = 1'b0;
    pmp_addr_write    = 1'b0;

    if (csr_we_i && csr_priv_ok) begin
      // PMP config writes (pmpcfg0-3)
      if (csr_addr_i >= CSR_PMPCFG0 && csr_addr_i <= CSR_PMPCFG3) begin
        pmp_cfg_write = 1'b1;
      end
      // PMP address writes (pmpaddr0-15)
      if (csr_addr_i >= CSR_PMPADDR0 && 
          csr_addr_i < (CSR_PMPADDR0 + 12'(NUM_PMP))) begin
        pmp_addr_write    = 1'b1;
        pmp_csr_wr_o      = 1'b1;
        pmp_csr_idx_o     = csr_addr_i[3:0];
        pmp_csr_addr_o    = csr_wdata_i;
        pmp_csr_addr_wr_o = 1'b1;
      end
    end
  end

  // ==========================================================================
  // Sequential CSR Updates
  // ==========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus_q    <= '0;
      mtvec_q      <= '0;
      mepc_q       <= '0;
      mcause_q     <= '0;
      medeleg_q    <= '0;
      mideleg_q    <= '0;
      priv_q       <= PRIV_M;     // CPU starts in M-mode on reset
      menclaveid_q <= '0;
    end else begin

      // ---- Trap hardware sequence (highest priority) ----
      if (trap_i) begin
        mepc_q              <= trap_pc_i;
        mcause_q            <= {27'b0, trap_cause_i};
        mstatus_q[12:11]    <= trap_priv_i;  // MPP = privilege at trap time
        mstatus_q[7]        <= mstatus_q[3]; // MPIE = MIE
        mstatus_q[3]        <= 1'b0;         // MIE = 0 (disable interrupts)
        priv_q              <= PRIV_M;        // switch to M-mode
      end

      // ---- mret hardware sequence ----
      else if (mret_insn_i) begin
        priv_q           <= priv_lvl_e'(mstatus_q[12:11]); // restore MPP
        mstatus_q[3]     <= mstatus_q[7];                  // MIE = MPIE
        mstatus_q[7]     <= 1'b1;                          // MPIE = 1
        mstatus_q[12:11] <= PRIV_U;                        // MPP = U-mode
      end

      // ---- Security Engine direct writes ----
      else begin
        if (se_mepc_wr_en_i) begin
          mepc_q <= se_mepc_wr_i;
        end
        if (se_mpp_wr_en_i) begin
          mstatus_q[12:11] <= se_mpp_wr_i;
        end

        // ---- Normal CSR writes from pipeline ----
        if (csr_we_i && csr_priv_ok) begin
          case (csr_addr_i)
            CSR_MSTATUS: mstatus_q <= csr_wdata_i;
            CSR_MTVEC:   mtvec_q   <= csr_wdata_i;
            CSR_MEPC:    mepc_q    <= csr_wdata_i;
            CSR_MEDELEG: medeleg_q <= csr_wdata_i;
            // PMP CSRs handled via pmp_csr interface
            default: ;
          endcase
        end
      end

      // ---- TEE CSR updates from SE ----
      if (enclave_active_i) begin
        menclaveid_q <= active_enclave_id_i;
      end else begin
        menclaveid_q <= '0;
      end
    end
  end

  // ==========================================================================
  // Output Assignments
  // ==========================================================================
  assign mepc_o     = mepc_q;
  assign mtvec_o    = mtvec_q;
  assign mpp_o      = mstatus_mpp;
  assign mie_o      = mstatus_mie;
  assign priv_lvl_o = priv_q;

  assign menclaveid_o   = menclaveid_q;
  assign menclavebase_o = (enclave_active_i && active_enclave_id_i < NUM_ENCLAVES[3:0]) ?
                           enclave_meta_i[active_enclave_id_i].base_addr : '0;
  assign menclavebound_o = (enclave_active_i && active_enclave_id_i < NUM_ENCLAVES[3:0]) ?
                            enclave_meta_i[active_enclave_id_i].base_addr +
                            enclave_meta_i[active_enclave_id_i].size : '0;

  assign mret_priv_restore_o = mret_insn_i;

endmodule

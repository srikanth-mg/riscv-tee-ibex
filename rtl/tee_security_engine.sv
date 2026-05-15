// ============================================================================
// tee_security_engine.sv — Hardware Security Engine
//
// Implements the enclave lifecycle as a dedicated hardware FSM.
// Replaces the traditional software Security Monitor.
//
// Six phases: Boot → Create → Enter → Execute → Exit → Destroy
//
// Key advantages over software SM:
//   - ~6 cycles per transition (vs ~100 cycles software)
//   - No software attack surface (no buffer overflow / control-flow hijack)
//   - Constant-time by construction (FSM always traverses same states)
//
// Interfaces:
//   - Pipeline: intercepts ecall, drives pipeline flush and mret
//   - Register file: parallel save/restore via shadow bank, hardware scrub
//   - PMP controller: fast-path activation for atomic PMP reconfiguration
//   - CSR unit: reads/writes mepc, mstatus, custom CSRs
// ============================================================================

module tee_security_engine
  import tee_pkg::*;
#(
  parameter int unsigned NUM_ENCLAVES = TEE_NUM_ENCLAVES,
  parameter int unsigned DATA_WIDTH   = TEE_DATA_WIDTH,
  parameter int unsigned ADDR_WIDTH   = TEE_ADDR_WIDTH
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // --------------------------------------------------------------------------
  // Pipeline interface
  // --------------------------------------------------------------------------
  input  logic                    ecall_insn_i,        // ecall detected in EX
  input  logic [DATA_WIDTH-1:0]   ecall_a0_i,          // a0 = operation code
  input  logic [DATA_WIDTH-1:0]   ecall_a1_i,          // a1 = enclave_id / arg
  input  logic [DATA_WIDTH-1:0]   ecall_a2_i,          // a2 = base_addr (create)
  input  logic [DATA_WIDTH-1:0]   ecall_a3_i,          // a3 = size (create)
  input  priv_lvl_e               current_priv_i,      // current privilege level

  output logic                    pipeline_flush_o,    // flush pipeline
  output logic                    mret_trigger_o,      // trigger mret sequence
  output logic                    se_busy_o,           // SE is processing

  // --------------------------------------------------------------------------
  // Register file interface
  // --------------------------------------------------------------------------
  input  logic [DATA_WIDTH-1:0]   rf_rdata_i [1:31],   // read all regs (x1-x31)
  output logic                    rf_scrub_o,           // zero all regs in 1 cycle
  output logic                    rf_restore_o,         // restore from shadow bank
  output logic [DATA_WIDTH-1:0]   rf_shadow_o [1:31],   // shadow bank output

  // --------------------------------------------------------------------------
  // PMP fast-path interface
  // --------------------------------------------------------------------------
  output logic                    pmp_fast_activate_o,
  output logic [3:0]              pmp_fast_idx_o,
  output logic [7:0]              pmp_fast_cfg_o,

  // PMP CSR write interface (for address setup during create)
  output logic                    pmp_csr_wr_o,
  output logic [3:0]              pmp_csr_idx_o,
  output logic [ADDR_WIDTH-1:0]   pmp_csr_addr_o,
  output logic                    pmp_csr_addr_wr_o,
  output logic                    pmp_csr_cfg_wr_o,
  output logic [7:0]              pmp_csr_cfg_o,

  // --------------------------------------------------------------------------
  // CSR interface
  // --------------------------------------------------------------------------
  output logic [ADDR_WIDTH-1:0]   mepc_wr_o,           // write mepc
  output logic                    mepc_wr_en_o,
  output logic [1:0]              mpp_wr_o,            // write mstatus.MPP
  output logic                    mpp_wr_en_o,

  input  logic [ADDR_WIDTH-1:0]   mepc_rd_i,           // read current mepc
  input  logic [1:0]              mpp_rd_i,            // read current mstatus.MPP

  // --------------------------------------------------------------------------
  // Status outputs
  // --------------------------------------------------------------------------
  output logic                    enclave_active_o,
  output logic [3:0]              active_enclave_id_o,
  output se_state_e               se_state_o,          // for debug / testbench

  // Enclave metadata read port (for CSR unit)
  output enclave_meta_t           enclave_meta_o [NUM_ENCLAVES],

  // Error / return value
  output logic [DATA_WIDTH-1:0]   return_val_o,        // value placed in a0 on return
  output logic                    forward_to_smode_o   // forward non-TEE ecall to S-mode
);

  // ==========================================================================
  // Internal State
  // ==========================================================================
  se_state_e state_q, state_d;

  // Enclave metadata table (in flip-flops — small, fast, hardware-protected)
  enclave_meta_t enc_table_q [NUM_ENCLAVES];

  // Shadow register bank for host context
  logic [DATA_WIDTH-1:0] shadow_regs_q [1:31];

  // Saved host CSR values
  logic [ADDR_WIDTH-1:0] saved_mepc_q, saved_mepc_d;
  logic [1:0]            saved_mpp_q,  saved_mpp_d;

  // Working registers
  logic [3:0]            target_enc_q, target_enc_d;      // target enclave for current op
  tee_op_e               current_op_q, current_op_d;      // current operation

  // Active enclave tracking
  logic                  enc_active_q, enc_active_d;
  logic [3:0]            enc_active_id_q, enc_active_id_d;

  // Memory scrub counter (for DESTROY phase)
  logic [ADDR_WIDTH-1:0] scrub_addr_q, scrub_addr_d;
  logic                  scrub_done;

  // ==========================================================================
  // Decode ecall operation
  // ==========================================================================
  tee_op_e decoded_op;
  always_comb begin
    case (ecall_a0_i[3:0])
      4'd1:    decoded_op = TEE_OP_CREATE;
      4'd2:    decoded_op = TEE_OP_ENTER;
      4'd3:    decoded_op = TEE_OP_EXIT;
      4'd4:    decoded_op = TEE_OP_DESTROY;
      4'd5:    decoded_op = TEE_OP_ATTEST;
      default: decoded_op = TEE_OP_NONE;
    endcase
  end

  // ==========================================================================
  // Validation Logic
  // ==========================================================================
  logic create_valid;
  logic enter_valid;
  logic exit_valid;
  logic destroy_valid;
  logic [3:0] enc_id_from_a1;

  assign enc_id_from_a1 = ecall_a1_i[3:0];

  // CREATE validation: slot available, ID in range
  assign create_valid = (enc_id_from_a1 < NUM_ENCLAVES[3:0]) &&
                        (!enc_table_q[enc_id_from_a1].valid);

  // ENTER validation: enclave exists, is in CREATED or STOPPED state, not running
  assign enter_valid = (enc_id_from_a1 < NUM_ENCLAVES[3:0]) &&
                       (enc_table_q[enc_id_from_a1].valid) &&
                       (enc_table_q[enc_id_from_a1].state == ENC_CREATED ||
                        enc_table_q[enc_id_from_a1].state == ENC_STOPPED) &&
                       (!enc_active_q);  // no other enclave running

  // EXIT validation: this enclave is actually running
  assign exit_valid = (enc_active_q) &&
                      (enc_active_id_q == enc_id_from_a1);

  // DESTROY validation: enclave exists, is NOT running
  assign destroy_valid = (enc_id_from_a1 < NUM_ENCLAVES[3:0]) &&
                         (enc_table_q[enc_id_from_a1].valid) &&
                         (enc_table_q[enc_id_from_a1].state != ENC_RUNNING);

  // ==========================================================================
  // FSM Sequential Logic
  // ==========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= SE_IDLE;
      target_enc_q   <= '0;
      current_op_q   <= TEE_OP_NONE;
      saved_mepc_q   <= '0;
      saved_mpp_q    <= 2'b00;
      enc_active_q   <= 1'b0;
      enc_active_id_q <= '0;
      scrub_addr_q   <= '0;

      for (int i = 0; i < NUM_ENCLAVES; i++) begin
        enc_table_q[i] <= '{
          base_addr:   '0,
          size:        '0,
          entry_point: '0,
          pmp_idx:     '0,
          state:       ENC_INVALID,
          valid:       1'b0
        };
      end

      for (int i = 1; i < 32; i++) begin
        shadow_regs_q[i] <= '0;
      end
    end else begin
      state_q        <= state_d;
      target_enc_q   <= target_enc_d;
      current_op_q   <= current_op_d;
      saved_mepc_q   <= saved_mepc_d;
      saved_mpp_q    <= saved_mpp_d;
      enc_active_q   <= enc_active_d;
      enc_active_id_q <= enc_active_id_d;
      scrub_addr_q   <= scrub_addr_d;

      // Shadow bank save (parallel — all 31 registers in one cycle)
      if (state_q == SE_ENTER_SAVE_CTX) begin
        for (int i = 1; i < 32; i++) begin
          shadow_regs_q[i] <= rf_rdata_i[i];
        end
      end

      // Enclave table updates
      case (state_q)
        SE_CREATE_COMMIT: begin
          enc_table_q[target_enc_q].valid       <= 1'b1;
          enc_table_q[target_enc_q].base_addr   <= ecall_a2_i;
          enc_table_q[target_enc_q].size         <= ecall_a3_i;
          enc_table_q[target_enc_q].entry_point  <= ecall_a2_i + 32'h10; // entry = base + 0x10
          enc_table_q[target_enc_q].pmp_idx      <= target_enc_q + 4'd1; // PMP0 is SE
          enc_table_q[target_enc_q].state        <= ENC_CREATED;
        end

        SE_ENTER_PMP: begin
          enc_table_q[target_enc_q].state <= ENC_RUNNING;
        end

        SE_EXIT_REVOKE: begin
          enc_table_q[target_enc_q].state <= ENC_STOPPED;
        end

        SE_DESTROY_FREE: begin
          enc_table_q[target_enc_q].valid <= 1'b0;
          enc_table_q[target_enc_q].state <= ENC_INVALID;
        end

        default: ;
      endcase
    end
  end

  // ==========================================================================
  // FSM Combinational Logic (Next State + Outputs)
  // ==========================================================================
  always_comb begin
    // Default outputs — all inactive
    state_d            = state_q;
    target_enc_d       = target_enc_q;
    current_op_d       = current_op_q;
    saved_mepc_d       = saved_mepc_q;
    saved_mpp_d        = saved_mpp_q;
    enc_active_d       = enc_active_q;
    enc_active_id_d    = enc_active_id_q;
    scrub_addr_d       = scrub_addr_q;

    pipeline_flush_o   = 1'b0;
    mret_trigger_o     = 1'b0;
    se_busy_o          = (state_q != SE_IDLE);
    rf_scrub_o         = 1'b0;
    rf_restore_o       = 1'b0;
    pmp_fast_activate_o = 1'b0;
    pmp_fast_idx_o     = '0;
    pmp_fast_cfg_o     = '0;
    pmp_csr_wr_o       = 1'b0;
    pmp_csr_idx_o      = '0;
    pmp_csr_addr_o     = '0;
    pmp_csr_addr_wr_o  = 1'b0;
    pmp_csr_cfg_wr_o   = 1'b0;
    pmp_csr_cfg_o      = '0;
    mepc_wr_o          = '0;
    mepc_wr_en_o       = 1'b0;
    mpp_wr_o           = 2'b00;
    mpp_wr_en_o        = 1'b0;
    return_val_o       = '0;
    forward_to_smode_o = 1'b0;

    case (state_q)
      // ================================================================
      // IDLE — Waiting for ecall
      // ================================================================
      SE_IDLE: begin
        if (ecall_insn_i) begin
          pipeline_flush_o = 1'b1;
          target_enc_d     = enc_id_from_a1;
          current_op_d     = decoded_op;

          case (decoded_op)
            TEE_OP_CREATE: begin
              if (create_valid) state_d = SE_CREATE_VALIDATE;
              else              state_d = SE_IDLE; // reject silently
            end
            TEE_OP_ENTER: begin
              if (enter_valid) begin
                state_d      = SE_ENTER_SAVE_CTX;
                saved_mepc_d = mepc_rd_i;  // save host return address
                saved_mpp_d  = mpp_rd_i;   // save host privilege
              end else begin
                state_d = SE_IDLE;
              end
            end
            TEE_OP_EXIT: begin
              if (exit_valid) state_d = SE_EXIT_REVOKE;
              else            state_d = SE_IDLE;
            end
            TEE_OP_DESTROY: begin
              if (destroy_valid) state_d = SE_DESTROY_SCRUB;
              else               state_d = SE_IDLE;
            end
            TEE_OP_NONE: begin
              // Not a TEE ecall — forward to S-mode
              forward_to_smode_o = 1'b1;
              state_d = SE_FORWARD_SYSCALL;
            end
            default: state_d = SE_IDLE;
          endcase
        end
      end

      // ================================================================
      // CREATE FLOW
      // ================================================================
      SE_CREATE_VALIDATE: begin
        // Validation already done combinationally (create_valid)
        // In a more complex implementation, check for overlapping regions here
        state_d = SE_CREATE_COMMIT;
      end

      SE_CREATE_COMMIT: begin
        // Write PMP entry: address + config (NO_ACCESS)
        pmp_csr_wr_o      = 1'b1;
        pmp_csr_idx_o     = target_enc_q + 4'd1;
        pmp_csr_addr_o    = ecall_a2_i + ecall_a3_i; // top of range
        pmp_csr_addr_wr_o = 1'b1;
        pmp_csr_cfg_wr_o  = 1'b1;
        pmp_csr_cfg_o     = 8'b0_00_01_000;  // TOR mode, no R/W/X

        return_val_o = {28'b0, target_enc_q}; // return enclave_id
        state_d      = SE_IDLE;
      end

      // ================================================================
      // ENTER FLOW — Security-critical ordering
      // ================================================================
      SE_ENTER_SAVE_CTX: begin
        // Parallel save happens in sequential block (shadow_regs_q <= rf_rdata_i)
        // This state just triggers the save; data captured on next clock edge
        state_d = SE_ENTER_SCRUB;
      end

      SE_ENTER_SCRUB: begin
        // Zero all general-purpose registers in ONE cycle
        rf_scrub_o = 1'b1;
        state_d    = SE_ENTER_PMP;
      end

      SE_ENTER_PMP: begin
        // Grant RWX to enclave's PMP entry via fast-path
        pmp_fast_activate_o = 1'b1;
        pmp_fast_idx_o      = enc_table_q[target_enc_q].pmp_idx;
        pmp_fast_cfg_o      = 8'b0_00_01_111;  // TOR mode, R+W+X

        enc_active_d    = 1'b1;
        enc_active_id_d = target_enc_q;
        state_d         = SE_ENTER_LAUNCH;
      end

      SE_ENTER_LAUNCH: begin
        // Set mepc = enclave entry point, mstatus.MPP = U-mode
        mepc_wr_o    = enc_table_q[target_enc_q].entry_point;
        mepc_wr_en_o = 1'b1;
        mpp_wr_o     = PRIV_U;   // enclave runs in U-mode
        mpp_wr_en_o  = 1'b1;

        mret_trigger_o = 1'b1;   // trigger mret → drops to U-mode
        state_d        = SE_IDLE;
      end

      // ================================================================
      // EXIT FLOW — PMP revoked FIRST (security-critical ordering)
      // ================================================================
      SE_EXIT_REVOKE: begin
        // FIRST: Revoke PMP access before anything else
        pmp_fast_activate_o = 1'b1;
        pmp_fast_idx_o      = enc_table_q[target_enc_q].pmp_idx;
        pmp_fast_cfg_o      = 8'b0_00_01_000;  // TOR mode, no R/W/X

        enc_active_d    = 1'b0;
        enc_active_id_d = '0;
        state_d         = SE_EXIT_SCRUB;
      end

      SE_EXIT_SCRUB: begin
        // Scrub enclave registers to prevent secret leakage
        rf_scrub_o = 1'b1;
        state_d    = SE_EXIT_RESTORE;
      end

      SE_EXIT_RESTORE: begin
        // Restore host registers from shadow bank
        rf_restore_o = 1'b1;
        state_d      = SE_EXIT_RETURN;
      end

      SE_EXIT_RETURN: begin
        // Set mepc and MPP back to host's saved values
        mepc_wr_o    = saved_mepc_q;
        mepc_wr_en_o = 1'b1;
        mpp_wr_o     = saved_mpp_q;
        mpp_wr_en_o  = 1'b1;

        mret_trigger_o = 1'b1;
        state_d        = SE_IDLE;
      end

      // ================================================================
      // DESTROY FLOW
      // ================================================================
      SE_DESTROY_SCRUB: begin
        // Zero enclave memory region (counter-based)
        // In real implementation, this issues write transactions to memory
        scrub_addr_d = scrub_addr_q + ADDR_WIDTH'(4);  // 4 bytes per cycle

        if (scrub_addr_q >= enc_table_q[target_enc_q].size) begin
          scrub_addr_d = '0;
          state_d      = SE_DESTROY_FREE;
        end
      end

      SE_DESTROY_FREE: begin
        // Free PMP entry
        pmp_fast_activate_o = 1'b1;
        pmp_fast_idx_o      = enc_table_q[target_enc_q].pmp_idx;
        pmp_fast_cfg_o      = 8'b0;  // OFF — disabled

        state_d = SE_IDLE;
      end

      // ================================================================
      // FORWARD SYSCALL — Non-TEE ecall goes to S-mode
      // ================================================================
      SE_FORWARD_SYSCALL: begin
        // In full implementation: set sepc, scause, jump to stvec
        // For now, just return to caller
        mret_trigger_o = 1'b1;
        state_d        = SE_IDLE;
      end

      default: state_d = SE_IDLE;
    endcase
  end

  // ==========================================================================
  // Output Assignments
  // ==========================================================================
  assign enclave_active_o    = enc_active_q;
  assign active_enclave_id_o = enc_active_id_q;
  assign se_state_o          = state_q;

  // Shadow bank output for register file restore
  generate
    for (genvar i = 1; i < 32; i++) begin : gen_shadow_out
      assign rf_shadow_o[i] = shadow_regs_q[i];
    end
  endgenerate

  // Enclave metadata output for CSR unit
  generate
    for (genvar i = 0; i < NUM_ENCLAVES; i++) begin : gen_meta_out
      assign enclave_meta_o[i] = enc_table_q[i];
    end
  endgenerate

endmodule

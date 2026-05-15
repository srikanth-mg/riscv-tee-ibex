// ============================================================================
// tee_rtl_tb.sv
//
// RTL integration testbench for tee_top.
// Instantiates the actual DUT (not a behavioral model).
//
// Goals:
//   1. Verify DUT compiles and resets cleanly
//   2. Exercise CSR read/write path
//   3. Drive an ecall and observe FSM transitions
//   4. Probe PMP grant/fault behavior across privilege levels
//   5. Generate VCD waveforms for visual debug
//
// Run in Vivado:
//   - Set tee_rtl_tb as top-level for simulation
//   - run_simulation (auto from create_project.tcl)
// ============================================================================

`timescale 1ns/1ps

module tee_rtl_tb;

  import tee_pkg::*;

  // ==========================================================================
  // Parameters
  // ==========================================================================
  localparam int unsigned CLK_PERIOD   = 10;   // 10 ns → 100 MHz
  localparam int unsigned DATA_WIDTH   = TEE_DATA_WIDTH;
  localparam int unsigned ADDR_WIDTH   = TEE_ADDR_WIDTH;
  localparam int unsigned NUM_PMP      = TEE_NUM_PMP;
  localparam int unsigned NUM_ENCLAVES = TEE_NUM_ENCLAVES;

  // ==========================================================================
  // DUT signals
  // ==========================================================================
  logic                    clk;
  logic                    rst_n;

  // IF interface
  logic [ADDR_WIDTH-1:0]   if_addr;
  logic                    if_valid;
  logic                    if_granted;
  logic                    if_fault;

  // EX interface (load/store)
  logic [ADDR_WIDTH-1:0]   ex_addr;
  logic                    ex_valid;
  logic                    ex_read;
  logic                    ex_write;
  logic                    ex_granted;
  logic                    ex_fault;

  // Trap interface
  logic                    ecall_insn;
  logic [DATA_WIDTH-1:0]   ecall_a3;
  logic                    mret_insn;
  logic [ADDR_WIDTH-1:0]   pc;
  logic                    pipeline_flush;
  logic                    mret_trigger;
  logic [ADDR_WIDTH-1:0]   trap_target;

  // Register file
  logic [4:0]              rs1_addr;
  logic [DATA_WIDTH-1:0]   rs1_data;
  logic [4:0]              rs2_addr;
  logic [DATA_WIDTH-1:0]   rs2_data;
  logic [4:0]              rd_addr;
  logic [DATA_WIDTH-1:0]   rd_data;
  logic                    rd_we;

  // CSR
  logic [11:0]             csr_addr;
  logic [DATA_WIDTH-1:0]   csr_wdata;
  logic                    csr_we;
  logic                    csr_re;
  logic [DATA_WIDTH-1:0]   csr_rdata;
  logic                    csr_illegal;

  // Data memory
  logic [ADDR_WIDTH-1:0]   dmem_addr;
  logic [DATA_WIDTH-1:0]   dmem_wdata;
  logic                    dmem_we;
  logic                    dmem_re;
  logic [DATA_WIDTH-1:0]   dmem_rdata;

  // Status
  logic                    enclave_active;
  logic [3:0]              active_enclave_id;
  se_state_e               se_state;
  priv_lvl_e               current_priv;

  // ==========================================================================
  // Scoreboard
  // ==========================================================================
  int tests_run    = 0;
  int tests_passed = 0;
  int tests_failed = 0;

  // ==========================================================================
  // Clock generation
  // ==========================================================================
  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ==========================================================================
  // DUT instantiation
  // ==========================================================================
  tee_top #(
    .DATA_WIDTH   (DATA_WIDTH),
    .ADDR_WIDTH   (ADDR_WIDTH),
    .NUM_PMP      (NUM_PMP),
    .NUM_ENCLAVES (NUM_ENCLAVES)
  ) u_dut (
    .clk_i               (clk),
    .rst_ni              (rst_n),

    // IF
    .if_addr_i           (if_addr),
    .if_valid_i          (if_valid),
    .if_granted_o        (if_granted),
    .if_fault_o          (if_fault),

    // EX
    .ex_addr_i           (ex_addr),
    .ex_valid_i          (ex_valid),
    .ex_read_i           (ex_read),
    .ex_write_i          (ex_write),
    .ex_granted_o        (ex_granted),
    .ex_fault_o          (ex_fault),

    // Trap
    .ecall_insn_i        (ecall_insn),
    .ecall_a3_i          (ecall_a3),
    .mret_insn_i         (mret_insn),
    .pc_i                (pc),
    .pipeline_flush_o    (pipeline_flush),
    .mret_trigger_o      (mret_trigger),
    .trap_target_o       (trap_target),

    // Regfile
    .rs1_addr_i          (rs1_addr),
    .rs1_data_o          (rs1_data),
    .rs2_addr_i          (rs2_addr),
    .rs2_data_o          (rs2_data),
    .rd_addr_i           (rd_addr),
    .rd_data_i           (rd_data),
    .rd_we_i             (rd_we),

    // CSR
    .csr_addr_i          (csr_addr),
    .csr_wdata_i         (csr_wdata),
    .csr_we_i            (csr_we),
    .csr_re_i            (csr_re),
    .csr_rdata_o         (csr_rdata),
    .csr_illegal_o       (csr_illegal),

    // DMEM
    .dmem_addr_o         (dmem_addr),
    .dmem_wdata_o        (dmem_wdata),
    .dmem_we_o           (dmem_we),
    .dmem_re_o           (dmem_re),
    .dmem_rdata_i        (dmem_rdata),

    // Status
    .enclave_active_o    (enclave_active),
    .active_enclave_id_o (active_enclave_id),
    .se_state_o          (se_state),
    .current_priv_o      (current_priv)
  );

  // ==========================================================================
  // Helper task: drive all inputs to known idle values
  // ==========================================================================
  task automatic drive_idle();
    if_addr     = '0;
    if_valid    = 1'b0;
    ex_addr     = '0;
    ex_valid    = 1'b0;
    ex_read     = 1'b0;
    ex_write    = 1'b0;
    ecall_insn  = 1'b0;
    ecall_a3    = '0;
    mret_insn   = 1'b0;
    pc          = '0;
    rs1_addr    = '0;
    rs2_addr    = '0;
    rd_addr     = '0;
    rd_data     = '0;
    rd_we       = 1'b0;
    csr_addr    = '0;
    csr_wdata   = '0;
    csr_we      = 1'b0;
    csr_re      = 1'b0;
    dmem_rdata  = '0;
  endtask

  // ==========================================================================
  // Helper task: write a register through the rd port
  // ==========================================================================
  task automatic write_reg(input logic [4:0] addr,
                           input logic [DATA_WIDTH-1:0] data);
    @(posedge clk);
    rd_addr = addr;
    rd_data = data;
    rd_we   = 1'b1;
    @(posedge clk);
    rd_we   = 1'b0;
    rd_addr = '0;
    rd_data = '0;
  endtask

  // ==========================================================================
  // Helper task: CSR write
  // ==========================================================================
  task automatic csr_write(input logic [11:0] addr,
                           input logic [DATA_WIDTH-1:0] data);
    @(posedge clk);
    csr_addr  = addr;
    csr_wdata = data;
    csr_we    = 1'b1;
    csr_re    = 1'b0;
    @(posedge clk);
    csr_we    = 1'b0;
    csr_addr  = '0;
    csr_wdata = '0;
  endtask

  // ==========================================================================
  // Helper task: CSR read (result in csr_rdata)
  // ==========================================================================
  task automatic csr_read(input logic [11:0] addr);
    @(posedge clk);
    csr_addr = addr;
    csr_we   = 1'b0;
    csr_re   = 1'b1;
    @(posedge clk);
    csr_re   = 1'b0;
    csr_addr = '0;
  endtask

  // ==========================================================================
  // Helper task: PMP load/store check probe
  // ==========================================================================
  task automatic check_load(input logic [ADDR_WIDTH-1:0] addr,
                            output logic granted,
                            output logic fault);
    @(posedge clk);
    ex_addr  = addr;
    ex_valid = 1'b1;
    ex_read  = 1'b1;
    ex_write = 1'b0;
    @(posedge clk);
    granted  = ex_granted;
    fault    = ex_fault;
    ex_valid = 1'b0;
    ex_read  = 1'b0;
    ex_addr  = '0;
  endtask

  // ==========================================================================
  // Check macro
  // ==========================================================================
  task automatic check(input string name, input logic cond);
    tests_run++;
    if (cond) begin
      $display("[PASS] %s", name);
      tests_passed++;
    end else begin
      $display("[FAIL] %s", name);
      tests_failed++;
    end
  endtask

  // ==========================================================================
  // MAIN TEST SEQUENCE
  // ==========================================================================
  initial begin
    // Waveform dump
    $dumpfile("tee_rtl_tb.vcd");
    $dumpvars(0, tee_rtl_tb);

    $display("================================================================");
    $display("  TEE RTL Integration Testbench");
    $display("================================================================");

    // ------------------------------------------------------------------------
    // Reset
    // ------------------------------------------------------------------------
    rst_n = 1'b0;
    drive_idle();
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    // ------------------------------------------------------------------------
    // TEST 1: Post-reset state
    // ------------------------------------------------------------------------
    $display("\n--- TEST 1: Post-reset state ---");
    check("SE in IDLE after reset",        se_state == SE_IDLE);
    check("No enclave active after reset", enclave_active == 1'b0);
    check("Privilege = M after reset",     current_priv == PRIV_M);

    // ------------------------------------------------------------------------
    // TEST 2: CSR write/read — MTVEC
    // ------------------------------------------------------------------------
    $display("\n--- TEST 2: CSR write/read MTVEC ---");
    csr_write(CSR_MTVEC, 32'h0000_1000);
    csr_read (CSR_MTVEC);
    check("MTVEC readback matches", csr_rdata == 32'h0000_1000);

    // ------------------------------------------------------------------------
    // TEST 3: PMP check in M-mode bypasses (should grant)
    // ------------------------------------------------------------------------
    $display("\n--- TEST 3: M-mode load bypasses PMP ---");
    begin
      logic g, f;
      check_load(32'h2000_0000, g, f);
      check("M-mode load granted", g == 1'b1 && f == 1'b0);
    end

  // ------------------------------------------------------------------------
    // TEST 4: ecall pulse — observe FSM leaves IDLE
    //   tee_top hijacks rs1/rs2/rd ports for ecall args:
    //     ecall_a0 ← rs1_data_o   (read x10)
    //     ecall_a1 ← rs2_data_o   (read x11)
    //     ecall_a2 ← rd_data_i    (driven directly)
    //     ecall_a3 ← ecall_a3_i   (driven directly via dedicated port)
    //
    //   CREATE path is: SE_IDLE → CREATE_VALIDATE → CREATE_COMMIT → SE_IDLE
    //   The FSM only spends ~2-3 cycles in non-IDLE states then returns,
    //   so we monitor for any non-IDLE state during a 10-cycle window.
    // ------------------------------------------------------------------------
    $display("\n--- TEST 4: ecall triggers SE FSM transition ---");
    // First populate x10 and x11 with op_code and enclave_id
    write_reg(5'd10, {28'd0, TEE_OP_CREATE});  // x10 = a0 = CREATE
    write_reg(5'd11, 32'd1);                    // x11 = a1 = enclave_id 1

    // Now issue ecall — hold read addrs AND drive rd_data as a2 simultaneously
    @(posedge clk);
    rs1_addr   = 5'd10;             // route x10 into ecall_a0
    rs2_addr   = 5'd11;             // route x11 into ecall_a1
    rd_data    = 32'h4000_0000;     // a2 = base address
    ecall_a3   = 32'h0000_1000;     // a3 = enclave size (NON-ZERO required)
    ecall_insn = 1'b1;
    pc         = 32'h0000_2000;
    @(posedge clk);
    ecall_insn = 1'b0;
    rs1_addr   = '0;
    rs2_addr   = '0;
    rd_data    = '0;
    ecall_a3   = '0;

    // Monitor FSM state for 10 cycles to catch the CREATE_VALIDATE / CREATE_COMMIT
    // transients before the FSM returns to IDLE.
    begin
      logic advanced;
      advanced = 1'b0;
      for (int i = 0; i < 10; i++) begin
        @(posedge clk);
        $display("  [diag] cycle %0d: se_state = %0d  enclave_active = %0b",
                 i, se_state, enclave_active);
        if (se_state != SE_IDLE) advanced = 1'b1;
      end
      check("SE FSM advanced past IDLE", advanced);
    end

    // ------------------------------------------------------------------------
    // Wait for FSM to settle back
    // ------------------------------------------------------------------------
    repeat (50) @(posedge clk);

    // ------------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------------
    $display("\n================================================================");
    $display("  RESULTS: %0d/%0d passed", tests_passed, tests_run);
    if (tests_failed == 0)
      $display("  >>> ALL PASSED <<<");
    else
      $display("  >>> %0d FAILED — check waveform <<<", tests_failed);
    $display("================================================================\n");

    $finish;
  end

  // ==========================================================================
  // Timeout watchdog
  // ==========================================================================
  initial begin
    #(CLK_PERIOD * 5000);
    $display("\n*** TIMEOUT ***");
    $finish;
  end

endmodule

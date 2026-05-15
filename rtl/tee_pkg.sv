// ============================================================================
// tee_pkg.sv — TEE Package
//
// Shared types, constants, and parameters used across all TEE modules.
// Import this in every module: import tee_pkg::*;
// ============================================================================

package tee_pkg;

  // ==========================================================================
  // System Parameters
  // ==========================================================================
  parameter int unsigned TEE_DATA_WIDTH    = 32;
  parameter int unsigned TEE_ADDR_WIDTH    = 32;
  parameter int unsigned TEE_NUM_PMP       = 16;
  parameter int unsigned TEE_NUM_ENCLAVES  = 4;
  parameter int unsigned TEE_NUM_REGS      = 32;  // x0-x31 (x0 hardwired to 0)

  // ==========================================================================
  // Privilege Levels (RISC-V Privileged Spec v1.12, Section 1.2)
  // ==========================================================================
  typedef enum logic [1:0] {
    PRIV_U = 2'b00,   // User mode
    PRIV_S = 2'b01,   // Supervisor mode
    PRIV_M = 2'b11    // Machine mode
  } priv_lvl_e;

  // ==========================================================================
  // TEE Operation Codes (passed in a0 register via ecall)
  // ==========================================================================
  typedef enum logic [3:0] {
    TEE_OP_NONE    = 4'd0,
    TEE_OP_CREATE  = 4'd1,   // Create a new enclave
    TEE_OP_ENTER   = 4'd2,   // Enter an existing enclave
    TEE_OP_EXIT    = 4'd3,   // Exit the current enclave
    TEE_OP_DESTROY = 4'd4,   // Destroy an enclave
    TEE_OP_ATTEST  = 4'd5    // Request attestation report
  } tee_op_e;

  // ==========================================================================
  // Security Engine FSM States
  // ==========================================================================
  typedef enum logic [3:0] {
    SE_IDLE            = 4'd0,
    SE_CREATE_VALIDATE = 4'd1,
    SE_CREATE_COMMIT   = 4'd2,
    SE_ENTER_SAVE_CTX  = 4'd3,
    SE_ENTER_SCRUB     = 4'd4,
    SE_ENTER_PMP       = 4'd5,
    SE_ENTER_LAUNCH    = 4'd6,
    SE_EXIT_REVOKE     = 4'd7,
    SE_EXIT_SCRUB      = 4'd8,
    SE_EXIT_RESTORE    = 4'd9,
    SE_EXIT_RETURN     = 4'd10,
    SE_DESTROY_SCRUB   = 4'd11,
    SE_DESTROY_FREE    = 4'd12,
    SE_FORWARD_SYSCALL = 4'd13
  } se_state_e;

  // ==========================================================================
  // Enclave States
  // ==========================================================================
  typedef enum logic [1:0] {
    ENC_INVALID  = 2'd0,   // Not created
    ENC_CREATED  = 2'd1,   // Created but not running
    ENC_RUNNING  = 2'd2,   // Currently executing
    ENC_STOPPED  = 2'd3    // Exited, can re-enter
  } enc_state_e;

  // ==========================================================================
  // Enclave Metadata Structure
  // ==========================================================================
  typedef struct packed {
    logic [TEE_ADDR_WIDTH-1:0]  base_addr;     // Physical base address
    logic [TEE_ADDR_WIDTH-1:0]  size;          // Region size in bytes
    logic [TEE_ADDR_WIDTH-1:0]  entry_point;   // Entry point address
    logic [3:0]                 pmp_idx;       // Assigned PMP entry index
    enc_state_e                 state;         // Current enclave state
    logic                       valid;         // Metadata slot in use
  } enclave_meta_t;

  // ==========================================================================
  // PMP Configuration Field (RISC-V Privileged Spec v1.12, Section 3.7.1)
  //
  // Bit layout within each 8-bit pmpcfg field:
  //   [7]   L    - Lock (1 = frozen until reset)
  //   [6:5] WIRI - Reserved (read 0, write ignored)
  //   [4:3] A    - Address matching mode
  //   [2]   X    - Execute permission
  //   [1]   W    - Write permission
  //   [0]   R    - Read permission
  // ==========================================================================
  typedef struct packed {
    logic       lock;      // [7]   Lock bit
    logic [1:0] reserved;  // [6:5] Reserved
    logic [1:0] addr_mode; // [4:3] Address matching mode
    logic       x;         // [2]   Execute permission
    logic       w;         // [1]   Write permission
    logic       r;         // [0]   Read permission
  } pmp_cfg_t;

  // PMP addressing modes
  typedef enum logic [1:0] {
    PMP_MODE_OFF   = 2'b00,   // Disabled
    PMP_MODE_TOR   = 2'b01,   // Top of Range
    PMP_MODE_NA4   = 2'b10,   // Naturally aligned 4-byte
    PMP_MODE_NAPOT = 2'b11    // Naturally aligned power-of-two
  } pmp_mode_e;

  // ==========================================================================
  // Trap Cause Codes (RISC-V Privileged Spec v1.12, Table 3.6)
  // ==========================================================================
  typedef enum logic [4:0] {
    TRAP_INST_MISALIGN   = 5'd0,
    TRAP_INST_ACCESS     = 5'd1,    // PMP denied instruction fetch
    TRAP_ILLEGAL_INST    = 5'd2,    // e.g., U-mode writes PMP CSR
    TRAP_BREAKPOINT      = 5'd3,
    TRAP_LOAD_MISALIGN   = 5'd4,
    TRAP_LOAD_ACCESS     = 5'd5,    // PMP denied load
    TRAP_STORE_MISALIGN  = 5'd6,
    TRAP_STORE_ACCESS    = 5'd7,    // PMP denied store
    TRAP_ECALL_U         = 5'd8,    // ecall from U-mode
    TRAP_ECALL_S         = 5'd9,    // ecall from S-mode
    TRAP_ECALL_M         = 5'd11,   // ecall from M-mode
    TRAP_INST_PAGE       = 5'd12,
    TRAP_LOAD_PAGE       = 5'd13,
    TRAP_STORE_PAGE      = 5'd15
  } trap_cause_e;

  // ==========================================================================
  // Custom CSR Addresses (in custom M-mode space 0x7C0-0x7FF)
  // ==========================================================================
  parameter logic [11:0] CSR_MENCLAVEID       = 12'h7C0;
  parameter logic [11:0] CSR_MENCLAVE_ACT     = 12'h7C1;
  parameter logic [11:0] CSR_MENCLAVEBASE     = 12'h7C2;
  parameter logic [11:0] CSR_MENCLAVEBOUND    = 12'h7C3;

  // Standard PMP CSR addresses
  parameter logic [11:0] CSR_PMPCFG0          = 12'h3A0;
  parameter logic [11:0] CSR_PMPCFG1          = 12'h3A1;
  parameter logic [11:0] CSR_PMPCFG2          = 12'h3A2;
  parameter logic [11:0] CSR_PMPCFG3          = 12'h3A3;
  parameter logic [11:0] CSR_PMPADDR0         = 12'h3B0;

  // Standard M-mode CSR addresses
  parameter logic [11:0] CSR_MSTATUS          = 12'h300;
  parameter logic [11:0] CSR_MTVEC            = 12'h305;
  parameter logic [11:0] CSR_MEPC             = 12'h341;
  parameter logic [11:0] CSR_MCAUSE           = 12'h342;
  parameter logic [11:0] CSR_MEDELEG          = 12'h302;

  // ==========================================================================
  // Memory Access Type
  // ==========================================================================
  typedef struct packed {
    logic read;
    logic write;
    logic exec;
  } mem_access_t;

endpackage

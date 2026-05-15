# Architecture Notes

Supplementary technical documentation for the TEE design. The top-level README covers the headline architecture; this document captures the design decisions and trade-offs in more depth.

## 1. Security Engine FSM

The Security Engine (SE) is a 14-state Mealy machine. States are organized into five lifecycle paths originating from `SE_IDLE`:

```
SE_IDLE
  ├── CREATE_VALIDATE → CREATE_COMMIT ─────────────────────────► SE_IDLE
  ├── ENTER_SAVE_CTX → ENTER_SCRUB → ENTER_PMP → ENTER_LAUNCH ─► SE_IDLE
  ├── EXIT_REVOKE → EXIT_SCRUB → EXIT_RESTORE → EXIT_RETURN ───► SE_IDLE
  ├── DESTROY_SCRUB → DESTROY_FREE ────────────────────────────► SE_IDLE
  └── FORWARD_SYSCALL (non-TEE ecall passthrough) ─────────────► SE_IDLE
```

### Why ENTER has four states (not two)

The original design encoded `ENTER` as two states: `ENTER_SAVE_CTX` (latch shadow + scrub main + set PMP), followed by `ENTER_LAUNCH` (drop privilege to U-mode via mret).

This produced a **race condition**: in the single-state-save-and-scrub formulation, the shadow bank latched its inputs from `regs_q` at the same clock edge that `regs_q` was being scrubbed. Whether the shadow captured pre-scrub or post-scrub values was timing-dependent.

The fix splits the operation across distinct cycles:
- `ENTER_SAVE_CTX` - assert `rf_save_o`, latch `regs_q` into shadow bank
- `ENTER_SCRUB` - assert `rf_scrub_o`, clear `regs_q` to zero
- `ENTER_PMP` - issue fast PMP activation sideband write
- `ENTER_LAUNCH` - trigger `mret`, transition to U-mode

The trade-off is one extra cycle per enclave entry in exchange for deterministic behavior. The four-state split also makes the FSM easier to verify with concurrent assertions: each phase has a single observable side effect.

### One-hot encoding

Vivado auto-infers a one-hot encoding for the SE FSM without requiring `(* fsm_encoding = "one_hot" *)` attribution. One-hot encoding provides:

- **Hamming distance ≥ 2** between any pair of valid states - a single-event upset (single-bit flip) cannot transition the FSM to another valid state
- **Single-LUT decode** for each state-dependent output - combinational paths from state to output are short
- **No "X-propagation"** issues if the FSM enters an invalid state - the default arm in the case statement deterministically returns to `SE_IDLE`

The 14-state FSM requires 14 flip-flops in one-hot encoding versus 4 in binary encoding. The area cost is negligible (10 extra FFs); the fault-tolerance benefit is meaningful for a security FSM.

## 2. Parallel-Match PMP - Implementation Details

### Comparator network

Each of the 16 PMP entries is encoded with:
- 8-bit configuration register (`pmpcfg`)
- 32-bit address register (`pmpaddr`)
- Independent comparator producing a 1-bit match signal

The match logic depends on the PMP mode encoded in `pmpcfg[A]`:

| Mode | Encoding | Match condition |
|---|---|---|
| `OFF`   | `2'b00` | Always 0 |
| `TOR`   | `2'b01` | `(addr >= pmpaddr[i-1]) && (addr < pmpaddr[i])` |
| `NA4`   | `2'b10` | `addr[31:2] == pmpaddr[31:2]` |
| `NAPOT` | `2'b11` | Range derived from trailing 1s in `pmpaddr` |

All 16 match signals are computed simultaneously from the incoming address.

### Balanced-tree priority encoding

The 16 match bits feed a balanced-tree priority encoder that produces a 4-bit `match_idx` indicating the lowest-numbered matching entry (RISC-V PMP semantics: lower-numbered entries have priority).

The tree depth is `ceil(log2(16)) = 4` levels of 2:1 selectors. Combined with the comparator stage and the final permission-check logic, the total critical-path depth is 13 LUT levels in the synthesized design - uniform across all 16 entries.

### Fast activation sideband

The PMP controller exposes two distinct write-port families:

- **CSR-mapped write port**: software writes to `pmpcfg0-3` and `pmpaddr0-15` arrive here through the standard CSR bus. Used during boot-time configuration by trusted firmware.
- **Fast activation sideband**: a single-cycle write path driven by the SE during `ENTER_PMP`. The SE drives `pmp_fast_activate_o`, `pmp_fast_idx_o`, and `pmp_fast_cfg_o` to install enclave-region PMP entries without CSR-write latency.

The fast path is essential because going through the CSR bus would require multiple cycles per PMP entry update, lengthening every enclave entry by 30+ cycles.

## 3. Register File and Shadow Bank

### Layout

```
tee_register_file
  ├── regs_q [0:31]         - main register file, 32 × 32-bit
  └── shadow_q [1:31]       - shadow bank, 31 × 32-bit (no x0 mirror)
```

Read ports:
- `rs1_addr_i` / `rs1_data_o` - standard combinational read port
- `rs2_addr_i` / `rs2_data_o` - second read port
- `bulk_rdata_o [1:31]` - full bulk read for SE consumption (32-entry vector)

Write ports:
- `rd_addr_i` / `rd_data_i` / `rd_we_i` - standard write port (x0 writes gated)
- `scrub_i` - single-cycle zero-all-registers control from SE
- `restore_i` / `shadow_data_i [1:31]` - bulk restore from shadow bank

### x0 handling

The architectural x0 register must always read zero. Two patterns exist in literature:

1. **Continuous-assign tie**: `assign regs_q[0] = '0;` - produces multi-driver warnings in tools that infer FFs for the entire array
2. **Initialize-and-gate**: `regs_q[0]` is initialized to zero on reset; all subsequent writes are gated with `(rd_addr_i != 5'd0)`

This design uses pattern (2). The synthesizer optimizes `regs_q[0]` to a constant-tie cell after seeing that no path can ever update it post-reset. Net effect: zero LUTs, zero FFs, zero critical warnings - same as the continuous-assign formulation but stylistically clean.

### Shadow bank security property

The shadow bank deliberately has no bus address. There is no CSR mapped to it, no PMP rule referencing it, no SE read-port exposing its contents to software. The only paths that touch it are internal to `tee_register_file`:

- Write: bulk save during `ENTER` (driven by SE `rf_save_o`)
- Read: bulk restore during `EXIT` (driven by SE `rf_restore_o`)

This is *security by construction* rather than enforcement. A PMP rule guarding software-accessible memory must be checked on every access (with the associated comparator cost and side-channel risk); the shadow bank has no such risk because no software-accessible address maps to it.

## 4. CSR Unit

### Standard CSRs implemented

| Address | Name | Width | Notes |
|---|---|---|---|
| `0x300` | `mstatus` | 32-bit | M-mode status; MIE, MPP fields |
| `0x305` | `mtvec` | 32-bit | M-mode trap vector |
| `0x341` | `mepc` | 32-bit | M-mode exception PC |
| `0x342` | `mcause` | 32-bit | M-mode trap cause |
| `0x302` | `medeleg` | 32-bit | Trap delegation (Ibex has no S-mode → unused) |
| `0x3A0`-`0x3A3` | `pmpcfg0-3` | 32-bit each | PMP config (4 × 8-bit) |
| `0x3B0`-`0x3BF` | `pmpaddr0-15` | 32-bit each | PMP entry addresses |

### Custom enclave CSRs

| Address | Name | Width | Notes |
|---|---|---|---|
| `0x7C0` | `menclaveid` | 4-bit | Active enclave ID (0 = none) |
| `0x7C1` | `menclave_activate` | 1-bit | Activation flag (auto-set on ENTER) |
| `0x7C2` | `menclavebase` | 32-bit | Active enclave base address |
| `0x7C3` | `menclavebound` | 32-bit | Active enclave upper bound |

All four custom CSRs are M-mode read/write only. U-mode reads return zero; U-mode writes raise `TRAP_ILLEGAL_INST`. The SE writes these through a sideband path during FSM transitions — no software in the loop.

The choice to allocate four CSRs (rather than packing the metadata into one) reflects RISC-V CSR access semantics: each CSR access is a single instruction (`csrr` / `csrw`) and packing multiple fields into one CSR would require multi-instruction software sequences to read/update individual fields.

## 5. Trap Routing

On Ibex (M + U mode, no S-mode), all traps route directly to M-mode. The `medeleg` CSR is implemented for spec compliance but is effectively unused.

The SE generates traps for:
- Enclave PMP violations (load/store/fetch from outside permitted region)
- Privileged-instruction violations from U-mode (e.g., writing PMP CSRs)
- Non-TEE ecalls in U-mode (forwarded via `forward_to_smode_o` despite no S-mode - would be the integration point for OS syscalls)

Trap entry sequence:
1. SE asserts `trap_i` with `trap_pc_i = pc_i`, `trap_cause_i`, `trap_priv_i`
2. CSR unit latches PC into `mepc`, cause into `mcause`, MPP from current privilege
3. CSR unit returns `mtvec` as `trap_target_o`
4. SE asserts `pipeline_flush_o` to redirect fetch

## 6. Integration Boundary

The TEE is designed to interface with Ibex at three specific touch points:

1. **PMP override into the load/store unit (LSU)**: the existing Ibex PMP module is replaced with `tee_pmp_controller`. The LSU's address-check output is sourced from `ex_granted_o` / `ex_fault_o`.

2. **CSR bus**: the existing Ibex CSR file is augmented with our four custom CSRs. The CSR bus carries `csr_addr`, `csr_wdata`, `csr_we`, `csr_re` from the EX stage.

3. **Ecall trap path**: when Ibex's ID stage decodes an ecall, `ecall_insn_i` is pulsed for one cycle. The SE FSM handles the dispatch.

Standalone synthesis (this repo) validates the IP block in isolation. Full Ibex integration is the next engineering phase.

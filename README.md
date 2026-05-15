## Hardware-Enforced Trusted Execution Environment for the Ibex RISC-V Core

![Status](https://img.shields.io/badge/status-functional-success)
![Tests](https://img.shields.io/badge/tests-6%2F6%20passing-success)
![Synthesis](https://img.shields.io/badge/synthesis-0%20critical%20warnings-success)
![Timing](https://img.shields.io/badge/timing-MET%20%2B2.68ns-success)
![FPGA](https://img.shields.io/badge/target-Zynq--7020-blue)
![Language](https://img.shields.io/badge/SystemVerilog-1720%20LOC-blueviolet)
![License](https://img.shields.io/badge/license-Apache%202.0-green)

A complete, open-source RTL implementation of a hardware-enforced Trusted Execution Environment (TEE) designed as an integration-ready IP block for the lowRISC Ibex RISC-V core. The design eliminates the timing side-channel inherent to conventional priority-encoded PMP through a parallel-match architecture, independently validated by the post-synthesis critical-path report.
---
# Why this project
Commercial TEEs (Intel SGX, ARM TrustZone) are proprietary at the hardware level. Open RISC-V academic designs (Sanctum, Keystone) typically rely on existing PMP implementations whose access time leaks which memory region matched through data-dependent comparator depth. This work replaces the standard cascading-MUX PMP with a balanced-tree parallel-match structure that produces constant logic depth across all PMP entries, eliminating the timing side-channel - and proves the property in synthesized hardware, not just in argument.

# Results
Metric	Value	Status
1) Tests passing	6 / 6	✅
2) Synthesis errors	0	✅
3) Critical warnings	0	✅
4) Slice LUTs	3,514 (6.61%)	
5) Slice Registers	3,172 (2.98%)
6) Target frequency	50 MHz
7) WNS (setup)	+2.680 ns	✅ MET
8) WHS (hold)	+0.103 ns	✅ MET
9) Failing endpoints	0 / 6,243	✅
10) Critical path	13 uniform logic levels	constant-time

Target: Xilinx Zynq-7020 (`xc7z020clg400-1`), speed grade −1, Vivado 2023.1.
The critical path traverses 13 logic levels from a PMP entry register through the parallel-match comparator network to `pipeline\_flush\_o`. This depth is uniform across all 16 PMP entries - directly observable in the synthesis report as evidence of the constant-time property.

# Architecture
```
                    ┌─────────────────────────────────────────────┐
                    │                tee_top                      │
                    │  ┌─────────────────┐   ┌─────────────────┐  │
   IF/EX ────────►  │  │  Security       │   │  PMP            │  │
   Trap ─────────►  │  │  Engine (FSM)   │   │  Controller     │  │
   CSR  ─────────►  │  │  14 states      │   │  parallel-match │  │
   DMEM ─────────►  │  └─────────────────┘   └─────────────────┘  │
                    │  ┌─────────────────┐   ┌─────────────────┐  │
                    │  │  CSR Unit       │   │  Register File  │  │
                    │  │  M-mode + 4     │   │  main + shadow  │  │
                    │  │  custom CSRs    │   │  bank           │  │
                    │  └─────────────────┘   └─────────────────┘  │
                    └─────────────────────────────────────────────┘
```
Four sub-modules cooperate behind `tee\_top`:
`tee\_security\_engine` - 14-state hardware FSM orchestrating enclave lifecycle (`CREATE`, `ENTER`, `EXIT`, `DESTROY`, `FORWARD`). Auto-inferred as one-hot by Vivado, providing Hamming-distance resistance to single-bit fault transitions.
`tee\_pmp\_controller` - parallel-match PMP with 16 entries. All comparators evaluated simultaneously, balanced-tree priority encoding produces constant 13-level logic depth.
`tee\_csr\_unit` - standard M-mode CSRs (`mstatus`, `mtvec`, `mepc`, `mcause`) plus 4 custom enclave CSRs in the RISC-V reserved vendor space (`0x7C0`–`0x7C3`).
`tee\_register\_file` - 32×32-bit main register file paired with a 31×32-bit shadow bank for single-cycle context save and restore. The shadow bank has no bus address - structurally inaccessible to software.
# Key design decisions
## Parallel-match PMP
A canonical PMP implementation checks each entry sequentially in priority order:
```
                  E0 → E1 → E2 → ... → E15 → grant
                  ^^             ^^^^^^^^^^^^
                  fast           slow (variable depth)
```
This produces data-dependent propagation delay: an access matching entry 0 traverses 1 logic level, an access matching entry 15 traverses up to 16. An attacker measuring access latency learns which PMP entry matched - a timing side-channel.
The parallel-match implementation flattens this to a balanced tree:
```
                  E0  ─┐
                  E1  ─┤
                  E2  ─┤── Balanced ── grant
                  ... ─┤    Tree
                  E15 ─┘
```
All 16 entries are compared simultaneously; the critical path is uniform 13 levels regardless of which entry matches. Trade-off: more area (more comparators, more wires) in exchange for constant-time access. Measured cost: ~37% of total cells.

## Shadow register bank
Conventional enclave context switch requires 31 store instructions to spill `x1`–`x31` to memory, then 31 loads on exit - roughly 62 cycles of memory traffic and an attack surface (the bus) through which register values transit.
The shadow bank is a dedicated 31×32-bit register array internal to `tee\_register\_file` with no bus address. On `ENTER`, the SE latches main → shadow and pulses `rf\_scrub\_o` in a single cycle. On `EXIT`, the inverse. This is security by construction: there is no PMP rule that needs to "guard" the shadow bank because there is no addressable path to reach it.

## M-mode-only custom CSRs
Address	Name	Purpose
`0x7C0`	`menclaveid`	4-bit ID of the currently active enclave
`0x7C1`	`menclave\_activate`	Activation flag, set on `ENTER`
`0x7C2`	`menclavebase`	Base address of active enclave region
`0x7C3`	`menclavebound`	Upper bound of active enclave region
`U`-mode reads return zero; `U`-mode writes raise `TRAP\_ILLEGAL\_INST`. The SE writes these through a sideband path on FSM transitions - no software in the loop.

## Threat model
In scope: compromised U-mode applications, memory snooping by non-enclave processes, register-state leakage across context switches, PMP timing side-channels.
Out of scope: compromised M-mode firmware (root of trust by construction), physical attacks (probing, fault injection), software bugs inside the enclave, remote attestation with cryptographic signing.

## Repository structure
```
riscv-tee-ibex/
├── README.md                   ← this file
├── LICENSE                     ← Apache 2.0
├── rtl/
│   ├── tee\_pkg.sv              ← types, enums, parameters, CSR addresses
│   ├── tee\_security\_engine.sv  ← 14-state hardware FSM
│   ├── tee\_pmp\_controller.sv   ← parallel-match PMP (16 entries)
│   ├── tee\_csr\_unit.sv         ← M-mode + 4 custom enclave CSRs
│   ├── tee\_register\_file.sv    ← main 32×32 + shadow 31×32 bank
│   └── tee\_top.sv              ← integration
├── tb/
│   └── tee\_rtl\_tb.sv           ← directed RTL integration testbench
├── synth/
│   ├── create\_project.tcl      ← Vivado project setup script
│   └── tee\_constraints.xdc     ← 50 MHz target SDC
└── docs/
    └── architecture.md         ← additional design notes
```
## How to reproduce
Prerequisites
Xilinx Vivado 2023.1 (Windows or Linux)
Target part `xc7z020clg400-1` (Zynq-7020, speed grade −1)
No FPGA board required (synthesis + sim only)
Run
```tcl
# In Vivado TCL console
cd <path-to-riscv-tee-ibex>
source synth/create\_project.tcl

# Behavioral simulation — expect "RESULTS: 6/6 passed"
launch\_simulation

# Synthesis — expect "WNS +2.680 ns MET, 0 critical warnings"
launch\_runs synth\_1 -jobs 4
wait\_on\_run synth\_1

# Reports
open\_run synth\_1
report\_utilization     -file util.rpt
report\_timing\_summary  -file timing.rpt
```
# Testbench summary
##	Test	What it verifies
1)	Reset	Post-reset state of FSM, registers, privilege
2)	CSR R/W	Read-after-write to MTVEC
3)	PMP M-mode	M-mode load bypasses PMP (expected behavior)
4)	ecall FSM	FSM advances out of `SE\_IDLE` on ecall trap
5)	Reg write	Read-after-write through register file
6)	FSM return	FSM returns to `SE\_IDLE` after lifecycle ops
All 6 tests pass after the integration patches described in commit history (`ecall\_a3` wiring through `tee\_top`, `x0` write gating in `tee\_register\_file`).

## Limitations / future work
Standalone delivery -> TEE is a complete IP block but is not yet integrated into the Ibex pipeline. Three boundary integration points are documented: PMP override into the load/store unit, the CSR bus, and the ecall trap path.
Single-hart only -> Multi-hart enclaves would require per-hart shadow banks and PMP entry partitioning.
Local attestation only -> Cryptographic remote attestation deferred - would require a hardware SHA core writing a sealed measurement CSR.
Verification depth -> Test 4 verifies FSM-leaves-IDLE behavior; full CREATE-commit observation requires exposing `enclave\_meta\_o` to the testbench (future-work item).

#Background
Built as the M.S. Computer Engineering capstone project at Binghamton University, advised by Prof. Wenfeng Zhao. Influenced by:
Costan, Lebedev, Devadas — Sanctum: Minimal Hardware Extensions for Strong Software Isolation (USENIX Security 2016)
Lee, Kohlbrenner, Shinde, Asanović, Song — Keystone: An Open Framework for Architecting Trusted Execution Environments (EuroSys 2020)
Bourgeat et al. — MI6: Secure Enclaves in a Speculative Out-of-Order Processor (MICRO 2019)
Weiser et al. — TIMBER-V: Tag-Isolated Memory Bringing Fine-grained Enclaves to RISC-V (NDSS 2019)
lowRISC contributors — Ibex Documentation

#License
Apache License 2.0 — see LICENSE. Includes explicit patent grant and patent-retaliation clause, appropriate for hardware security IP.

#Author
Srikanth Muthuvel Ganthimathi
M.S. Computer Engineering, Binghamton University
Advisor: Prof. Wenfeng Zhao

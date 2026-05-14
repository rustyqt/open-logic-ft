<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_fifo_async

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_fifo_async](../../src/ft/vhdl/olo_ft_fifo_async.vhd)

## Description

This component implements an **ECC-protected asynchronous FIFO** using SECDED (Single Error Correction, Double Error
Detection) Hamming code. It wraps [olo_base_fifo_async](../base/olo_base_fifo_async.md) internally with a wider word to
store parity bits alongside data.

The ECC is transparent to the user: data is automatically encoded on write and decoded/corrected on read. Error status
flags indicate whether a single-bit error was corrected or a double-bit error was detected.

## Generics

| Name            | Type      | Default  | Description                                                  |
| :-------------- | :-------- | -------- | :----------------------------------------------------------- |
| Width_g         | positive  | -        | Number of data bits per FIFO entry                           |
| Depth_g         | positive  | -        | Number of entries (must be power of two)                     |
| AlmFullOn_g     | boolean   | false    | Enable almost-full flag                                      |
| AlmFullLevel_g  | natural   | 0        | Almost-full threshold level                                  |
| AlmEmptyOn_g    | boolean   | false    | Enable almost-empty flag                                     |
| AlmEmptyLevel_g | natural   | 0        | Almost-empty threshold level                                 |
| RamStyle_g      | string    | "auto"   | Controls the RAM implementation resource                     |
| RamBehavior_g   | string    | "RBW"    | Controls the RAM behavior. "RBW" or "WBR"                    |
| ReadyRstState_g | std_logic | '1'      | Value of _In_Ready_ during reset                             |
| Optimization_g  | string    | "SPEED"  | "SPEED" or "LATENCY"                                         |
| SyncStages_g    | positive  | 2        | Number of clock domain crossing synchronizer stages (2-4)    |
| EccPipeline_g   | natural   | 0        | Number of pipeline stages after ECC decode on Out_Clk domain |

## Interfaces

### Input (In_Clk domain)

| Name          | In/Out | Length                  | Default | Description                                                  |
| :------------ | :----- | :---------------------- | ------- | :----------------------------------------------------------- |
| In_Clk        | in     | 1                       | -       | Input clock                                                  |
| In_Rst        | in     | 1                       | -       | Input reset                                                  |
| In_RstOut     | out    | 1                       | N/A     | Synchronized input reset output                              |
| In_Data       | in     | _Width_g_               | -       | Input data                                                   |
| In_Valid      | in     | 1                       | '1'     | Input valid                                                  |
| In_Ready      | out    | 1                       | N/A     | Input ready                                                  |
| In_ErrInj_BitFlip | in     | _eccCodewordWidth(Width_g)_ | (others => '0') | ECC error injection. Each '1' bit XORs (flips) the corresponding bit of the stored codeword. Popcount 1 = SEC-correctable, popcount 2 = DED-detectable. See [olo_ft_ram_sp - Error Injection](./olo_ft_ram_sp.md#error-injection). |
| In_Full       | out    | 1                       | N/A     | FIFO full (input side)                                       |
| In_Empty      | out    | 1                       | N/A     | FIFO empty (input side)                                      |
| In_AlmFull    | out    | 1                       | N/A     | Almost full (input side)                                     |
| In_AlmEmpty   | out    | 1                       | N/A     | Almost empty (input side)                                    |
| In_Level      | out    | _ceil(log2(Depth_g+1))_ | N/A     | Fill level (input side)                                      |

### Output (Out_Clk domain)

| Name        | In/Out | Length                  | Default | Description                                                  |
| :---------- | :----- | :---------------------- | ------- | :----------------------------------------------------------- |
| Out_Clk     | in     | 1                       | -       | Output clock                                                 |
| Out_Rst     | in     | 1                       | -       | Output reset                                                 |
| Out_RstOut  | out    | 1                       | N/A     | Synchronized output reset output                             |
| Out_Data    | out    | _Width_g_               | N/A     | Output data (corrected if single-bit error detected)         |
| Out_Valid   | out    | 1                       | N/A     | Output valid                                                 |
| Out_Ready   | in     | 1                       | '1'     | Output ready                                                 |
| Out_EccSec  | out    | 1                       | N/A     | Single error corrected flag                                  |
| Out_EccDed  | out    | 1                       | N/A     | Double error detected flag                                   |
| Out_Full    | out    | 1                       | N/A     | FIFO full (output side)                                      |
| Out_Empty   | out    | 1                       | N/A     | FIFO empty (output side)                                     |
| Out_AlmFull | out    | 1                       | N/A     | Almost full (output side)                                    |
| Out_AlmEmpty| out    | 1                       | N/A     | Almost empty (output side)                                   |
| Out_Level   | out    | _ceil(log2(Depth_g+1))_ | N/A     | Fill level (output side)                                     |

## Detailed Description

See [olo_base_fifo_async](../base/olo_base_fifo_async.md) for detailed FIFO behavior and
[olo_ft_ram_tdp](./olo_ft_ram_tdp.md) for details on ECC overhead and error injection.

## Clock Domain Crossing in TMR-Based Designs

This section documents the interaction between the asynchronous FIFO's internal clock domain
crossing (CDC) mechanism and Triple Module Redundancy (TMR) environments. It is relevant for
designers using this FIFO in radiation-hardened systems where vendor TMR tools (e.g., Synplify's
`syn_radhardlevel = "tmr"`) are applied to the surrounding logic.

### What ECC Protects

The ECC (SECDED Hamming code) protects the **data stored in the block RAM**. Data is encoded
before writing and decoded/corrected after reading. This addresses the dominant radiation
vulnerability: block RAM cells are static storage with large cross-sections and long exposure
windows (data persists until the next write, which may be microseconds to mission-lifetime).

### What ECC Does Not Protect

The FIFO's internal **CDC synchronizer registers** are not covered by ECC. The asynchronous FIFO
uses Gray-coded read/write pointers that cross clock domains through multi-stage flip-flop
synchronizers (`olo_base_cc_bits`). These synchronizer flip-flops are sequential elements that
can be affected by SEUs, just like any other flip-flop in the design. They should be covered by
vendor TMR (`syn_radhardlevel = "tmr"`), like all other flip-flops in the design.

Unlike RAM cells, synchronizer FFs are **refreshed every clock cycle** — a bit flip persists for
at most one clock period before being overwritten by the next valid pointer value. This makes
the synchronizer FFs orders of magnitude less vulnerable than the static RAM cells.

### The Sampling Uncertainty + SEU Concern

Li, Nelson, and Wirthlin [1] demonstrated that when TMR is applied to signals crossing
asynchronous clock domains, a combined failure mode can arise: the three TMR copies may arrive
in the receiving domain on different clock cycles due to routing delay differences (signal skew)
and the inherent randomness of asynchronous sampling. This is called **sampling uncertainty**.
If this causes a 2-vs-1 disagreement, a single SEU on one of the agreeing copies can flip the
majority vote — defeating TMR with a single fault.

Their fault injection experiments showed catastrophic failure rates for naively triplicated
**pulse-based** synchronizers — only 47% of signals arrived correctly in the presence of a
sensitive SEU.

### Why This Does Not Apply to Gray-Coded FIFO Pointers

The Li et al. failure mode applies to **transient pulse signals** where missing one cycle means
losing the information permanently. Gray-coded FIFO pointers are fundamentally different — they
are **persistent multi-bit level signals** with per-bit majority voting. Three properties make
them immune to this failure mode:

**Property 1: Per-bit voting produces only valid pointer values.**

The majority voter operates independently on each bit. At any sampling instant, the Gray code
guarantee ensures that at most **one bit** is transitioning (all other bits are stable and
identical across all three TMR copies). Therefore:

- For any **stable bit**: all three copies agree. A single SEU on one copy is corrected by the
  voter (2-of-3). This works unconditionally.
- For the **one transitioning bit**: sampling uncertainty may cause a 2-vs-1 split. A single SEU
  on the majority side can flip the voted result. But this only affects **one bit** — and that
  bit can only resolve to its old or new value. The result is either the current pointer value or
  the previous pointer value.

Since all other bits are voted correctly, the overall voted pointer is always either `Gray(N)` or
`Gray(N+1)` — **never an invalid value**. An invalid pointer would require **two simultaneous
SEUs**, which is beyond TMR's protection model.

**Property 2: Both possible voted values are safe for the FIFO.**

The async FIFO is designed to operate with +-1 pointer uncertainty — this is the fundamental
design principle of Gray-coded CDC. The synchronized pointer is always a possibly-stale version
of the actual pointer. Whether the voter outputs `Gray(N)` or `Gray(N+1)`:

- If the pointer appears **more stale** (old value): the FIFO flags are more conservative (full
  asserts earlier, empty de-asserts later). No data corruption — at worst, unnecessary
  backpressure for one cycle.
- If the pointer appears **more fresh** (new value): the FIFO flags are less conservative but
  still correct, since the pointer did reach that value.

Neither outcome causes an overflow, underflow, or read of invalid data.

**Property 3: Any voter error self-corrects within one cycle.**

The reflected binary Gray code has a second key property beyond single-bit changes: on two
**consecutive** increments, **never the same bit** changes (the changing-bit pattern follows
the ruler sequence: 0, 1, 0, 2, 0, 1, 0, 3, ...). Once a bit transitions, it holds its new
value for at least **two sender clock periods** before it can possibly change again. This means:

- Cycle N: bit K transitions, sampling uncertainty + SEU causes the voter to output the old value
- Cycle N+1: a **different** bit transitions; bit K is now stable across all three TMR copies
- The voter for bit K now sees three identical inputs — correct output regardless of any SEU

The error is transient and self-heals on the next clock cycle.

### No Clock Frequency Constraints

The standard Gray-coded async FIFO has **no constraints on the clock frequency ratio** between
the write and read clocks. The Gray code single-bit-change property applies at each **individual
sampling instant**, not between consecutive samples. Even if the sender clock is much faster
than the receiver clock and the pointer increments multiple times between receiver clock edges:

- At any receiver clock edge, the pointer is either stable or in the middle of a **single-bit**
  transition (the previous transitions have already settled)
- The receiver may "skip" intermediate pointer values, but each sample captures a valid Gray
  code value (or resolves metastability on one bit to an adjacent valid value)
- The only implicit requirement is that routing skew between pointer bits is less than one sender
  clock period, which is always satisfied in practical designs

This frequency-agnostic property is fundamental to the standard async FIFO design and is
preserved when vendor TMR is applied.

### Summary

| Concern | General TMR CDC [1] | Gray-Coded FIFO Pointers |
|---------|---------------------|--------------------------|
| Signal type | Transient pulse | Persistent level (multi-bit) |
| Voter granularity | Whole signal | Per-bit independent |
| "Wrong" voted value | Information lost | Previous valid pointer (safe) |
| Self-correction | No — pulse is gone | Yes — within 1 cycle |
| Invalid output possible? | Yes | No — always Gray(N) or Gray(N+-1) |
| Single SEU consequence | MTTF worse than unmitigated | No functional impact |
| Clock ratio constraint | Yes (pulsewidth dependent) | None |

Standard vendor TMR on the existing synchronizer is sufficient for Gray-coded FIFO pointer
crossings. No custom TMR synchronizer, pulse stretching, or clock ratio constraints are
required.

### Recommendations for Radiation-Hardened Designs

1. **Apply vendor TMR** (`syn_radhardlevel = "tmr"`) to the logic surrounding the FIFO,
   including the CDC synchronizer flip-flops. TMR covers flip-flops, LUT contents, and routing —
   everything except block RAM contents (which is what ECC protects).

2. **Use `syn_encoding = "safe,onehot"`** for all FSMs in the design to ensure recovery from
   illegal states caused by SEUs. See the
   [Synplify application note on safe VHDL state machines](https://digsys.upc.edu/csd/P06/designing_safe_vhdl.pdf)
   for details.

3. **Enable scrubbing on the protected RAM** (`olo_ft_ram_sdp` with `Scrub_g = true`) in any
   data-buffer use case. Scrubbing is essential to prevent single-bit errors from accumulating
   into uncorrectable double-bit errors in the block RAM. The integrated scrubber walks the
   address space autonomously using idle cycles, so it imposes no extra timing requirement.

### References

[1] Y. Li, B. Nelson, and M. Wirthlin, "Synchronization Techniques for Crossing Multiple Clock
Domains in FPGA-Based TMR Circuits," IEEE Transactions on Nuclear Science, vol. 57, no. 6,
pp. 3506-3514, Dec. 2010. DOI: 10.1109/TNS.2010.2086075

[2] Y. Fan and Z. Deng, "Design and verification for CDC synchronization based on TMR," IEICE
Electronics Express, vol. 17, no. 21, pp. 1-6, 2020. DOI: 10.1587/elex.17.20200287

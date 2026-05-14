<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_ram_sdp

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_ram_sdp](../../src/ft/vhdl/olo_ft_ram_sdp.vhd)

## Description

This component implements an **ECC-protected simple dual-port RAM** using SECDED (Single Error Correction, Double Error
Detection) Hamming code. It wraps [olo_base_ram_sdp](../base/olo_base_ram_sdp.md) internally with a wider word to store
parity bits alongside data.

The ECC is transparent to the user: data is automatically encoded on write and decoded/corrected on read. Error status
flags indicate whether a single-bit error was corrected or a double-bit error was detected.

When `Scrub_g = true`, the entity additionally embeds an **opportunistic memory scrubber** that walks the address
space autonomously using cycles in which the user is not driving the read or write port. The scrubber never stalls
the user; user data is always authoritative. See [Opportunistic Scrubbing](#opportunistic-scrubbing) below.

This is useful in **radiation-hardened** designs where single-event upsets (SEUs) can flip bits in memory cells.

## Generics

| Name           | Type     | Default | Description                                                  |
| :------------- | :------- | ------- | :----------------------------------------------------------- |
| Depth_g        | positive | -       | Number of addresses the RAM has                              |
| Width_g        | positive | -       | Number of data bits stored per address (word-width). The internal RAM is wider to accommodate ECC parity bits. |
| IsAsync_g      | boolean  | false   | When _true_, the read port runs on a separate clock (_Rd_Clk_). Must be _false_ when `Scrub_g = true` (elaboration fails otherwise). |
| RamRdLatency_g | positive | 1       | Read latency inside the RAM. Higher values can help close timing. |
| RamStyle_g     | string   | "auto"  | Controls the RAM implementation resource. Passed through to [olo_base_ram_sdp](../base/olo_base_ram_sdp.md). |
| RamBehavior_g  | string   | "RBW"   | Controls the RAM behavior. <br>"RBW": Read-before-write<br>"WBR": Write-before-read |
| EccPipeline_g  | natural  | 0       | Number of pipeline stages after ECC decode. <br>0 = combinational output (default). <br>1+ = adds register stages to break the critical path. Total read latency becomes _RamRdLatency_g_ + _EccPipeline_g_. |
| Scrub_g        | boolean  | false   | When _true_, an internal opportunistic scrubber walks the address space and writes back corrected codewords on SEC. Requires _IsAsync_g_ = false. |

## Interfaces

### Clock and Reset

| Name   | In/Out | Length | Default | Description                                                  |
| :----- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Clk    | in     | 1      | -       | Write-side clock (also read clock when _IsAsync_g_ = false). The scrubber runs on this clock. |
| Rst    | in     | 1      | '0'     | Synchronous reset on _Clk_. Resets the scrubber FSM; the RAM contents are not cleared. |
| Rd_Clk | in     | 1      | '0'     | Read-side clock. Only used when _IsAsync_g_ = true.          |
| Rd_Rst | in     | 1      | '0'     | Synchronous reset on _Rd_Clk_. Only used when _IsAsync_g_ = true. |

### Write Port

| Name           | In/Out | Length                       | Default          | Description                                                  |
| :------------- | :----- | :--------------------------- | ---------------- | :----------------------------------------------------------- |
| Wr_Addr        | in     | _ceil(log2(Depth_g))_        | -                | Write address                                                |
| Wr_Ena         | in     | 1                            | '1'              | Write enable                                                 |
| Wr_Data        | in     | _Width_g_                    | -                | Write data                                                   |

### Read Port

| Name      | In/Out | Length                | Default | Description                                                  |
| :-------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| Rd_Addr   | in     | _ceil(log2(Depth_g))_ | -       | Read address                                                 |
| Rd_Ena    | in     | 1                     | '1'     | Read enable                                                  |
| Rd_Data   | out    | _Width_g_             | N/A     | Read data (corrected if a single-bit error was detected)     |
| Rd_Valid  | out    | 1                     | N/A     | Read-data valid flag. '1' on cycles when _Rd_Data_/_Rd_EccSec_/_Rd_EccDed_ correspond to a user-issued read (_Rd_Ena_ delayed by _RamRdLatency_g_+_EccPipeline_g_). Cycles consumed by the scrubber's own reads are masked out. |
| Rd_EccSec | out    | 1                     | N/A     | Single error corrected flag. '1' when a single-bit error was detected and corrected. |
| Rd_EccDed | out    | 1                     | N/A     | Double error detected flag. '1' when an uncorrectable double-bit error was detected. Read data is unreliable in this case. |

### Error Injection

| Name           | In/Out | Length                      | Default          | Description                                                  |
| :------------- | :----- | :-------------------------- | ---------------- | :----------------------------------------------------------- |
| ErrInj_BitFlip | in     | _eccCodewordWidth(Width_g)_ | (others => '0') | ECC error injection for testing/BIST. Each '1' bit XORs (flips) the corresponding bit of the stored codeword on the next user write. Popcount 1 = SEC-correctable, popcount 2 = DED-detectable. Suppressed during scrubber writebacks. See [olo_ft_ram_tdp - Error Injection](./olo_ft_ram_tdp.md#error-injection). |
| ErrInj_Valid   | in     | 1                           | '0'              | Strobe that latches the _ErrInj_BitFlip_ pattern into the codec; the pattern is applied to the next user write and then cleared. |

### Scrubber Status

When `Scrub_g = false`, all of these outputs are tied to '0'.

| Name           | In/Out | Length | Default | Description                                                  |
| :------------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Scrub_Active   | out    | 1      | N/A     | '1' while the scrubber FSM holds a read or writeback in flight; '0' when the FSM is idle. |
| Scrub_EccSec   | out    | 1      | N/A     | Pulses '1' on the cycle the scrubber decoded a SEC-correctable error on its own read. |
| Scrub_EccDed   | out    | 1      | N/A     | Pulses '1' on the cycle the scrubber decoded a DED on its own read. The scrubber **does not** write the cell back in this case (the corrected value is unreliable). |
| Scrub_PassDone | out    | 1      | N/A     | Pulses '1' on the cycle the scrubber's address counter rolls from _Depth_g_-1 back to 0, indicating a complete pass over the memory. |

## Detailed Description

See [olo_ft_ram_tdp](./olo_ft_ram_tdp.md) for details on ECC overhead, architecture, error injection, and constraints
that apply across the entire FT area.

### Opportunistic Scrubbing

When `Scrub_g = true`, an internal scrubber FSM walks every address of the RAM and writes back the corrected codeword
on a corrected SEC. Key properties:

- **Free-running.** The scrubber has no rate-limit generic. It advances as fast as user-idle cycles allow: a tightly
  used port slows the scrubber down, an idle port lets it run at one address per RMW window.
- **Opportunistic on both ports.** The scrubber issues its read only on cycles where `Rd_Ena = '0'`, and its writeback
  only on cycles where `Wr_Ena = '0'`. The user is never stalled.
- **User-write-wins hazard policy.** If the user writes to the address currently being scrubbed at any cycle between
  the scrubber's read-issue and its writeback, the scrubber aborts the writeback (sticky internal `Collision` flag).
  User data is always authoritative.
- **ON_ERROR writeback policy.** The scrubber only writes back when the read decoded as a correctable single-bit
  error (SEC). Clean cells are left untouched; DED reads are reported via _Scrub_EccDed_ but **never** written back
  (writing the unreliable corrected codeword over a previously-detectable DED would silently corrupt memory).
- **Synchronous only.** The scrubber FSM observes user activity on a single clock; `Scrub_g = true` therefore requires
  `IsAsync_g = false` and is enforced by an elaboration-time `assert ... severity failure`.

The user-facing `Rd_Valid` is gated so cycles consumed by the scrubber's own reads do not pulse it; only reads the
user issued show up as `Rd_Valid = '1'`.

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

For an opportunistic background memory scrubber, use [olo_ft_ram_sdp_scrub](./olo_ft_ram_sdp_scrub.md) — a separate
entity that wraps this one plus the scrubber FSM. The scrub variant is sync-only (no `IsAsync_g`).

This is useful in **radiation-hardened** designs where single-event upsets (SEUs) can flip bits in memory cells.

## Generics

| Name           | Type     | Default | Description                                                  |
| :------------- | :------- | ------- | :----------------------------------------------------------- |
| Depth_g        | positive | -       | Number of addresses the RAM has                              |
| Width_g        | positive | -       | Number of data bits stored per address (word-width). The internal RAM is wider to accommodate ECC parity bits. |
| IsAsync_g      | boolean  | false   | When _true_, the read port runs on a separate clock (_Rd_Clk_). |
| RamRdLatency_g | positive | 1       | Read latency inside the RAM. Higher values can help close timing. |
| RamStyle_g     | string   | "auto"  | Controls the RAM implementation resource. Passed through to [olo_base_ram_sdp](../base/olo_base_ram_sdp.md). |
| RamBehavior_g  | string   | "RBW"   | Controls the RAM behavior. <br>"RBW": Read-before-write<br>"WBR": Write-before-read |
| EccPipeline_g  | natural  | 0       | Number of pipeline stages after ECC decode. <br>0 = combinational output (default). <br>1+ = adds register stages to break the critical path. Total read latency becomes _RamRdLatency_g_ + _EccPipeline_g_. |

## Interfaces

### Clock and Reset

| Name   | In/Out | Length | Default | Description                                                  |
| :----- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Clk    | in     | 1      | -       | Write-side clock (also read clock when _IsAsync_g_ = false). |
| Rst    | in     | 1      | '0'     | Synchronous reset on _Clk_. The RAM contents are not cleared. |
| Rd_Clk | in     | 1      | '0'     | Read-side clock. Only used when _IsAsync_g_ = true.          |
| Rd_Rst | in     | 1      | '0'     | Synchronous reset on _Rd_Clk_. Only used when _IsAsync_g_ = true. |

### Write Port

| Name    | In/Out | Length                | Default | Description     |
| :------ | :----- | :-------------------- | ------- | :-------------- |
| Wr_Addr | in     | _ceil(log2(Depth_g))_ | -       | Write address   |
| Wr_Ena  | in     | 1                     | '1'     | Write enable    |
| Wr_Data | in     | _Width_g_             | -       | Write data      |

### Read Port

| Name      | In/Out | Length                | Default | Description                                                  |
| :-------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| Rd_Addr   | in     | _ceil(log2(Depth_g))_ | -       | Read address                                                 |
| Rd_Ena    | in     | 1                     | '1'     | Read enable                                                  |
| Rd_Data   | out    | _Width_g_             | N/A     | Read data (corrected if a single-bit error was detected)     |
| Rd_Valid  | out    | 1                     | N/A     | Read-data valid flag. Pulses '1' exactly _RamRdLatency_g_+_EccPipeline_g_ cycles after each _Rd_Ena_ = '1' cycle. |
| Rd_EccSec | out    | 1                     | N/A     | Single error corrected flag. '1' when a single-bit error was detected and corrected. |
| Rd_EccDed | out    | 1                     | N/A     | Double error detected flag. '1' when an uncorrectable double-bit error was detected. Read data is unreliable in this case. |

### Error Injection (optional)

| Name           | In/Out | Length                      | Default          | Description                                                  |
| :------------- | :----- | :-------------------------- | ---------------- | :----------------------------------------------------------- |
| ErrInj_BitFlip | in     | _eccCodewordWidth(Width_g)_ | (others => '0') | ECC error injection for testing/BIST. Each '1' bit XORs (flips) the corresponding bit of the stored codeword on the next user write. Popcount 1 = SEC-correctable, popcount 2 = DED-detectable. |
| ErrInj_Valid   | in     | 1                           | '0'              | Strobe that latches the _ErrInj_BitFlip_ pattern into the codec; the pattern is applied to the next user write and then cleared. |

## Detailed Description

See [olo_ft_ram_tdp](./olo_ft_ram_tdp.md) for details on ECC overhead, architecture, error injection, and constraints
that apply across the entire FT area.

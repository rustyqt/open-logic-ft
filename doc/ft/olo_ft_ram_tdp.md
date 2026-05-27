<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_ram_tdp

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_ram_tdp](../../src/ft/vhdl/olo_ft_ram_tdp.vhd)

## Description

This component implements an **ECC-protected true dual-port RAM** using SECDED (Single Error Correction, Double Error
Detection) Hamming code. It wraps [olo_base_ram_tdp](../base/olo_base_ram_tdp.md) internally with a wider word to store
parity bits alongside data.

The ECC is transparent to the user: data is automatically encoded on write and decoded/corrected on read. Error status
flags indicate whether a single-bit error was corrected or a double-bit error was detected.

This is useful in **radiation-hardened** designs where single-event upsets (SEUs) can flip bits in memory cells, e.g. in
space or high-energy physics environments.

## Generics

| Name          | Type     | Default | Description                                                  |
| :------------ | :------- | ------- | :----------------------------------------------------------- |
| Depth_g       | positive | -       | Number of addresses the RAM has                              |
| Width_g       | positive | -       | Number of data bits stored per address (word-width). The internal RAM is wider to accommodate ECC parity bits. |
| RamRdLatency_g   | positive | 1       | Read latency inside the RAM. <br>1 is the behavior of a normal synchronous RAM.<br>Higher values can be desirable for timing-optimization. |
| RamStyle_g    | string   | "auto"  | Controls the RAM implementation resource. Passed through to [olo_base_ram_tdp](../base/olo_base_ram_tdp.md). |
| RamBehavior_g | string   | "RBW"   | Controls the RAM behavior. <br>"RBW": Read-before-write<br>"WBR": Write-before-read |
| EccPipeline_g | natural  | 0       | Number of pipeline stages after ECC decode. <br>0 = combinational output (default). <br>1+ = adds register stages to break the critical path after ECC correction. Total read latency becomes _RamRdLatency_g_ + _EccPipeline_g_. |

## Interfaces

### Port A

| Name           | In/Out | Length                | Default | Description                                                  |
| :------------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| A_Clk          | in     | 1                     | -       | Port A clock                                                 |
| A_Addr         | in     | _ceil(log2(Depth_g))_ | -       | Port A address                                               |
| A_WrEna        | in     | 1                     | '0'     | Port A write enable                                          |
| A_WrData       | in     | _Width_g_             | 0       | Port A write data                                            |
| A_ErrInj_BitFlip | in     | _eccCodewordWidth(Width_g)_ | (others => '0') | ECC error injection for testing/BIST. Each '1' bit XORs (flips) the corresponding bit of the stored codeword. Popcount 1 = SEC-correctable, popcount 2 = DED-detectable.<br>See [Error Injection](#error-injection). |
| A_RdData       | out    | _Width_g_             | N/A     | Port A read data (corrected if a single-bit error was detected) |
| A_RdValid      | out    | 1                     | N/A     | Port A read-data valid flag. '1' on cycles when _A_RdData_/_A_RdEccSec_/_A_RdEccDed_ correspond to a user-issued read (_A_WrEna_='0' delayed by _RamRdLatency_g_+_EccPipeline_g_). |
| A_RdEccSec     | out    | 1                     | N/A     | Single error corrected flag. '1' when a single-bit error was detected and corrected in the read data. |
| A_RdEccDed     | out    | 1                     | N/A     | Double error detected flag. '1' when an uncorrectable double-bit error was detected. Read data is unreliable in this case. |

### Port B

| Name           | In/Out | Length                | Default | Description                                                  |
| :------------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| B_Clk          | in     | 1                     | -       | Port B clock                                                 |
| B_Addr         | in     | _ceil(log2(Depth_g))_ | -       | Port B address                                               |
| B_WrEna        | in     | 1                     | '0'     | Port B write enable                                          |
| B_WrData       | in     | _Width_g_             | 0       | Port B write data                                            |
| B_ErrInj_BitFlip | in     | _eccCodewordWidth(Width_g)_ | (others => '0') | Same behavior as _A_ErrInj_BitFlip_                            |
| B_RdData       | out    | _Width_g_             | N/A     | Port B read data (corrected if a single-bit error was detected) |
| B_RdValid      | out    | 1                     | N/A     | Same behavior as _A_RdValid_                                 |
| B_RdEccSec     | out    | 1                     | N/A     | Same behavior as _A_RdEccSec_                                |
| B_RdEccDed     | out    | 1                     | N/A     | Same behavior as _A_RdEccDed_                                |

## Detailed Description

### Architecture

```
Write path:  WrData -> eccEncode -> XOR bit-flip injection -> wider internal RAM
Read path:   wider internal RAM -> eccSyndromeAndParity -> eccCorrectData + EccSec/EccDed -> [optional ECC pipeline]

```

The ECC encoding is combinational on the write path. The internal RAM (an instance of _olo_base_ram_tdp_ with wider
word) provides the configurable read pipeline (_RamRdLatency_g_). The ECC decoding is combinational after the read
pipeline, so the error flags are time-aligned with the read data.

When _EccPipeline_g_ > 0, additional register stages are inserted after the ECC decode logic. This breaks the
combinational path between the RAM output and the corrected data output, which can help close timing at high clock
frequencies. The total read latency becomes _RamRdLatency_g_ + _EccPipeline_g_ clock cycles.

### ECC Overhead

The SECDED Hamming code adds parity bits to each stored word:

| Data Width | Parity Bits | Total Stored Bits |
| :--------- | :---------- | :---------------- |
| 8          | 5           | 13                |
| 16         | 6           | 22                |
| 32         | 7           | 39                |
| 64         | 8           | 72                |
| 128        | 9           | 137               |

### Error Injection

The _A_ErrInj_BitFlip_ and _B_ErrInj_BitFlip_ ports allow arbitrary bit-flip patterns to be XORed into the stored codeword
on each write. This is useful for testing the ECC mechanism in simulation and for built-in self-test (BIST) in
hardware. Each port is the full codeword width (_eccCodewordWidth(Width_g)_), so any bit position can be exercised -
which is needed to fully verify the SECDED codec.

| Popcount of ErrInj_BitFlip | Meaning              | Behavior                                                            |
| :----------------------- | :------------------- | :------------------------------------------------------------------ |
| 0                        | No injection         | Codeword stored unchanged. _RdEccSec_ = '0', _RdEccDed_ = '0'.      |
| 1                        | Single-bit error     | SEC-correctable. _RdEccSec_ = '1', _RdEccDed_ = '0', data corrected. |
| 2                        | Double-bit error     | DED-detectable. _RdEccSec_ = '0', _RdEccDed_ = '1', data unreliable. |
| â‰¥ 3                      | Outside SECDED range | Detection behavior is undefined - the SECDED Hamming code only guarantees correct classification for at most 2 bit errors. |

Codeword bit 0 is the overall parity bit, bits at power-of-2 positions (1, 2, 4, 8, ...) are Hamming parity bits, and
all remaining positions hold data bits. See [olo_ft_pkg_ecc](./olo_ft_pkg_ecc.md) for the full codeword layout.

### Constraints

- Byte enables are not supported (ECC covers the full word; partial writes would invalidate parity)
- RAM initialization is not supported (the internal RAM stores ECC codewords, not raw data)
- True dual-port RAM is _NOT_ supported when compiling with Yosys for Cologne Chip FPGAs

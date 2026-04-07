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
| RdLatency_g   | positive | 1       | Read latency. <br>1 is the behavior of a normal synchronous RAM.<br>Higher values can be desirable for timing-optimization. The ECC decode is combinational after the read pipeline, so increasing _RdLatency_g_ can help close timing. |
| RamStyle_g    | string   | "auto"  | Controls the RAM implementation resource. Passed through to [olo_base_ram_tdp](../base/olo_base_ram_tdp.md). |
| RamBehavior_g | string   | "RBW"   | Controls the RAM behavior. <br>"RBW": Read-before-write<br>"WBR": Write-before-read |

## Interfaces

### Port A

| Name           | In/Out | Length                | Default | Description                                                  |
| :------------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| A_Clk          | in     | 1                     | -       | Port A clock                                                 |
| A_Addr         | in     | _ceil(log2(Depth_g))_ | -       | Port A address                                               |
| A_WrEna        | in     | 1                     | '0'     | Port A write enable                                          |
| A_WrData       | in     | _Width_g_             | 0       | Port A write data                                            |
| A_WrEccBitFlip | in     | 2                     | "00"    | ECC error injection for testing/BIST. Each bit flips the corresponding bit in the stored codeword.<br>"01" = single-bit error, "11" = double-bit error.<br>See [Error Injection](#error-injection). |
| A_RdData       | out    | _Width_g_             | N/A     | Port A read data (corrected if a single-bit error was detected) |
| A_RdSecErr     | out    | 1                     | N/A     | Single error corrected flag. '1' when a single-bit error was detected and corrected in the read data. |
| A_RdDedErr     | out    | 1                     | N/A     | Double error detected flag. '1' when an uncorrectable double-bit error was detected. Read data is unreliable in this case. |

### Port B

| Name           | In/Out | Length                | Default | Description                                                  |
| :------------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| B_Clk          | in     | 1                     | -       | Port B clock                                                 |
| B_Addr         | in     | _ceil(log2(Depth_g))_ | -       | Port B address                                               |
| B_WrEna        | in     | 1                     | '0'     | Port B write enable                                          |
| B_WrData       | in     | _Width_g_             | 0       | Port B write data                                            |
| B_WrEccBitFlip | in     | 2                     | "00"    | Same behavior as _A_WrEccBitFlip_                            |
| B_RdData       | out    | _Width_g_             | N/A     | Port B read data (corrected if a single-bit error was detected) |
| B_RdSecErr     | out    | 1                     | N/A     | Same behavior as _A_RdSecErr_                                |
| B_RdDedErr     | out    | 1                     | N/A     | Same behavior as _A_RdDedErr_                                |

## Detailed Description

### Architecture

```
Write path:  WrData -> eccEncode -> XOR bit-flip injection -> wider internal RAM
Read path:   wider internal RAM -> eccSyndromeAndParity -> eccCorrectData + SecErr/DedErr
```

The ECC encoding is combinational on the write path. The internal RAM (an instance of _olo_base_ram_tdp_ with wider
word) provides the configurable read pipeline (_RdLatency_g_). The ECC decoding is combinational after the read
pipeline, so the error flags are time-aligned with the read data.

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

The _A_WrEccBitFlip_ and _B_WrEccBitFlip_ ports allow deliberate injection of bit errors into stored codewords. This
is useful for testing the ECC mechanism in simulation and for built-in self-test (BIST) in hardware.

- Setting bit 0 to '1' flips bit 0 of the stored codeword (overall parity bit)
- Setting bit 1 to '1' flips bit 1 of the stored codeword (first Hamming parity bit)
- Setting both bits to '1' injects a double-bit error

### Constraints

- Byte enables are not supported (ECC covers the full word; partial writes would invalidate parity)
- RAM initialization is not supported (the internal RAM stores ECC codewords, not raw data)
- True dual-port RAM is _NOT_ supported when compiling with Yosys for Cologne Chip FPGAs

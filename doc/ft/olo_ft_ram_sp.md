<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_ram_sp

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_ram_sp](../../src/ft/vhdl/olo_ft_ram_sp.vhd)

## Description

This component implements an **ECC-protected single-port RAM** using SECDED (Single Error Correction, Double Error
Detection) Hamming code. It wraps [olo_base_ram_sp](../base/olo_base_ram_sp.md) internally with a wider word to store
parity bits alongside data.

The ECC is transparent to the user: data is automatically encoded on write and decoded/corrected on read. Error status
flags indicate whether a single-bit error was corrected or a double-bit error was detected.

This is useful in **radiation-hardened** designs where single-event upsets (SEUs) can flip bits in memory cells.

## Generics

| Name          | Type     | Default | Description                                                  |
| :------------ | :------- | ------- | :----------------------------------------------------------- |
| Depth_g       | positive | -       | Number of addresses the RAM has                              |
| Width_g       | positive | -       | Number of data bits stored per address (word-width). The internal RAM is wider to accommodate ECC parity bits. |
| RdLatency_g   | positive | 1       | Read latency. Higher values can help close timing.           |
| RamStyle_g    | string   | "auto"  | Controls the RAM implementation resource. Passed through to [olo_base_ram_sp](../base/olo_base_ram_sp.md). |
| RamBehavior_g | string   | "RBW"   | Controls the RAM behavior. <br>"RBW": Read-before-write<br>"WBR": Write-before-read |

## Interfaces

| Name         | In/Out | Length                | Default | Description                                                  |
| :----------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| Clk          | in     | 1                     | -       | Clock                                                        |
| Addr         | in     | _ceil(log2(Depth_g))_ | -       | Address                                                      |
| WrEna        | in     | 1                     | '1'     | Write enable                                                 |
| WrData       | in     | _Width_g_             | -       | Write data                                                   |
| WrEccBitFlip | in     | 2                     | "00"    | ECC error injection. "01" = single-bit error, "11" = double-bit error. See [olo_ft_ram_tdp - Error Injection](./olo_ft_ram_tdp.md#error-injection). |
| RdData       | out    | _Width_g_             | N/A     | Read data (corrected if a single-bit error was detected)     |
| RdSecErr     | out    | 1                     | N/A     | Single error corrected flag. '1' when a single-bit error was detected and corrected. |
| RdDedErr     | out    | 1                     | N/A     | Double error detected flag. '1' when an uncorrectable double-bit error was detected. Read data is unreliable in this case. |

## Detailed Description

See [olo_ft_ram_tdp](./olo_ft_ram_tdp.md) for details on ECC overhead, architecture, error injection, and constraints.

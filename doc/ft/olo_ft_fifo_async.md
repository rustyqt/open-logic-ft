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
| In_EccBitFlip | in     | 2                       | "00"    | ECC error injection. "01" = single-bit error, "11" = double-bit error. |
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
| Out_SecErr  | out    | 1                       | N/A     | Single error corrected flag                                  |
| Out_DedErr  | out    | 1                       | N/A     | Double error detected flag                                   |
| Out_Full    | out    | 1                       | N/A     | FIFO full (output side)                                      |
| Out_Empty   | out    | 1                       | N/A     | FIFO empty (output side)                                     |
| Out_AlmFull | out    | 1                       | N/A     | Almost full (output side)                                    |
| Out_AlmEmpty| out    | 1                       | N/A     | Almost empty (output side)                                   |
| Out_Level   | out    | _ceil(log2(Depth_g+1))_ | N/A     | Fill level (output side)                                     |

## Detailed Description

See [olo_base_fifo_async](../base/olo_base_fifo_async.md) for detailed FIFO behavior and
[olo_ft_ram_tdp](./olo_ft_ram_tdp.md) for details on ECC overhead and error injection.

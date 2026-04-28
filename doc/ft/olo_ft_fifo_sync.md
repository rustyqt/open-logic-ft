<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_fifo_sync

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_fifo_sync](../../src/ft/vhdl/olo_ft_fifo_sync.vhd)

## Description

This component implements an **ECC-protected synchronous FIFO** using SECDED (Single Error Correction, Double Error
Detection) Hamming code. It wraps [olo_base_fifo_sync](../base/olo_base_fifo_sync.md) internally with a wider word to
store parity bits alongside data.

The ECC is transparent to the user: data is automatically encoded on write and decoded/corrected on read. Error status
flags indicate whether a single-bit error was corrected or a double-bit error was detected.

## Generics

| Name            | Type      | Default | Description                                                  |
| :-------------- | :-------- | ------- | :----------------------------------------------------------- |
| Width_g         | positive  | -       | Number of data bits per FIFO entry. The internal FIFO is wider to accommodate ECC parity bits. |
| Depth_g         | positive  | -       | Number of entries the FIFO has                               |
| AlmFullOn_g     | boolean   | false   | Enable almost-full flag                                      |
| AlmFullLevel_g  | natural   | 0       | Almost-full threshold level                                  |
| AlmEmptyOn_g    | boolean   | false   | Enable almost-empty flag                                     |
| AlmEmptyLevel_g | natural   | 0       | Almost-empty threshold level                                 |
| RamStyle_g      | string    | "auto"  | Controls the RAM implementation resource                     |
| RamBehavior_g   | string    | "RBW"   | Controls the RAM behavior. "RBW" or "WBR"                    |
| ReadyRstState_g | std_logic | '1'     | Value of _In_Ready_ during reset                             |
| EccPipeline_g   | natural   | 0       | Number of pipeline stages after ECC decode. Uses [olo_base_pl_stage](../base/olo_base_pl_stage.md) with proper Valid/Ready handshaking. 0 = combinational output. |

## Interfaces

| Name          | In/Out | Length                   | Default | Description                                                  |
| :------------ | :----- | :----------------------- | ------- | :----------------------------------------------------------- |
| Clk           | in     | 1                        | -       | Clock                                                        |
| Rst           | in     | 1                        | -       | Reset                                                        |
| In_Data       | in     | _Width_g_                | -       | Input data                                                   |
| In_Valid      | in     | 1                        | '1'     | Input valid (AXI-S handshaking)                              |
| In_Ready      | out    | 1                        | N/A     | Input ready (AXI-S handshaking)                              |
| In_Level      | out    | _ceil(log2(Depth_g+1))_  | N/A     | Input-side fill level                                        |
| In_EccBitFlip | in     | _eccCodewordWidth(Width_g)_ | (others => '0') | ECC error injection. Each '1' bit XORs (flips) the corresponding bit of the stored codeword. Popcount 1 = SEC-correctable, popcount 2 = DED-detectable. See [olo_ft_ram_sp - Error Injection](./olo_ft_ram_sp.md#error-injection). |
| Out_Data      | out    | _Width_g_                | N/A     | Output data (corrected if a single-bit error was detected)   |
| Out_Valid     | out    | 1                        | N/A     | Output valid (AXI-S handshaking)                             |
| Out_Ready     | in     | 1                        | '1'     | Output ready (AXI-S handshaking)                             |
| Out_Level     | out    | _ceil(log2(Depth_g+1))_  | N/A     | Output-side fill level                                       |
| Out_EccSec    | out    | 1                        | N/A     | Single error corrected flag                                  |
| Out_EccDed    | out    | 1                        | N/A     | Double error detected flag. Read data is unreliable.         |
| Full          | out    | 1                        | N/A     | FIFO is full                                                 |
| AlmFull       | out    | 1                        | N/A     | FIFO is almost full                                          |
| Empty         | out    | 1                        | N/A     | FIFO is empty                                                |
| AlmEmpty      | out    | 1                        | N/A     | FIFO is almost empty                                         |

## Detailed Description

See [olo_base_fifo_sync](../base/olo_base_fifo_sync.md) for detailed FIFO behavior and
[olo_ft_ram_tdp](./olo_ft_ram_tdp.md) for details on ECC overhead and error injection.

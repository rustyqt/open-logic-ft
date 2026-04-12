<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_fifo_packet

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_fifo_packet](../../src/ft/vhdl/olo_ft_fifo_packet.vhd)

## Description

This component implements an **ECC-protected synchronous packet FIFO** using SECDED (Single Error Correction, Double
Error Detection) Hamming code. It wraps [olo_base_fifo_packet](../base/olo_base_fifo_packet.md) internally with a wider
word to store parity bits alongside data.

The ECC is transparent to the user: data is automatically encoded on write and decoded/corrected on read. Error status
flags indicate whether a single-bit error was corrected or a double-bit error was detected.

## Generics

| Name               | Type     | Default | Description                                                  |
| :----------------- | :------- | ------- | :----------------------------------------------------------- |
| Width_g            | positive | -       | Number of data bits per FIFO entry                           |
| Depth_g            | positive | -       | Number of entries (must be power of two)                     |
| FeatureSet_g       | string   | "FULL"  | "FULL" or "DROP_ONLY"                                        |
| RamStyle_g         | string   | "auto"  | Controls the RAM implementation resource                     |
| RamBehavior_g      | string   | "RBW"   | Controls the RAM behavior. "RBW" or "WBR"                    |
| SmallRamStyle_g    | string   | "auto"  | RAM style for internal packet-end FIFO                       |
| SmallRamBehavior_g | string   | "same"  | RAM behavior for internal packet-end FIFO                    |
| MaxPackets_g       | positive | 17      | Maximum number of packets in FIFO (min 2)                    |
| EccPipeline_g      | natural  | 0       | Number of pipeline stages after ECC decode                   |

## Interfaces

| Name          | In/Out | Length                     | Default | Description                                                  |
| :------------ | :----- | :------------------------- | ------- | :----------------------------------------------------------- |
| Clk           | in     | 1                          | -       | Clock                                                        |
| Rst           | in     | 1                          | -       | Reset                                                        |
| In_Valid      | in     | 1                          | '1'     | Input valid                                                  |
| In_Ready      | out    | 1                          | N/A     | Input ready                                                  |
| In_Data       | in     | _Width_g_                  | -       | Input data                                                   |
| In_Last       | in     | 1                          | '1'     | End of packet                                                |
| In_Drop       | in     | 1                          | '0'     | Drop current packet                                          |
| In_IsDropped  | out    | 1                          | N/A     | Indicates current input is being dropped                     |
| In_EccBitFlip | in     | 2                          | "00"    | ECC error injection. "01" = single-bit, "11" = double-bit.   |
| Out_Valid     | out    | 1                          | N/A     | Output valid                                                 |
| Out_Ready     | in     | 1                          | '1'     | Output ready                                                 |
| Out_Data      | out    | _Width_g_                  | N/A     | Output data (corrected if single-bit error detected)         |
| Out_Size      | out    | _ceil(log2(Depth_g+1))_    | N/A     | Packet size in words (FULL mode only)                        |
| Out_Last      | out    | 1                          | N/A     | End of packet                                                |
| Out_Next      | in     | 1                          | '0'     | Advance to next packet (FULL mode only)                      |
| Out_Repeat    | in     | 1                          | '0'     | Repeat current packet (FULL mode only)                       |
| Out_SecErr    | out    | 1                          | N/A     | Single error corrected flag                                  |
| Out_DedErr    | out    | 1                          | N/A     | Double error detected flag                                   |
| PacketLevel   | out    | _ceil(log2(MaxPackets_g+1))_ | N/A   | Number of complete packets in FIFO                           |
| FreeWords     | out    | _ceil(log2(Depth_g+1))_    | N/A     | Number of free word slots                                    |

## Detailed Description

See [olo_base_fifo_packet](../base/olo_base_fifo_packet.md) for detailed FIFO behavior and
[olo_ft_ram_tdp](./olo_ft_ram_tdp.md) for details on ECC overhead and error injection.

### Constraints

- In DROP_ONLY mode, the _In_Last_ flag is stored alongside the encoded data in the RAM but is not covered by the ECC
  parity. An SEU flipping the _In_Last_ bit would corrupt packet framing but not data content.
- In FULL mode, _In_Last_ is handled via a separate internal FIFO (also not ECC-protected).

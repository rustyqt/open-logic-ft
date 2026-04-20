<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_cc_reset

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_cc_reset](../../src/ft/vhdl/olo_ft_cc_reset.vhd)

## Description

TMR-hardened clock crossing for resets. This entity is structurally identical to
[olo_base_cc_reset](../base/olo_base_cc_reset.md) but instantiates
[olo_ft_cc_bits](./olo_ft_cc_bits.md) (triplicated, with per-bit majority voter) instead of
`olo_base_cc_bits` for the acknowledge-path synchronizers.

Reset on either side is asserted on the other clock domain immediately and de-asserted
synchronously to the corresponding clock. The reset is clock-crossed in both directions.

## Generics

| Name         | Type     | Default | Description                                                  |
| :----------- | :------- | :------ | :----------------------------------------------------------- |
| SyncStages_g | positive | 2       | Number of sync stages per TMR chain in the internal `olo_ft_cc_bits` (range 2-4). |

## Interfaces

| Name     | In/Out | Length | Default | Description                                       |
| :------- | :----- | :----- | :------ | :------------------------------------------------ |
| A_Clk    | in     | 1      | -       | Clock of domain A                                 |
| A_RstIn  | in     | 1      | '0'     | Reset input in domain A (active high)             |
| A_RstOut | out    | 1      | N/A     | Synchronized reset output in domain A             |
| B_Clk    | in     | 1      | -       | Clock of domain B                                 |
| B_RstIn  | in     | 1      | '0'     | Reset input in domain B (active high)             |
| B_RstOut | out    | 1      | N/A     | Synchronized reset output in domain B             |

## Detailed Description

The component behaves identically to `olo_base_cc_reset`. See that component's documentation
for the full protocol description. The only difference is that each of the two internal
acknowledge-path synchronizers is a TMR-hardened `olo_ft_cc_bits` instead of the non-TMR
`olo_base_cc_bits`. This protects the ack paths against single-event upsets in radiation
environments.

Note that the local request-path registers (`RstALatch`, `RstBLatch`, `RstRqstB2A`,
`RstRqstA2B`) are **not** manually triplicated in this entity. They should be covered by
vendor TMR (`syn_radhardlevel = "tmr"`) as part of the surrounding radiation-hardened design.

## Relationship to Other Components

- [olo_base_cc_reset](../base/olo_base_cc_reset.md): the non-TMR version with the same
  interface
- [olo_ft_cc_pulse](./olo_ft_cc_pulse.md): uses `olo_ft_cc_reset` internally for reset crossing

## References

[1] Y. Li, B. Nelson, and M. Wirthlin, "Synchronization Techniques for Crossing Multiple Clock
Domains in FPGA-Based TMR Circuits," IEEE Transactions on Nuclear Science, vol. 57, no. 6,
pp. 3506-3514, Dec. 2010. DOI: 10.1109/TNS.2010.2086075

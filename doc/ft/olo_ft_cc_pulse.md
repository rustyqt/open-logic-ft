<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_cc_pulse

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_cc_pulse](../../src/ft/vhdl/olo_ft_cc_pulse.vhd)

## Description

This component is a **TMR-hardened pulse clock domain crossing**. It implements the modified
short-pulse synchronizer from Li, Nelson, and Wirthlin [1] (Fig. 14), triplicated per Fig. 11 of
the same paper, with a per-bit majority voter at the output. It provides provable single-SEU
immunity for pulse-based CDC in radiation-hardened designs.

This is the fault-tolerant counterpart to [olo_base_cc_pulse](../base/olo_base_cc_pulse.md),
with the same pulse-based semantics but using the Li TMR synchronizer internally instead of a
toggle-and-2FF-synchronizer design. Pulses on `In_Pulse` are converted to pulses on `Out_Pulse`
across the clock domain boundary.

## Generics

| Name         | Type     | Default | Description                                                  |
| :----------- | :------- | :------ | :----------------------------------------------------------- |
| NumPulses_g  | positive | 1       | Number of independent pulse channels                         |
| SyncStages_g | positive | 3       | Number of receiver-domain sync stages. Range: 3-4. Default 3 matches Li Fig. 14 exactly. 4 stretches the output pulse by one cycle and relaxes the maximum clock-ratio constraint (see Timing Constraints). |

## Interfaces

| Name       | In/Out | Length         | Default | Description                                               |
| :--------- | :----- | :------------- | :------ | :-------------------------------------------------------- |
| In_Clk     | in     | 1              | -       | Sender's clock                                            |
| In_RstIn   | in     | 1              | '0'     | Reset in sender's domain (synchronously asserted input)   |
| In_RstOut  | out    | 1              | N/A     | Synchronized reset out (sender's domain)                  |
| In_Pulse   | in     | _NumPulses_g_  | -       | Pulse inputs (pulses on `In_Clk`)                         |
| Out_Clk    | in     | 1              | -       | Receiver's clock                                          |
| Out_RstIn  | in     | 1              | '0'     | Reset in receiver's domain                                |
| Out_RstOut | out    | 1              | N/A     | Synchronized reset out (receiver's domain)                |
| Out_Pulse  | out    | _NumPulses_g_  | N/A     | Pulse outputs (pulses on `Out_Clk`)                       |

## Detailed Description

### Architecture

Per pulse channel, the design instantiates three independent copies (A, B, C) of the Li Fig. 14
synchronizer, with a per-bit 2-of-3 majority voter at the output. The internal topology of each
copy is:

```
                              ┌───────── feedback ─────────┐
                              │                             │
In_Pulse[i] --> [S   Q]-- latch_out --> [D FF1 Q]-- ff1_out --(AND ~fb)-- ff2_in --> [D FF2 Q]-- ff3_in --> [D FF3 Q]-- rcvSig
                [R    ]<─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

The SR latch (one per TMR copy, per bit) is a level-sensitive latch that converts the input
pulse into a stable level. The level crosses the clock domain through FF1 and FF2, and FF3
(plus optional FF4 for `SyncStages_g = 4`) stretches the output pulse so that the downstream
voter sees sufficient overlap across all three TMR copies under worst-case sampling uncertainty.
The feedback from the last FF resets the latch and simultaneously gates the AND gate, producing
a clean single pulse at the receiver.

### TMR Safety

With the 2-cycle output pulse width (for `SyncStages_g = 3`) combined with the per-bit majority
voter, the design is provably immune to any single SEU on any flip-flop in any of the three
chains, even under worst-case sampling uncertainty between the chains. This has been verified
both analytically and experimentally in [1], showing 6 to 10 orders of magnitude MTTF improvement
over unmitigated designs.

The architecture sets `syn_radhardlevel = "none"` at the architecture level to prevent tools
like Synplify (used by Microchip Libero) from triplicating the already-triplicated registers.

### Timing Constraints

The user must respect these constraints:

1. **Input pulse width**: each input pulse must return to zero before the feedback round-trip
   completes. A single-cycle pulse on `In_Clk` is always safe. A multi-cycle pulse is fine if
   it returns to zero before the feedback arrives back at the SR latch. A sustained level
   signal is **not** supported — use [olo_base_cc_bits](../base/olo_base_cc_bits.md) with
   vendor TMR for level signals.

2. **Maximum clock ratio**: for the handshake to work correctly, the feedback round-trip time
   must exceed the input pulse duration. Approximately:
   ```
   f_out < SyncStages_g × f_in
   ```
   For `SyncStages_g = 3` and a single-cycle input pulse, this means `f_out < 3 × f_in`.
   Exceeding this ratio causes the feedback to return while the input pulse is still high,
   creating an S/R conflict in the SR latch. If you need a larger clock ratio, increase
   `SyncStages_g` to 4.

3. **Minimum spacing between consecutive pulses on the same bit**: approximately
   `2 × SyncStages_g + 2` `Out_Clk` cycles. The next pulse must not be issued until the
   feedback handshake is complete (latch reset, feedback de-asserted).

4. **Output pulse width**: `SyncStages_g − 1` `Out_Clk` cycles (2 cycles for `SyncStages_g = 3`,
   3 cycles for `SyncStages_g = 4`). Downstream logic must sample on any cycle while the output
   is high. If a single-cycle pulse is required at the output, add an edge detector on
   `Out_Pulse`.

### Reset Behavior

Reset is crossed between the two clock domains using
[olo_base_cc_reset](../base/olo_base_cc_reset.md), consistent with `olo_base_cc_pulse`. The
resulting synchronized resets (`In_RstOut`, `Out_RstOut`) are exposed to the user to help with
reset management in surrounding logic.

### Synthesis Notes

- The SR latch is an **intentional VHDL latch**. Synthesis tool warnings about latch inference
  on `LatchOut` can be ignored — the latch is a core part of the design.
- `syn_radhardlevel = "none"` prevents vendor TMR from triplicating already-triplicated
  registers. Tools that do not recognize this attribute will simply ignore it.
- Attributes `dont_merge`, `preserve`, `syn_preserve`, `syn_keep`, `dont_touch` are applied to
  prevent the synthesis tool from merging the three TMR copies into a single register chain
  (which would defeat the TMR).

## References

[1] Y. Li, B. Nelson, and M. Wirthlin, "Synchronization Techniques for Crossing Multiple Clock
Domains in FPGA-Based TMR Circuits," IEEE Transactions on Nuclear Science, vol. 57, no. 6,
pp. 3506-3514, Dec. 2010. DOI: 10.1109/TNS.2010.2086075

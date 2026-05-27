<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_cc_bits

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_cc_bits](../../src/ft/vhdl/olo_ft_cc_bits.vhd)

## Description

This component is a **TMR-hardened multi-bit clock domain crossing** for level signals. It
implements the long-pulse TMR synchronizer from Li, Nelson, and Wirthlin [1] (Fig. 12): three
independent N-stage synchronizer chains running in parallel, with a per-bit 2-of-3 majority
voter at the output.

It is the fault-tolerant counterpart to [olo_base_cc_bits](../base/olo_base_cc_bits.md) with an
identical interface. Use it for arbitrary level signals (control bits, status flags,
Gray-coded FIFO pointers, etc.) in radiation-hardened designs. For pulse-based CDC, consider
[olo_ft_cc_pulse](./olo_ft_cc_pulse.md) instead.

## Generics

| Name         | Type     | Default | Description                                                  |
| :----------- | :------- | :------ | :----------------------------------------------------------- |
| Width_g      | positive | 1       | Number of parallel bits                                      |
| SyncStages_g | positive | 2       | Number of receiver-domain sync stages per chain (range 2-4). Same meaning as in `olo_base_cc_bits`. |

## Interfaces

| Name     | In/Out | Length    | Default | Description                                               |
| :------- | :----- | :-------- | :------ | :-------------------------------------------------------- |
| In_Clk   | in     | 1         | -       | Sender's clock                                            |
| In_Rst   | in     | 1         | '0'     | Reset in sender's domain (active high)                    |
| In_Data  | in     | _Width_g_ | -       | Input data (level signal)                                 |
| Out_Clk  | in     | 1         | -       | Receiver's clock                                          |
| Out_Rst  | in     | 1         | '0'     | Reset in receiver's domain (active high)                  |
| Out_Data | out    | _Width_g_ | N/A     | Synchronized output data (level signal)                   |

## Detailed Description

### Architecture

For each bit, the design triplicates the standard synchronizer chain and combines the outputs
with a majority voter:

```
In_Data[i] --+--> RegIn_A --> Reg0_A --> RegN_A(..) --.
             |                                         \
             +--> RegIn_B --> Reg0_B --> RegN_B(..) ----+--> Voter --> Out_Data[i]
             |                                         /
             +--> RegIn_C --> Reg0_C --> RegN_C(..) --'
```

- Each TMR copy (A, B, C) has its own sender-side register (`RegIn`) clocked by `In_Clk` and
  its own chain of `SyncStages_g` receiver-side registers (`Reg0`, `RegN(0..)`) clocked by
  `Out_Clk`. This matches the structure of `olo_base_cc_bits`, replicated three times.
- The majority voter per bit is `(A AND B) OR (B AND C) OR (A AND C)`.
- A single SEU on any flip-flop in any of the three chains is masked by the voter.

### Why Standard Vendor TMR Is Not Enough

Naively applying vendor TMR (`syn_radhardlevel = "tmr"`) to the regular `olo_base_cc_bits`
would triplicate the synchronizer FFs, but the registers of the three copies would receive
their own independent views of the asynchronous input. Due to wire skew and sampling
uncertainty, the three copies may sample the input at different instants, leading to brief
2-vs-1 disagreements during transitions. Such disagreements combined with an SEU can defeat
the voter. This effect is analyzed in detail in [1].

For **Gray-coded** signals this failure mode is benign — the two possible voted values are
adjacent Gray codes, both of which the receiver handles correctly (see the discussion in
[olo_ft_fifo_async](./olo_ft_fifo_async.md)). For **arbitrary binary-coded** level signals,
however, a voter disagreement can produce a value that differs by any amount from the intended
value, which is not safe. `olo_ft_cc_bits` provides a TMR-correct implementation for the
general level-signal case by taking explicit control of the triplication and the voter.

### Synthesis Attributes

- **`syn_radhardlevel = "none"`** at the architecture level. Tells tools like Synplify
  (Microchip Libero) not to insert automatic TMR on top of the manually triplicated registers.
  Without this, the tool would blindly triplicate the already-triplicated registers.
- **All standard CDC attributes** from `olo_base_cc_bits` (`async_reg`, `dont_merge`,
  `preserve`, `syn_preserve`, `syn_keep`, `shreg_extract`, `syn_srlstyle`) applied to each
  triplicated register — ensures the synthesis tool cannot merge the three copies back into a
  single chain (which would defeat the TMR).

### Relationship to Other Components

- [olo_base_cc_bits](../base/olo_base_cc_bits.md): the non-TMR version with the same interface.
  For most designs this is sufficient.
- [olo_ft_cc_pulse](./olo_ft_cc_pulse.md): TMR-hardened CDC for pulses (Li Fig. 14 design).
  Use when the input is an event/pulse that must arrive exactly once at the receiver.
- [olo_ft_fifo_async](./olo_ft_fifo_async.md): uses standard `olo_base_cc_bits` internally for
  Gray-coded pointer crossings. Per-bit voting on Gray codes produces only valid pointer
  values, so `olo_ft_cc_bits` is not required there.

## References

[1] Y. Li, B. Nelson, and M. Wirthlin, "Synchronization Techniques for Crossing Multiple Clock
Domains in FPGA-Based TMR Circuits," IEEE Transactions on Nuclear Science, vol. 57, no. 6,
pp. 3506-3514, Dec. 2010. DOI: 10.1109/TNS.2010.2086075

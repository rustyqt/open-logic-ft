<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_ram_sp_scrub

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_ram_sp_scrub](../../src/ft/vhdl/olo_ft_ram_sp_scrub.vhd)

## Description

This component implements an **ECC-protected single-port RAM with an opportunistic memory scrubber**. It composes
two existing entities:

- [olo_ft_ram_sp](./olo_ft_ram_sp.md) — the SECDED-protected single-port RAM (encoder + RAM + decoder).
- [olo_ft_ram_scrubber](./olo_ft_ram_scrubber.md) — the private opportunistic scrubber FSM.

The user-facing interface is identical to [olo_ft_ram_sp](./olo_ft_ram_sp.md) plus four scrubber-status outputs.
ECC encoding/decoding is transparent; the scrubber additionally walks the address space autonomously and writes
corrected codewords back when a single-bit error is detected. Because the underlying RAM is single-port, the
scrubber only issues a read or writeback on cycles where the user is doing neither (`WrEna='0' and RdEna='0'`).
User accesses are never stalled.

This is useful in **radiation-hardened** designs where single-event upsets (SEUs) can flip bits in memory cells.

For background on the SECDED scheme, the codeword layout, error injection semantics and the constraints that
apply across the _ft_ area, see [olo_ft_principles](./olo_ft_principles.md) (when available) or
[olo_ft_ram_sp](./olo_ft_ram_sp.md).

## Generics

| Name           | Type     | Default | Description                                                  |
| :------------- | :------- | ------- | :----------------------------------------------------------- |
| Depth_g        | positive | -       | Number of addresses the RAM has                              |
| Width_g        | positive | -       | Number of data bits stored per address (word-width). The internal RAM is wider to accommodate ECC parity bits. |
| RamRdLatency_g | positive | 1       | Read latency of the wrapped RAM, _excluding_ ECC pipeline stages. Higher values can help close timing on the RAM read path. |
| RamStyle_g     | string   | "auto"  | Controls the RAM implementation resource. Passed through to [olo_base_ram_sp](../base/olo_base_ram_sp.md). |
| RamBehavior_g  | string   | "RBW"   | Controls the RAM behavior. <br>"RBW": Read-before-write<br>"WBR": Write-before-read |
| EccPipeline_g  | natural  | 0       | Number of pipeline register stages within the ECC decoder (range _0..2_). Total read latency is _RamRdLatency_g_ + _EccPipeline_g_ cycles. See [olo_ft_ram_sp](./olo_ft_ram_sp.md#generics) for details. |

## Interfaces

### Clock and Reset

| Name | In/Out | Length | Default | Description                                                  |
| :--- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Clk  | in     | 1      | -       | Clock                                                        |
| Rst  | in     | 1      | '0'     | Reset (high-active, synchronous to _Clk_). Resets the scrubber FSM and the read-valid pipeline. The stored RAM contents are unaffected (block RAMs cannot be reset). |

### FT RAM Port

| Name     | In/Out | Length                | Default | Description                                                  |
| :------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| Addr     | in     | _ceil(log2(Depth_g))_ | -       | Address                                                      |
| WrEna    | in     | 1                     | '1'     | Write enable                                                 |
| WrData   | in     | _Width_g_             | -       | Write data                                                   |
| RdEna    | in     | 1                     | '1'     | Read enable. _RdValid_ pulses '1' exactly _RamRdLatency_g_+_EccPipeline_g_ cycles after each cycle on which _RdEna_ = '1' (and _WrEna_ = '0'). Leave at the default '1' for continuous reads. |
| RdData   | out    | _Width_g_             | N/A     | Read data (corrected if a single-bit error was detected)     |
| RdValid  | out    | 1                     | N/A     | Read-data valid. Pulses '1' only for reads the user issued; cycles consumed by the scrubber's own reads are masked out. |
| RdEccSec | out    | 1                     | N/A     | Single error corrected flag. '1' when a single-bit error was detected and corrected on the user's current read. |
| RdEccDed | out    | 1                     | N/A     | Double error detected flag. '1' when an uncorrectable double-bit error was detected. Read data is unreliable in this case. |

### Error Injection (optional)

These ports drive the internal [olo_ft_ecc_encode](./olo_ft_ecc_encode.md) instance (via the wrapped
[olo_ft_ram_sp](./olo_ft_ram_sp.md)). Leave them unconnected for normal operation.

> **Note on scrubber interaction.** `ErrInj_*` is design-for-test only. The encoder's injection latch is consumed
> by the very next encoder write, which in the scrub variant may be a scrubber writeback rather than the user's
> intended next write. Either drive `ErrInj_Valid = '1'` together with `WrEna = '1'` in the same cycle (immediate
> injection, bypasses the latch), or pause the scrubber with `Scrub_Enable <= '0'` while the latch is being
> preloaded and held — see [Pausing the Scrubber](#pausing-the-scrubber) for the deterministic sequence. Even in
> the worst case, a scrubber-corrupted cell is SEC-correctable and is repaired by the next scrubber pass over
> that address.

| Name           | In/Out | Length                                                              | Default | Description                                                  |
| :------------- | :----- | :------------------------------------------------------------------ | ------- | :----------------------------------------------------------- |
| ErrInj_BitFlip | in     | _[eccCodewordWidth](./olo_ft_pkg_ecc.md#ecccodewordwidth)(Width_g)_ | all 0   | Codeword-wide flip pattern. Each '1' bit XORs the corresponding bit of the stored codeword on the next user write. Popcount 1 = SEC-correctable, popcount 2 = DED-detectable. |
| ErrInj_Valid   | in     | 1                                                                   | '0'     | Strobe that latches _ErrInj\_BitFlip_ into the encoder's pending-injection register. The latched pattern is applied to the next user write. If _ErrInj\_Valid_ = '1' and _WrEna_ = '1' in the same cycle the pattern is applied directly without going through the latch. |

### Scrubber Control

| Name         | In/Out | Length | Default | Description                                                  |
| :----------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Scrub_Enable | in     | 1      | '1'     | External enable. '1' = scrubber runs as usual. '0' suspends the scrubber on the same cycle: the FSM is forced to `Idle_s`, both `Scrub_Rd_Ena` and `Scrub_Wr_Ena` are gated low combinationally, and the address counter is **preserved** so coverage resumes from the same address when this is reasserted. Use this to pin the scrubber down during ECC error-injection tests. |

### Scrubber Status

| Name           | In/Out | Length | Default | Description                                                  |
| :------------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Scrub_Valid    | out    | 1      | N/A     | Pulses '1' on the cycle a scrubber-issued read returns from the codec (one pulse per scrubber read, regardless of whether an ECC error was detected). Aligned with _Scrub_EccSec_ and _Scrub_EccDed_, so the user can qualify all three together by ANDing them with _Scrub_Valid_. Also used internally to mask the user-facing _RdValid_. |
| Scrub_EccSec   | out    | 1      | N/A     | Pulses '1' on the cycle the scrubber decoded a SEC-correctable error on its own read. |
| Scrub_EccDed   | out    | 1      | N/A     | Pulses '1' on the cycle the scrubber decoded a DED on its own read. The scrubber **does not** write the cell back in this case (the corrected value is unreliable). |
| Scrub_PassDone | out    | 1      | N/A     | Pulses '1' on the cycle the scrubber's address counter rolls from _Depth_g_-1 back to 0, indicating a complete pass over the memory. |

## Detailed Description

### Architecture

The wrapper composes two existing blocks plus a thin mux layer:

```
       user                                       scrubber
  Addr/WrEna/WrData/RdEna/ErrInj_*                 status
            |                                        ^
            v                                        |
       +---------+      Scrub_Rd/Wr_*       +-----------------+
       | user-   |<-------------------------| olo_ft_ram_     |
       | priority|                          |    scrubber     |
       | muxes   |          Dec_Rd_*        |                 |
       +---------+--------------------------+-----------------+
            |                                        ^
            v                                        |
       +---------------------+                       |
       |  olo_ft_ram_sp      |-----------------------+
       |  (encoder + RAM +   |  decoded R/W path
       |   decoder)          |
       +---------------------+
            |
            +-> user RdValid is gated through a length-(RamRdLatency_g + EccPipeline_g)
                shift register so scrubber-owned read cycles do not pulse it.
```

### Opportunistic Scrubbing

The opportunistic scrubbing model is the same as
[olo_ft_ram_sdp - Opportunistic Scrubbing](./olo_ft_ram_sdp.md#opportunistic-scrubbing), with one single-port
specialization:

- **Single shared port.** The scrubber issues its read **and** its writeback only on cycles where the user is
  doing nothing (`WrEna='0' AND RdEna='0'`). A continuously active user starves the scrubber but never causes
  data corruption.

All other properties carry over verbatim:

- **Free-running** — no rate-limit generic.
- **User-write-wins hazard policy** — sticky `Collision` flag aborts the writeback if the user wrote to the
  in-flight address.
- **ON_ERROR writeback policy** — only SEC errors are written back; DED is reported but not corrected.

The user-facing `RdValid` is gated through a `RamRdLatency_g + EccPipeline_g` shift register driven by
`RdEna AND NOT Scrub_Rd_Ena`, so cycles consumed by the scrubber's own reads do not pulse it.

### Pausing the Scrubber

`Scrub_Enable = '0'` drops the scrubber FSM to `Idle_s` on the same cycle and gates `Scrub_Rd_Ena` /
`Scrub_Wr_Ena` low combinationally. The internal address counter is preserved, so the next `Scrub_Enable = '1'`
resumes scrubbing from the same address. This is the deterministic way to keep the scrubber from interacting
with an injection-test sequence:

```vhdl
Scrub_Enable <= '0';
wait until rising_edge(Clk);     -- FSM is now in Idle_s
ErrInj_BitFlip <= some_pattern;  -- preload the encoder's injection latch
ErrInj_Valid   <= '1';
wait until rising_edge(Clk);
ErrInj_Valid   <= '0';
... wait / set up / verify ...
WrEna  <= '1';                   -- the latched pattern lands on this write
WrData <= test_value;
wait until rising_edge(Clk);
WrEna  <= '0';
... read back, check RdEccSec = '1' ...
Scrub_Enable <= '1';             -- resume background scrubbing
```

### ECC Overhead, Error Injection and Status Flags

See [olo_ft_ram_sp](./olo_ft_ram_sp.md) for ECC overhead (internal storage width vs. data width), error injection
semantics, and the meaning of _RdEccSec_ / _RdEccDed_. The behavior is identical because the underlying ECC path
is the same instance of [olo_ft_ram_sp](./olo_ft_ram_sp.md).

### Constraints

The no-byte-enables and no-initialization constraints from [olo_ft_ram_sp](./olo_ft_ram_sp.md) apply. No
additional `olo_ft_ram_sp_scrub`-specific constraints.

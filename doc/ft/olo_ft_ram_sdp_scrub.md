<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_ram_sdp_scrub

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_ram_sdp_scrub](../../src/ft/vhdl/olo_ft_ram_sdp_scrub.vhd)

## Description

This component implements an **ECC-protected simple dual-port RAM with an opportunistic memory scrubber**. It composes
two existing entities:

- [olo_ft_ram_sdp](./olo_ft_ram_sdp.md) — the SECDED-protected simple dual-port RAM (encoder + RAM + decoder).
- [olo_ft_ram_scrubber](./olo_ft_ram_scrubber.md) — the private opportunistic scrubber FSM.

The user-facing interface mirrors [olo_ft_ram_sdp](./olo_ft_ram_sdp.md) (write port + read port + error injection)
plus scrubber control (`Scrub_Enable`) and status outputs.

ECC encoding/decoding is transparent. The scrubber additionally walks the address space autonomously and writes
corrected codewords back when a single-bit error is detected. The scrubber issues its read only when `Rd_Ena='0'`
and its writeback only when `Wr_Ena='0'`; user accesses are never stalled.

This entity is **sync-only** — there is no `IsAsync_g` generic and no `Rd_Clk` / `Rd_Rst` port. The scrubber observes
user activity on a single clock to pick idle cycles. If you need async clocks, use plain
[olo_ft_ram_sdp](./olo_ft_ram_sdp.md) without scrubbing.

This is useful in **radiation-hardened** designs where single-event upsets (SEUs) can flip bits in memory cells.

## Generics

| Name           | Type     | Default | Description                                                  |
| :------------- | :------- | ------- | :----------------------------------------------------------- |
| Depth_g        | positive | -       | Number of addresses the RAM has                              |
| Width_g        | positive | -       | Number of data bits stored per address (word-width). The internal RAM is wider to accommodate ECC parity bits. |
| RamRdLatency_g | positive | 1       | Read latency of the wrapped RAM, _excluding_ ECC pipeline stages. Higher values can help close timing on the RAM read path. |
| RamStyle_g     | string   | "auto"  | Controls the RAM implementation resource. Passed through to [olo_base_ram_sdp](../base/olo_base_ram_sdp.md). |
| RamBehavior_g  | string   | "RBW"   | Controls the RAM behavior. <br>"RBW": Read-before-write<br>"WBR": Write-before-read |
| EccPipeline_g  | natural  | 0       | Number of pipeline register stages within the ECC decoder (range _0..2_). Total read latency is _RamRdLatency_g_ + _EccPipeline_g_ cycles. See [olo_ft_ram_sdp](./olo_ft_ram_sdp.md#generics) for details. |

## Interfaces

### Clock and Reset

| Name | In/Out | Length | Default | Description                                                  |
| :--- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Clk  | in     | 1      | -       | Clock                                                        |
| Rst  | in     | 1      | '0'     | Reset (high-active, synchronous to _Clk_). Resets the scrubber FSM. The stored RAM contents are unaffected (block RAMs cannot be reset). |

### Write Port

| Name    | In/Out | Length                | Default | Description     |
| :------ | :----- | :-------------------- | ------- | :-------------- |
| Wr_Addr | in     | _ceil(log2(Depth_g))_ | -       | Write address   |
| Wr_Ena  | in     | 1                     | '1'     | Write enable    |
| Wr_Data | in     | _Width_g_             | -       | Write data      |

### Read Port

| Name      | In/Out | Length                | Default | Description                                                  |
| :-------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| Rd_Addr   | in     | _ceil(log2(Depth_g))_ | -       | Read address                                                 |
| Rd_Ena    | in     | 1                     | '1'     | Read enable                                                  |
| Rd_Data   | out    | _Width_g_             | N/A     | Read data (corrected if a single-bit error was detected)     |
| Rd_Valid  | out    | 1                     | N/A     | Read-data valid. Pulses '1' only for reads the user issued; cycles consumed by the scrubber's own reads are masked out. |
| Rd_EccSec | out    | 1                     | N/A     | Single error corrected flag for the current user read.       |
| Rd_EccDed | out    | 1                     | N/A     | Double error detected flag for the current user read. Read data is unreliable in this case. |

### Error Injection (optional)

These ports drive the internal [olo_ft_ecc_encode](./olo_ft_ecc_encode.md) instance (via the wrapped
[olo_ft_ram_sdp](./olo_ft_ram_sdp.md)). Leave them unconnected for normal operation.

> **Note on scrubber interaction.** `ErrInj_*` is design-for-test only. The encoder's injection latch is consumed
> by the very next encoder write, which in this entity may be a scrubber writeback rather than the user's intended
> next write. Either drive `ErrInj_Valid = '1'` together with `Wr_Ena = '1'` in the same cycle (immediate injection,
> bypasses the latch), or pause the scrubber with `Scrub_Enable <= '0'` while the latch is being preloaded — see
> [Pausing the Scrubber](#pausing-the-scrubber). Even in the worst case, a scrubber-corrupted cell is
> SEC-correctable and is repaired by the next scrubber pass over that address.

| Name           | In/Out | Length                                                              | Default | Description                                                  |
| :------------- | :----- | :------------------------------------------------------------------ | ------- | :----------------------------------------------------------- |
| ErrInj_BitFlip | in     | _[eccCodewordWidth](./olo_ft_pkg_ecc.md#ecccodewordwidth)(Width_g)_ | all 0   | Codeword-wide flip pattern. Each '1' bit XORs the corresponding bit of the stored codeword on the next user write. Popcount 1 = SEC-correctable, popcount 2 = DED-detectable. |
| ErrInj_Valid   | in     | 1                                                                   | '0'     | Strobe that latches _ErrInj\_BitFlip_ into the encoder's pending-injection register. The latched pattern is applied to the next user write. If _ErrInj\_Valid_ = '1' and _Wr_Ena_ = '1' in the same cycle the pattern is applied directly without going through the latch. |

### Scrubber Control

| Name         | In/Out | Length | Default | Description                                                  |
| :----------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Scrub_Enable | in     | 1      | '1'     | External enable. '1' = scrubber runs as usual. '0' suspends the scrubber on the same cycle: the FSM is forced to `Idle_s` (after any in-flight read completes naturally), both `Scrub_Rd_Ena` and `Scrub_Wr_Ena` are gated low combinationally, and the address counter is preserved so coverage resumes from the same address on '1'. Use this to pin the scrubber down during ECC error-injection tests. |

### Scrubber Status

| Name           | In/Out | Length | Default | Description                                                  |
| :------------- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Scrub_Valid    | out    | 1      | N/A     | Pulses '1' on the cycle a scrubber-issued read returns from the codec (one pulse per scrubber read, regardless of whether an ECC error was detected). Aligned with _Scrub_EccSec_ and _Scrub_EccDed_, so the user can qualify all three together by ANDing them with _Scrub_Valid_. Also used internally to mask the user-facing _Rd_Valid_. |
| Scrub_EccSec   | out    | 1      | N/A     | Pulses '1' on the cycle the scrubber decoded a SEC-correctable error on its own read. |
| Scrub_EccDed   | out    | 1      | N/A     | Pulses '1' on the cycle the scrubber decoded a DED on its own read. The scrubber **does not** write the cell back in this case (the corrected value is unreliable). |
| Scrub_PassDone | out    | 1      | N/A     | Pulses '1' on the cycle after the scrubber's address counter rolls from _Depth_g_-1 back to 0, indicating a complete pass over the memory. |

## Detailed Description

### Architecture

The wrapper composes two existing blocks plus a thin mux layer:

```
       user                                       scrubber
   Wr_*/Rd_*/ErrInj_*                              status
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
       |  olo_ft_ram_sdp     |-----------------------+
       |  (encoder + SDP RAM |   decoded R/W path
       |   + decoder)        |
       +---------------------+
            |
            +-> user Rd_Valid is the inner Rd_Valid AND-NOT Scrub_Rd_Valid, so
                cycles consumed by the scrubber's own reads do not pulse it.
```

### Opportunistic Scrubbing

- **Free-running.** No rate-limit generic. The scrubber advances as fast as user-idle cycles allow.
- **Independent ports.** Because the underlying RAM has separate write and read ports, the scrubber's read can
  proceed concurrently with a user write (and vice versa). The scrubber only stalls on cycles where the user is
  using the *same* port.
- **User-write-wins hazard policy.** If the user writes to the address currently being scrubbed at any cycle between
  the scrubber's read-issue and its writeback, the scrubber aborts the writeback (sticky internal `Collision`
  flag). User data is always authoritative.
- **ON_ERROR writeback policy.** The scrubber only writes back when the read decoded as a correctable single-bit
  error (SEC). Clean cells are left untouched; DED reads are reported via _Scrub_EccDed_ but **never** written
  back.

The user-facing `Rd_Valid` is gated by `not Scrub_Valid` so cycles consumed by the scrubber's own reads do not
pulse it.

### Pausing the Scrubber

`Scrub_Enable = '0'` gates new scrubber requests combinationally on the same cycle. Any in-flight scrubber read
completes naturally so the internal `Scrub_Rd_Valid` pulse still fires and `Rd_Valid` masking stays correct; the
writeback is suppressed. The internal address counter is preserved (may advance by 1 if disabled mid-cycle), so
scrubbing resumes from the same neighbourhood on re-enable. The deterministic injection-test sequence:

```vhdl
Scrub_Enable <= '0';
wait until rising_edge(Clk);
ErrInj_BitFlip <= some_pattern;
ErrInj_Valid   <= '1';
wait until rising_edge(Clk);
ErrInj_Valid   <= '0';
... wait / set up / verify ...
Wr_Ena  <= '1';
Wr_Data <= test_value;
Wr_Addr <= test_addr;
wait until rising_edge(Clk);
Wr_Ena  <= '0';
... read back, check Rd_EccSec = '1' ...
Scrub_Enable <= '1';
```

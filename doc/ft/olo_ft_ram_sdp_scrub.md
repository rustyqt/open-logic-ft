<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_ram_sdp_scrub

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_ram_sdp_scrub](../../src/ft/vhdl/olo_ft_ram_sdp_scrub.vhd)

## Description

This component is an **ECC-protected simple dual-port RAM with built-in memory scrubber**. It wraps
[olo_ft_ram_sdp](./olo_ft_ram_sdp.md) and adds a scrubber FSM that periodically reads each memory
address, triggers ECC correction on the read pipeline, and writes the corrected value back. This
prevents single-event upsets (SEUs) from accumulating into uncorrectable double-bit errors over
time.

The scrubber and the user share both ports through internal multiplexers. The user must explicitly
halt the scrubber via a Stop/Stopped handshake before issuing accesses. The user protocol is
intentionally simple and the worst-case yield latency is just a few clock cycles.

This is useful in **radiation-hardened** designs where SEUs can flip bits in memory cells that may
otherwise sit untouched for long periods (configuration data, lookup tables, etc.).

Note: `IsAsync_g` is not supported because the scrubber FSM performs a synchronous
read-wait-decide-write sequence that requires both ports on the same clock.

## Generics

| Name          | Type     | Default    | Description                                                  |
| :------------ | :------- | :--------- | :----------------------------------------------------------- |
| Depth_g       | positive | -          | Number of addresses                                          |
| Width_g       | positive | -          | User data width                                              |
| RdLatency_g   | positive | 1          | Read latency (passed to underlying _olo_ft_ram_sdp_)         |
| RamStyle_g    | string   | "auto"     | Passed through                                               |
| RamBehavior_g | string   | "RBW"      | Passed through                                               |
| EccPipeline_g | natural  | 0          | Passed through                                               |
| ScrubPeriod_g | positive | 1024       | Cycles between consecutive scrub R-M-W operations. Larger = slower scrubbing, less port contention |
| ScrubMode_g   | string   | "ON_ERROR" | "ON_ERROR" = writeback only when SEC/DED detected; "ALWAYS" = unconditional writeback (cell refresh) |

## Interfaces

### User Write Port

| Name          | In/Out | Length                | Default | Description                                                  |
| :------------ | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| Clk           | in     | 1                     | -       | Clock                                                        |
| Rst           | in     | 1                     | -       | Synchronous reset                                            |
| Wr_Addr       | in     | _ceil(log2(Depth_g))_ | -       | Write address                                                |
| Wr_Ena        | in     | 1                     | '0'    | Write enable                                                 |
| Wr_Data       | in     | _Width_g_             | 0       | Write data                                                   |
| Wr_EccBitFlip | in     | 2                     | "00"    | ECC error injection (test/BIST). See [olo_ft_ram_tdp - Error Injection](./olo_ft_ram_tdp.md#error-injection). |

### User Read Port

| Name      | In/Out | Length                | Default | Description                                                  |
| :-------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| Rd_Addr   | in     | _ceil(log2(Depth_g))_ | -       | Read address                                                 |
| Rd_Ena    | in     | 1                     | '0'    | Read enable                                                  |
| Rd_Data   | out    | _Width_g_             | N/A     | Read data (corrected if a single-bit error was detected)    |
| Rd_SecErr | out    | 1                     | N/A     | Single error corrected flag (per read)                       |
| Rd_DedErr | out    | 1                     | N/A     | Double error detected flag (per read)                        |

### Scrubber Arbitration

| Name          | In/Out | Length | Default | Description                                                  |
| :------------ | :----- | :----- | ------- | :----------------------------------------------------------- |
| Scrub_Stop    | in     | 1      | '0'     | Assert to halt the scrubber and claim both ports             |
| Scrub_Stopped | out    | 1      | N/A     | '1' when scrubber has yielded the ports. Safe to issue user accesses |

### Scrubber Status

| Name           | In/Out | Length                | Default | Description                                                  |
| :------------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| Scrub_Active   | out    | 1                     | N/A     | '1' while scrubber FSM is processing an address              |
| Scrub_Addr     | out    | _ceil(log2(Depth_g))_ | N/A     | Current/most recent scrubbed address                         |
| Scrub_SecErr   | out    | 1                     | N/A     | Pulses '1' when scrubber finds a single-bit error            |
| Scrub_DedErr   | out    | 1                     | N/A     | Pulses '1' when scrubber finds a double-bit error            |
| Scrub_PassDone | out    | 1                     | N/A     | Pulses '1' when scrubber completes a full memory pass        |

## Detailed Description

### User Protocol

To issue accesses, the user logic must follow this sequence:

1. Assert _Scrub_Stop_ <= '1'
2. Wait until _Scrub_Stopped_ = '1'. Worst case ~_RdLatency_g_ + _EccPipeline_g_ + 4 clock cycles
3. Issue any number of accesses with normal SDP RAM semantics. Write on _Wr_Addr_/_Wr_Ena_/_Wr_Data_, read on _Rd_Addr_/_Rd_Ena_. Read data appears _RdLatency_g_ + _EccPipeline_g_ cycles after the address is sampled
4. Deassert _Scrub_Stop_ <= '0'
5. The scrubber resumes on the next clock cycle

### Architecture

```
                     ┌──────────────────┐
  User Wr_Addr/   ┌──┤                  │
  Wr_Ena/Wr_Data  │  │                  │
            WR MUX──►│  olo_ft_ram_sdp  │
   Scrubber FSM ──┘  │                  │
   (Write)           │                  │
                     │                  │
   User Rd_Addr/ ┌───┤                  │
   Rd_Ena        │   │                  │
            RD MUX──►│                  │
   Scrubber FSM ─┘   │                  │
   (Read)            └────┬─────────────┘
                          │
                          ▼
                   Rd_Data / Rd_SecErr / Rd_DedErr
                   → routed to user always
```

The wrapper instantiates an _olo_ft_ram_sdp_ with `IsAsync_g => false`. Two multiplexers select
between user signals and scrubber-FSM signals for each port based on the FSM state. While the
scrubber is in active states (Read, Wait, Decide, Write, Incr) the FSM drives both ports; while in
Idle or Yielded the user signals pass through.

### Scrubber FSM

The scrubber FSM has these states (identical to [olo_ft_ram_sp_scrub](./olo_ft_ram_sp_scrub.md)):

| State    | Action                                                                |
| :------- | :-------------------------------------------------------------------- |
| Idle     | Counts _ScrubPeriod_g_ cycles. If _Scrub_Stop_=1, transition to Yielded |
| Read     | Issues a read of the current scrub address on the read port           |
| Wait     | Waits _RdLatency_g_+_EccPipeline_g_ cycles for the read result        |
| Decide   | Captures the decoded read data and error flags                        |
| Write    | Writes the captured (corrected) value back on the write port, conditional on _ScrubMode_g_ |
| Incr     | Advances the scrub address (wraps → pulse _Scrub_PassDone_)           |
| Yielded  | Holds while _Scrub_Stop_=1; user owns both ports                      |

**Atomicity**: once the FSM enters Read state, the entire R-M-W sequence completes even if
_Scrub_Stop_ is asserted mid-cycle. The scrubber yields only between R-M-W operations.

### Scrub Modes

- **ON_ERROR** (default): The scrubber only writes the corrected value back when a SEC error
  was detected. This minimizes RAM port utilization.
- **ALWAYS**: The scrubber writes back on every R-M-W. This refreshes cell contents on every
  pass, useful for some aging-related effects, at the cost of higher port utilization.

In **both** modes, the scrubber **never writes back when a DED is detected**. The decoded data
on a double-bit error is unreliable (SECDED can detect but not correct double-bit errors), and
writing it back would silently corrupt memory by replacing a detectable error with a "valid"
codeword over wrong data. Instead, _Scrub_DedErr_ pulses and the corrupted memory is left
intact so the user can detect the unfixable error on their next read.

### Constraints

- The scrubber assumes user logic respects the Stop/Stopped handshake. Accesses issued while
  _Scrub_Stopped_ = '0' are ignored (the scrubber owns both ports).
- `IsAsync_g` is not supported. The scrubber FSM requires both ports on the same clock domain.
- _Scrub_PassDone_ is pulsed when the address counter wraps from _Depth_g_-1 back to 0.
- The scrubber does not protect against double-bit errors (SECDED can detect but not correct).
  When the scrubber encounters a DED, it pulses _Scrub_DedErr_ and **leaves the memory contents
  unchanged** (no writeback) so the error remains detectable on subsequent reads.

<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_ram_sp_scrub

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_ram_sp_scrub](../../src/ft/vhdl/olo_ft_ram_sp_scrub.vhd)

## Description

This component is an **ECC-protected single-port RAM with built-in memory scrubber**. It wraps
[olo_ft_ram_sp](./olo_ft_ram_sp.md) and adds a scrubber FSM that periodically reads each memory
address, triggers ECC correction on the read pipeline, and writes the corrected value back. This
prevents single-event upsets (SEUs) from accumulating into uncorrectable double-bit errors over
time.

The scrubber and the user share a single port through an internal multiplexer. The user must
explicitly halt the scrubber via a Stop/Stopped handshake before issuing accesses. The user
protocol is intentionally simple and the worst-case yield latency is just a few clock cycles.

This is useful in **radiation-hardened** designs where SEUs can flip bits in memory cells that may
otherwise sit untouched for long periods (configuration data, lookup tables, etc.).

### Why Stop/Stopped, not transparent dual-port?

A naive "transparent" scrubber built on a true dual-port RAM creates a stale-write hazard: if the
user writes a fresh value to address X while the scrubber is mid-read of X, the scrubber's
later writeback would silently destroy the user's data. Cross-port collision detection is possible
but adds complexity, breaks portability across vendors that lack TDP support, and is verifiable
only with brittle cycle-aligned tests. At realistic scrub rates (one address per millisecond or
slower) the parallel-access "benefit" of TDP is wasted anyway. The single-port arbitrated design
is dramatically simpler, more portable, and just as fast in practice.

## Generics

| Name          | Type     | Default    | Description                                                  |
| :------------ | :------- | :--------- | :----------------------------------------------------------- |
| Depth_g       | positive | -          | Number of addresses                                          |
| Width_g       | positive | -          | User data width                                              |
| RdLatency_g   | positive | 1          | Read latency (passed to underlying _olo_ft_ram_sp_)          |
| RamStyle_g    | string   | "auto"     | Passed through                                               |
| RamBehavior_g | string   | "RBW"      | Passed through                                               |
| EccPipeline_g | natural  | 0          | Passed through                                               |
| ScrubPeriod_g | positive | 1024       | Cycles between consecutive scrub R-M-W operations. Larger = slower scrubbing, less port contention |
| ScrubMode_g   | string   | "ON_ERROR" | "ON_ERROR" = writeback only when SEC/DED detected; "ALWAYS" = unconditional writeback (cell refresh) |

## Interfaces

### User Port

| Name         | In/Out | Length                | Default | Description                                                  |
| :----------- | :----- | :-------------------- | ------- | :----------------------------------------------------------- |
| Clk          | in     | 1                     | -       | Clock                                                        |
| Rst          | in     | 1                     | -       | Synchronous reset                                            |
| Addr         | in     | _ceil(log2(Depth_g))_ | -       | Address                                                      |
| WrEna        | in     | 1                     | '0'     | Write enable                                                 |
| WrData       | in     | _Width_g_             | 0       | Write data                                                   |
| WrEccBitFlip | in     | 2                     | "00"    | ECC error injection (test/BIST). See [olo_ft_ram_tdp - Error Injection](./olo_ft_ram_tdp.md#error-injection). |
| RdData       | out    | _Width_g_             | N/A     | Read data (corrected if a single-bit error was detected)    |
| RdSecErr     | out    | 1                     | N/A     | Single error corrected flag (per read)                       |
| RdDedErr     | out    | 1                     | N/A     | Double error detected flag (per read)                        |

### Scrubber Arbitration

| Name          | In/Out | Length | Default | Description                                                  |
| :------------ | :----- | :----- | ------- | :----------------------------------------------------------- |
| Scrub_Stop    | in     | 1      | '0'     | Assert to halt the scrubber and claim the port               |
| Scrub_Stopped | out    | 1      | N/A     | '1' when scrubber has yielded the port. Safe to issue user accesses |

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
3. Issue any number of accesses with normal SP RAM semantics. Read data appears _RdLatency_g_ + _EccPipeline_g_ cycles after the address is sampled
4. Deassert _Scrub_Stop_ <= '0'
5. The scrubber resumes on the next clock cycle

### Architecture

```
                      ┌─────────────────┐
   User Addr/      ┌──┤                 │
   WrEna/WrData    │  │                 │
                MUX───►│  olo_ft_ram_sp │
   Scrubber FSM ──┘  │                 │
   (Read/Write)      │                 │
                     └────┬────────────┘
                          │
                          ▼
                   RdData / RdSecErr / RdDedErr
                   → routed to user always
```

The wrapper instantiates an _olo_ft_ram_sp_. A multiplexer selects between user signals and
scrubber-FSM signals based on the FSM state. While the scrubber is in active states (Read, Wait,
Decide, Write, Incr) the FSM drives the bus; while in Idle or Yielded the user signals pass
through.

### Scrubber FSM

The scrubber FSM has these states:

| State    | Action                                                                |
| :------- | :-------------------------------------------------------------------- |
| Idle     | Counts _ScrubPeriod_g_ cycles. If _Scrub_Stop_=1, transition to Yielded |
| Read     | Issues a read of the current scrub address                            |
| Wait     | Waits _RdLatency_g_+_EccPipeline_g_ cycles for the read result        |
| Decide   | Captures the decoded read data and error flags                        |
| Write    | Writes the captured (corrected) value back, conditional on _ScrubMode_g_ |
| Incr     | Advances the scrub address (wraps → pulse _Scrub_PassDone_)           |
| Yielded  | Holds while _Scrub_Stop_=1; user owns the port                        |

**Atomicity**: once the FSM enters Read state, the entire R-M-W sequence completes even if
_Scrub_Stop_ is asserted mid-cycle. The scrubber yields only between R-M-W operations. This
ensures the captured value is always written back to the same address it was read from, and
prevents stale-write hazards.

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
  _Scrub_Stopped_ = '0' are ignored (the scrubber owns the bus).
- _Scrub_PassDone_ is pulsed when the address counter wraps from _Depth_g_-1 back to 0,
  including the case where the user holds _Scrub_Stop_=1 for an extended period spanning multiple
  passes.
- The scrubber does not protect against double-bit errors (SECDED can detect but not correct).
  When the scrubber encounters a DED, it pulses _Scrub_DedErr_ and **leaves the memory contents
  unchanged** (no writeback) so the error remains detectable on subsequent reads.

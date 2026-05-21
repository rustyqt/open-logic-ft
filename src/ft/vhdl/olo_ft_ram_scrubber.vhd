---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Private opportunistic memory-scrubber FSM. Instantiated by ECC-protected RAM
-- wrappers (currently `olo_ft_ram_sdp` with `Scrub_g=true`); not intended for
-- end-user instantiation.
--
-- Operating principle: read each address in turn, observe the decoded ECC
-- flags, and (in ON_ERROR mode) write the corrected value back. The scrubber
-- never stalls the user: it issues its own read only on cycles where the user
-- holds `Rd_Ena = '0'`, and issues its writeback only on cycles where the user
-- holds `Wr_Ena = '0'`. When the user writes to the address currently being
-- scrubbed at any point between the scrubber's read and writeback, the sticky
-- `Collision` flag is set and the writeback is aborted -- user data is always
-- authoritative.
--
-- Sequence per address (T = read-issue cycle, L = TotalReadLatency_g):
--   T            : assert Scrub_Rd_Ena (only when User_Rd_PortBusy = '0' and Scrub_Enable = '1')
--   T .. T+L     : monitor User_Wr_Ena & (User_Wr_Addr = InFlightAddr) -> Collision
--   T+L          : capture (Ram_Rd_Data, Ram_Rd_EccSec, Ram_Rd_EccDed)
--   T+L          : if EccDed='1' or EccSec='0' or Collision='1' -> abort (no writeback)
--                  else move to WriteWait
--   T+L .. T+L+k : wait for (User_Wr_PortBusy='0'); each cycle still tracks collisions
--   T+L+k        : assert Scrub_Wr_Ena (only if Collision='0' and Scrub_Enable='1')
--   T+L+k+1      : increment ScrubAddr; pulse Scrub_PassDone on rollover
--
-- Port-busy vs. collision semantics:
-- `User_Wr_Ena` is used only for collision detection (does the user actually
-- modify the in-flight address?). The separate `User_*_PortBusy` inputs gate
-- when the scrubber is allowed to issue its own read/write. In a SDP setting
-- the two are identical; in single-port settings they differ (port is busy on
-- both user reads AND user writes, but only user writes can corrupt data).
--
-- Scrub_Enable:
-- External enable. `Scrub_Enable = '0'` gates `Scrub_Rd_Ena` and `Scrub_Wr_Ena`
-- low combinationally on the same cycle (no new requests can land on the bus)
-- and prevents the FSM from starting new operations. Any in-flight read is
-- allowed to complete its natural FSM cycle so the wrapper's `RdValid` masking
-- (via `Scrub_Rd_Valid`) stays correct; the writeback is simply suppressed.
-- The address counter `ScrubAddr` may advance by 1 if disabled mid-cycle (the
-- in-flight address finishes its pass). Use this to deterministically suspend
-- scrubbing during ECC error-injection tests.
--
-- Scrub_Rd_Valid:
-- Pulses on the cycle the scrubber's own read returns from the codec (cycle T+L,
-- i.e. when the FSM is in `Decide_s`). Aligned with `Scrub_EccSec` and
-- `Scrub_EccDed` so all three can be qualified together by `Scrub_Rd_Valid`.
-- Wrappers use it to mask the user-facing `Rd_Valid` so scrubber-owned read
-- cycles do not pulse it. No extra FFs in the scrubber.
--
-- The wrapping RAM is responsible for muxing user-vs-scrubber requests onto the
-- shared write and read ports, encoding the scrubber's `Scrub_Wr_Data` through
-- the ECC encoder, and ANDing `not Scrub_Rd_Valid` into the user-facing
-- `Rd_Valid` so scrubber-owned read cycles do not pulse it.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.olo_base_pkg_math.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_ram_scrubber is
    generic (
        Depth_g            : positive;
        Width_g            : positive;
        TotalReadLatency_g : positive
    );
    port (
        Clk              : in    std_logic;
        Rst              : in    std_logic;
        -- External enable. '0' gates new scrubber requests combinationally and prevents the FSM
        -- from starting new operations. In-flight reads complete naturally; writebacks are
        -- suppressed. See the description header for details.
        Scrub_Enable     : in    std_logic;
        -- Snoop user accesses (combinational). User_Wr_Ena is for collision
        -- detection only; User_*_PortBusy gate the scrubber's request issuance.
        User_Wr_Ena      : in    std_logic;
        User_Wr_Addr     : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        User_Wr_PortBusy : in    std_logic;
        User_Rd_PortBusy : in    std_logic;
        -- Decoded read return tapped from `olo_ft_ecc_decode.Out_*`
        Ram_Rd_Data      : in    std_logic_vector(Width_g - 1 downto 0);
        Ram_Rd_EccSec    : in    std_logic;
        Ram_Rd_EccDed    : in    std_logic;
        -- Scrubber-driven requests (combined with user requests in the wrapper)
        Scrub_Rd_Ena     : out   std_logic;
        Scrub_Rd_Addr    : out   std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Scrub_Wr_Ena     : out   std_logic;
        Scrub_Wr_Addr    : out   std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Scrub_Wr_Data    : out   std_logic_vector(Width_g - 1 downto 0);
        -- Status
        Scrub_Rd_Valid   : out   std_logic;
        Scrub_EccSec     : out   std_logic;
        Scrub_EccDed     : out   std_logic;
        Scrub_PassDone   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ram_scrubber is

    constant AddrWidth_c : positive := log2ceil(Depth_g);

    -- FSM stays in `Idle_s` until the user yields the read port for a single cycle;
    -- the read result travels back through the codec over `TotalReadLatency_g` cycles
    -- and is captured in `Decide_s`; the writeback (if any) waits for an idle write
    -- port in `WriteWait_s`.
    type State_t is (Idle_s, ReadWait_s, Decide_s, WriteWait_s, Incr_s);

    signal State        : State_t;
    signal ScrubAddr    : unsigned(AddrWidth_c - 1 downto 0);
    signal InFlightAddr : unsigned(AddrWidth_c - 1 downto 0);
    signal WaitCnt      : unsigned(log2ceil(TotalReadLatency_g + 1) - 1 downto 0);
    signal Collision    : std_logic;
    signal CapturedData : std_logic_vector(Width_g - 1 downto 0);

    -- Registered pass-done pulse: drives the output port from a flip-flop instead of a
    -- combinational decode of the FSM state. One-cycle pulse, delayed by one cycle relative
    -- to the internal (State=Incr_s and ScrubAddr=Depth_g-1) event.
    signal Scrub_PassDone_q : std_logic := '0';

    -- Combinational request flags. User priority is enforced by gating on User_*_PortBusy so
    -- the wrapper's mux can simply combine these with the user signals.
    signal IssueRead    : std_logic;
    signal IssueWrite   : std_logic;

begin

    IssueRead  <= '1' when (State = Idle_s)
                        and (User_Rd_PortBusy = '0')
                        and (Scrub_Enable = '1') else '0';
    IssueWrite <= '1' when (State = WriteWait_s)
                        and (User_Wr_PortBusy = '0')
                        and (Collision = '0')
                        and (Scrub_Enable = '1') else '0';

    p_fsm : process (Clk) is
    begin
        if rising_edge(Clk) then

            -- Snoop user writes to the in-flight address across the entire read-decode-writeback
            -- window. Sticky: once set, stays set until the address is retired in Incr_s. This
            -- guarantees the writeback either lands before any user write or is aborted.
            if (State = ReadWait_s or State = WriteWait_s) and
               (User_Wr_Ena = '1') and
               (unsigned(User_Wr_Addr) = InFlightAddr) then
                Collision <= '1';
            end if;

            case State is

                when Idle_s =>
                    if IssueRead = '1' then
                        InFlightAddr <= ScrubAddr;
                        Collision    <= '0';
                        -- WaitCnt starts at 1 (not 0). The transition Idle->ReadWait already
                        -- consumed cycle T->T+1, so ReadWait only needs to span L-1 more cycles
                        -- to land in Decide_s on cycle T+L (the same cycle Ram_RdValid pulses).
                        WaitCnt      <= to_unsigned(1, WaitCnt'length);
                        if TotalReadLatency_g = 1 then
                            -- L=1: data is back on T+1, skip ReadWait entirely.
                            State <= Decide_s;
                        else
                            State <= ReadWait_s;
                        end if;
                    end if;

                when ReadWait_s =>
                    if WaitCnt = TotalReadLatency_g - 1 then
                        State <= Decide_s;
                    else
                        WaitCnt <= WaitCnt + 1;
                    end if;

                when Decide_s =>
                    -- ON_ERROR: only write back when SEC was corrected. DED is unreliable;
                    -- writing it back would silently commit a "valid" codeword over an
                    -- otherwise-detectable double-bit error. Collision means a user write
                    -- already arrived for this address -- their data is authoritative.
                    -- Scrub_Enable='0' also skips the writeback so the FSM unwinds without
                    -- needing the wrapper to wait for a separate drain.
                    if Ram_Rd_EccDed = '0' and Ram_Rd_EccSec = '1' and Collision = '0'
                       and Scrub_Enable = '1' then
                        CapturedData <= Ram_Rd_Data;
                        State        <= WriteWait_s;
                    else
                        State <= Incr_s;
                    end if;

                when WriteWait_s =>
                    -- Scrub_Enable='0' is an additional exit condition so the FSM doesn't hang
                    -- (IssueWrite is gated to '0' forever while disabled).
                    if Collision = '1' or IssueWrite = '1' or Scrub_Enable = '0' then
                        State <= Incr_s;
                    end if;

                when Incr_s =>
                    if ScrubAddr = Depth_g - 1 then
                        ScrubAddr <= (others => '0');
                    else
                        ScrubAddr <= ScrubAddr + 1;
                    end if;
                    State <= Idle_s;

            end case;

            if Rst = '1' then
                State        <= Idle_s;
                ScrubAddr    <= (others => '0');
                InFlightAddr <= (others => '0');
                Collision    <= '0';
                WaitCnt      <= (others => '0');
            end if;
        end if;
    end process;

    -- Status pulses are driven combinationally so they appear on the same cycle as the event
    -- that produced them (vs. an extra register delay). PassDone fires while the FSM is in
    -- Incr_s with ScrubAddr about to wrap; Sec/Ded fire while in Decide_s.
    Scrub_Rd_Ena   <= IssueRead;
    Scrub_Rd_Addr  <= std_logic_vector(ScrubAddr);
    Scrub_Wr_Ena   <= IssueWrite;
    Scrub_Wr_Addr  <= std_logic_vector(InFlightAddr);
    Scrub_Wr_Data  <= CapturedData;
    -- Pulses on the cycle the scrubber's own read returns from the codec (aligned to the inner
    -- RAM/decoder's RdValid AND to Scrub_EccSec/Scrub_EccDed). The wrapper ANDs `not
    -- Scrub_Rd_Valid` into the user-facing RdValid.
    Scrub_Rd_Valid <= '1' when State = Decide_s else '0';
    Scrub_EccSec   <= Ram_Rd_EccSec when State = Decide_s else '0';
    Scrub_EccDed   <= Ram_Rd_EccDed when State = Decide_s else '0';
    Scrub_PassDone <= Scrub_PassDone_q;

    -- Register Scrub_PassDone so the output sits in a flip-flop, not in a combinational
    -- decode of the FSM state. Fires one cycle after the FSM commits the address wrap in
    -- Incr_s; pulse is still one cycle wide.
    p_pass_done : process (Clk) is
    begin
        if rising_edge(Clk) then
            if (State = Incr_s) and (ScrubAddr = Depth_g - 1) then
                Scrub_PassDone_q <= '1';
            else
                Scrub_PassDone_q <= '0';
            end if;
            if Rst = '1' then
                Scrub_PassDone_q <= '0';
            end if;
        end if;
    end process;

end architecture;

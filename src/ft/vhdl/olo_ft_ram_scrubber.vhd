---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Private opportunistic memory-scrubber FSM. Instantiated by ECC-protected RAM
-- wrappers (`olo_ft_ram_sp_scrub`, `olo_ft_ram_sdp_scrub`); not intended for
-- end-user instantiation.
--
-- Operating principle: read each address in turn, observe the decoded ECC
-- flags, and write the corrected value back when a single-bit error is
-- detected. The scrubber never stalls the user: it issues its own read only on
-- cycles where the user holds `Rd_Ena = '0'`, and issues its writeback only on
-- cycles where the user holds `Wr_Ena = '0'`. When the user writes to the
-- address currently being scrubbed at any point between the scrubber's read
-- and writeback, the sticky `Collision` flag is set and the writeback is
-- aborted; user data is always authoritative.
--
-- Sequence per address (T = read-issue cycle, L = TotalReadLatency_g):
--   T            : assert Scrub_Rd_Ena (only when User_Rd_PortBusy = '0' and Scrub_Enable = '1')
--   T .. T+L     : monitor User_Wr_Ena & (User_Wr_Addr = InFlightAddr) -> Collision
--   T+L          : capture (Ram_Rd_Data, Ram_Rd_EccSec, Ram_Rd_EccDed) in Decide_s;
--                  Scrub_Rd_Valid + Scrub_EccSec/Ded fire combinationally on this cycle
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
-- Scrub_Enable = '0' gates Scrub_Rd_Ena and Scrub_Wr_Ena low combinationally
-- and prevents the FSM from starting new operations. Any in-flight read is
-- allowed to complete its FSM cycle so the wrapper's RdValid masking (via
-- Scrub_Rd_Valid) stays correct; the writeback is suppressed. ScrubAddr may
-- advance by 1 if disabled mid-cycle (the in-flight address finishes its
-- pass). Use this to deterministically suspend scrubbing during ECC error-
-- injection tests.
--
-- The wrapping RAM is responsible for muxing user-vs-scrubber requests onto
-- the shared write and read ports, encoding `Scrub_Wr_Data` through the ECC
-- encoder, and ANDing `not Scrub_Rd_Valid` into the user-facing `Rd_Valid` so
-- scrubber-owned read cycles do not pulse it.

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
        -- Clock and Reset
        Clk              : in    std_logic;
        Rst              : in    std_logic;
        -- Snoop user accesses
        User_Wr_Ena      : in    std_logic;
        User_Wr_Addr     : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        User_Wr_PortBusy : in    std_logic;
        User_Rd_PortBusy : in    std_logic;
        -- Decoded read return
        Ram_Rd_Data      : in    std_logic_vector(Width_g - 1 downto 0);
        Ram_Rd_EccSec    : in    std_logic;
        Ram_Rd_EccDed    : in    std_logic;
        -- Scrubber-driven requests
        Scrub_Rd_Ena     : out   std_logic;
        Scrub_Rd_Addr    : out   std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Scrub_Wr_Ena     : out   std_logic;
        Scrub_Wr_Addr    : out   std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Scrub_Wr_Data    : out   std_logic_vector(Width_g - 1 downto 0);
        -- Scrubber control
        Scrub_Enable     : in    std_logic;
        -- Scrubber Status
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

    type ScrubFsm_t is (Idle_s, ReadWait_s, Decide_s, WriteWait_s, Incr_s);

    type TwoProcess_r is record
        Fsm          : ScrubFsm_t;
        ScrubAddr    : unsigned(AddrWidth_c - 1 downto 0);
        InFlightAddr : unsigned(AddrWidth_c - 1 downto 0);
        WaitCnt      : unsigned(log2ceil(TotalReadLatency_g + 1) - 1 downto 0);
        Collision    : std_logic;
        CapturedData : std_logic_vector(Width_g - 1 downto 0);
        PassDone     : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

begin

    -- *** Combinatorial Process ***
    p_comb : process (all) is
        variable v            : TwoProcess_r;
        variable IssueRead_v  : std_logic;
        variable IssueWrite_v : std_logic;
    begin
        -- Hold variables stable
        v := r;

        if r.Fsm = Idle_s and User_Rd_PortBusy = '0' and Scrub_Enable = '1' then
            IssueRead_v := '1';
        else
            IssueRead_v := '0';
        end if;

        if r.Fsm = WriteWait_s and User_Wr_PortBusy = '0' and r.Collision = '0' and Scrub_Enable = '1' then
            IssueWrite_v := '1';
        else
            IssueWrite_v := '0';
        end if;

        -- One-cycle pulse: cleared every comb pass, set in Incr_s on address wrap.
        v.PassDone := '0';

        -- Sticky collision: stays set until the address is retired in Incr_s, so the writeback
        -- either lands before any user write or is aborted.
        if (r.Fsm = ReadWait_s or r.Fsm = WriteWait_s) and
           (User_Wr_Ena = '1') and
           (unsigned(User_Wr_Addr) = r.InFlightAddr) then
            v.Collision := '1';
        end if;

        case r.Fsm is

            when Idle_s =>
                if IssueRead_v = '1' then
                    v.InFlightAddr := r.ScrubAddr;
                    v.Collision    := '0';
                    -- WaitCnt starts at 1: the Idle->ReadWait transition already consumed cycle
                    -- T->T+1, so ReadWait only needs to span L-1 more cycles.
                    v.WaitCnt      := to_unsigned(1, v.WaitCnt'length);
                    if TotalReadLatency_g = 1 then
                        -- L=1: data is back on T+1, skip ReadWait entirely.
                        v.Fsm := Decide_s;
                    else
                        v.Fsm := ReadWait_s;
                    end if;
                end if;

            when ReadWait_s =>
                if r.WaitCnt = TotalReadLatency_g - 1 then
                    v.Fsm := Decide_s;
                else
                    v.WaitCnt := r.WaitCnt + 1;
                end if;

            when Decide_s =>
                -- Only write back when SEC was corrected. DED is unreliable; writing it back
                -- would silently commit a "valid" codeword over an otherwise-detectable double-
                -- bit error. Collision means the user already wrote this address; their data
                -- is authoritative. Scrub_Enable='0' also skips the writeback so the FSM
                -- unwinds without needing the wrapper to drain.
                if Ram_Rd_EccDed = '0' and Ram_Rd_EccSec = '1' and r.Collision = '0'
                   and Scrub_Enable = '1' then
                    v.CapturedData := Ram_Rd_Data;
                    v.Fsm          := WriteWait_s;
                else
                    v.Fsm := Incr_s;
                end if;

            when WriteWait_s =>
                -- Scrub_Enable='0' exits as well so the FSM does not hang while disabled.
                if r.Collision = '1' or IssueWrite_v = '1' or Scrub_Enable = '0' then
                    v.Fsm := Incr_s;
                end if;

            when Incr_s =>
                if r.ScrubAddr = Depth_g - 1 then
                    v.ScrubAddr := (others => '0');
                    v.PassDone  := '1';
                else
                    v.ScrubAddr := r.ScrubAddr + 1;
                end if;
                v.Fsm := Idle_s;

            -- coverage off
            when others => v.Fsm := Idle_s; -- unreachable code, safe recovery
            -- coverage on

        end case;

        Scrub_Rd_Ena  <= IssueRead_v;
        Scrub_Rd_Addr <= std_logic_vector(r.ScrubAddr);
        Scrub_Wr_Ena  <= IssueWrite_v;
        Scrub_Wr_Addr <= std_logic_vector(r.InFlightAddr);
        Scrub_Wr_Data <= r.CapturedData;

        -- Status pulses fire combinationally on the Decide_s cycle so they appear on the same
        -- cycle as the codec's read return.
        if r.Fsm = Decide_s then
            Scrub_Rd_Valid <= '1';
            Scrub_EccSec   <= Ram_Rd_EccSec;
            Scrub_EccDed   <= Ram_Rd_EccDed;
        else
            Scrub_Rd_Valid <= '0';
            Scrub_EccSec   <= '0';
            Scrub_EccDed   <= '0';
        end if;

        Scrub_PassDone <= r.PassDone;

        r_next <= v;

    end process;

    -- *** Sequential Process ***
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;

            if Rst = '1' then
                r.Fsm          <= Idle_s;
                r.ScrubAddr    <= (others => '0');
                r.InFlightAddr <= (others => '0');
                r.WaitCnt      <= (others => '0');
                r.Collision    <= '0';
                r.PassDone     <= '0';
                -- CapturedData is a pipeline register, not state -> not reset.
            end if;
        end if;
    end process;

end architecture;

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
-- Operating principle: read each address in turn; L cycles later observe the
-- decoded ECC flags in Decide_s, fire the writeback in the same cycle when a
-- single-bit error was corrected, and advance ScrubAddr. The scrubber never
-- stalls the user: it issues bus requests only while Scrub_Inhibit='0' (the
-- wrapper combines user-port-busy and external Scrub_Enable into this signal).
-- An inhibit during the read-decode window aborts the in-flight operation
-- back to Idle_s without advancing the address counter, so the scrubber
-- retries the same address on the next idle slot. User data is always
-- authoritative.
--
-- Sequence per address (T = read-issue cycle, L = TotalReadLatency_g):
--   T        : assert Scrub_Rd_Ena (only when Scrub_Inhibit='0')
--   T .. T+L : if Scrub_Inhibit='1' on any cycle, abort to Idle_s; ValidPipe keeps
--              shifting so Scrub_Rd_Valid still pulses on the codec return cycle
--   T+L      : in Decide_s, observe Ram_Rd_Data and ECC flags; if EccSec='1' and
--              EccDed='0' assert Scrub_Wr_Ena (writeback fires this cycle with
--              Scrub_Wr_Data = Ram_Rd_Data through the wrapper's encoder input);
--              advance ScrubAddr; pulse Scrub_PassDone on rollover; go to Idle_s.
--
-- Scrub_Rd_Valid is driven from a length-L shift register tracking every
-- Scrub_Rd_Ena pulse, so it still pulses on the codec return cycle when the FSM
-- aborted in the meantime -- the wrapper uses it to mask the user-facing
-- Rd_Valid. Scrub_Rd_EccSec / Scrub_Rd_EccDed are pass-throughs of the codec
-- output; the consumer must qualify them with Scrub_Rd_Valid.
--
-- Scrub_Inhibit is the wrapper's combined "do not act" signal. Set when the
-- user is accessing the port OR when the external Scrub_Enable is deasserted.
-- Both cases gate new bus issuance and abort any in-flight operation. After
-- Scrub_Inhibit returns low, scrubbing resumes from the same address.

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
        Clk             : in    std_logic;
        Rst             : in    std_logic;
        -- Decoded RAM Read
        Ram_Rd_Data     : in    std_logic_vector(Width_g - 1 downto 0);
        Ram_Rd_EccSec   : in    std_logic;
        Ram_Rd_EccDed   : in    std_logic;
        -- Scrub Control
        Scrub_Inhibit   : in    std_logic;
        Scrub_Rd_Ena    : out   std_logic;
        Scrub_Wr_Ena    : out   std_logic;
        Scrub_Addr      : out   std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Scrub_Wr_Data   : out   std_logic_vector(Width_g - 1 downto 0);
        -- Scrub Status
        Scrub_Rd_Valid  : out   std_logic;
        Scrub_Rd_EccSec : out   std_logic;
        Scrub_Rd_EccDed : out   std_logic;
        Scrub_PassDone  : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ram_scrubber is

    constant AddrWidth_c : positive := log2ceil(Depth_g);

    type ScrubFsm_t is (Idle_s, ReadWait_s, Decide_s);

    type TwoProcess_r is record
        Fsm       : ScrubFsm_t;
        ScrubAddr : unsigned(AddrWidth_c - 1 downto 0);
        WaitCnt   : unsigned(log2ceil(TotalReadLatency_g + 1) - 1 downto 0);
        ValidPipe : std_logic_vector(TotalReadLatency_g - 1 downto 0);
        PassDone  : std_logic;
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

        IssueRead_v  := '0';
        IssueWrite_v := '0';
        v.PassDone   := '0';

        case r.Fsm is

            when Idle_s =>
                if Scrub_Inhibit = '0' then
                    IssueRead_v := '1';
                    -- WaitCnt starts at 1: the Idle->ReadWait transition already
                    -- consumed cycle T->T+1, so ReadWait only needs to span L-1 more
                    -- cycles.
                    v.WaitCnt := to_unsigned(1, v.WaitCnt'length);
                    if TotalReadLatency_g = 1 then
                        -- L=1: data is back on T+1, skip ReadWait entirely.
                        v.Fsm := Decide_s;
                    else
                        v.Fsm := ReadWait_s;
                    end if;
                end if;

            when ReadWait_s =>
                if Scrub_Inhibit = '1' then
                    v.Fsm := Idle_s;
                elsif r.WaitCnt = TotalReadLatency_g - 1 then
                    v.Fsm := Decide_s;
                else
                    v.WaitCnt := r.WaitCnt + 1;
                end if;

            when Decide_s =>
                if Scrub_Inhibit = '1' then
                    v.Fsm := Idle_s;
                else
                    -- Write back SEC only; DED is unreliable and not corrected.
                    if Ram_Rd_EccDed = '0' and Ram_Rd_EccSec = '1' then
                        IssueWrite_v := '1';
                    end if;
                    if r.ScrubAddr = Depth_g - 1 then
                        v.ScrubAddr := (others => '0');
                        v.PassDone  := '1';
                    else
                        v.ScrubAddr := r.ScrubAddr + 1;
                    end if;
                    v.Fsm := Idle_s;
                end if;

            -- coverage off
            when others => v.Fsm := Idle_s; -- unreachable code, safe recovery
            -- coverage on

        end case;

        -- Shift IssueRead_v through L stages. Decoupled from FSM state so Scrub_Rd_Valid
        -- still pulses on the codec return cycle when the FSM aborted mid-flight.
        v.ValidPipe(0) := IssueRead_v;

        for i in 1 to TotalReadLatency_g - 1 loop
            v.ValidPipe(i) := r.ValidPipe(i - 1);
        end loop;

        Scrub_Rd_Ena    <= IssueRead_v;
        Scrub_Wr_Ena    <= IssueWrite_v;
        Scrub_Addr      <= std_logic_vector(r.ScrubAddr);
        Scrub_Wr_Data   <= Ram_Rd_Data;
        Scrub_Rd_Valid  <= r.ValidPipe(TotalReadLatency_g - 1);
        Scrub_Rd_EccSec <= Ram_Rd_EccSec;
        Scrub_Rd_EccDed <= Ram_Rd_EccDed;
        Scrub_PassDone  <= r.PassDone;

        r_next <= v;

    end process;

    -- *** Sequential Process ***
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;

            if Rst = '1' then
                r.Fsm       <= Idle_s;
                r.ScrubAddr <= (others => '0');
                r.WaitCnt   <= (others => '0');
                r.PassDone  <= '0';
                -- Reset so Scrub_Rd_Valid does not pulse on a random startup pattern.
                r.ValidPipe <= (others => '0');
            end if;
        end if;
    end process;

end architecture;

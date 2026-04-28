---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected simple dual port RAM with built-in memory scrubber. Wraps
-- olo_ft_ram_sdp and adds a scrubber FSM that periodically reads each address,
-- triggers ECC correction, and writes the corrected value back. This prevents
-- single-event upsets (SEUs) from accumulating into uncorrectable double-bit
-- errors over time.
--
-- The scrubber and the user share both ports through multiplexers. The user
-- explicitly halts the scrubber via the Scrub_Stop input and waits for
-- Scrub_Stopped to acknowledge. While Scrub_Stopped='1', the user can issue
-- accesses with normal SDP RAM semantics. The scrubber resumes when Scrub_Stop
-- is deasserted.
--
-- Note: IsAsync_g is not supported because the scrubber FSM performs a
-- synchronous read-wait-decide-write sequence that requires both ports on
-- the same clock.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_ram_sdp_scrub.md
--
-- Note: The link points to the documentation of the latest release. If you
--       use an older version, the documentation might not match the code.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.olo_base_pkg_math.all;
    use work.olo_base_pkg_string.all;
    use work.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_ram_sdp_scrub is
    generic (
        Depth_g       : positive;
        Width_g       : positive;
        RdLatency_g   : positive := 1;
        RamStyle_g    : string   := "auto";
        RamBehavior_g : string   := "RBW";
        EccPipeline_g : natural  := 0;
        ScrubPeriod_g : positive := 1024;
        ScrubMode_g   : string   := "ON_ERROR"
    );
    port (
        -- Control
        Clk            : in    std_logic;
        Rst            : in    std_logic;
        -- User write interface (matches olo_ft_ram_sdp)
        Wr_Addr        : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Wr_Ena         : in    std_logic                               := '0';
        Wr_Data        : in    std_logic_vector(Width_g - 1 downto 0)  := (others => '0');
        Wr_EccBitFlip  : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        -- User read interface (matches olo_ft_ram_sdp)
        Rd_Addr        : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Rd_Ena         : in    std_logic                               := '0';
        Rd_Data        : out   std_logic_vector(Width_g - 1 downto 0);
        Rd_EccSec      : out   std_logic;
        Rd_EccDed      : out   std_logic;
        -- Scrubber arbitration
        Scrub_Stop     : in    std_logic                               := '0';
        Scrub_Stopped  : out   std_logic;
        -- Scrubber status
        Scrub_Active   : out   std_logic;
        Scrub_Addr     : out   std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Scrub_EccSec   : out   std_logic;
        Scrub_EccDed   : out   std_logic;
        Scrub_PassDone : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ram_sdp_scrub is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant TotalReadLatency_c : positive := RdLatency_g + EccPipeline_g;
    constant AddrWidth_c        : positive := log2ceil(Depth_g);
    constant ModeAlways_c       : boolean  := compareNoCase(ScrubMode_g, "ALWAYS");

    -----------------------------------------------------------------------------------------------
    -- Types
    -----------------------------------------------------------------------------------------------
    type State_t is (Idle_s, Read_s, Wait_s, Decide_s, Write_s, Incr_s, Yielded_s);

    -----------------------------------------------------------------------------------------------
    -- Signals
    -----------------------------------------------------------------------------------------------
    signal State        : State_t;
    signal ScrubAddr_v  : unsigned(AddrWidth_c - 1 downto 0);
    signal PeriodCnt    : unsigned(log2ceil(ScrubPeriod_g + 1) - 1 downto 0);
    signal WaitCnt      : unsigned(log2ceil(TotalReadLatency_c + 1) - 1 downto 0);
    signal CapturedData : std_logic_vector(Width_g - 1 downto 0);
    signal CapturedSec  : std_logic;
    signal CapturedDed  : std_logic;

    -- Multiplexed RAM signals (write port)
    signal Ram_Wr_Addr : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal Ram_Wr_Ena  : std_logic;
    signal Ram_Wr_Data : std_logic_vector(Width_g - 1 downto 0);
    signal Ram_Wr_Flip : std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0);

    -- Multiplexed RAM signals (read port)
    signal Ram_Rd_Addr : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal Ram_Rd_Ena  : std_logic;
    signal Ram_Rd_Data : std_logic_vector(Width_g - 1 downto 0);
    signal Ram_Rd_Sec  : std_logic;
    signal Ram_Rd_Ded  : std_logic;

    -- Helper
    signal ScrubMaster   : std_logic;
    signal ScrubWriteReq : std_logic;

begin

    -----------------------------------------------------------------------------------------------
    -- Assertions
    -----------------------------------------------------------------------------------------------
    assert compareNoCase(ScrubMode_g, "ON_ERROR") or compareNoCase(ScrubMode_g, "ALWAYS")
        report "olo_ft_ram_sdp_scrub: ScrubMode_g must be ON_ERROR or ALWAYS. Got: " & ScrubMode_g
        severity error;

    -----------------------------------------------------------------------------------------------
    -- Scrubber FSM
    -----------------------------------------------------------------------------------------------
    p_fsm : process (Clk) is
    begin
        if rising_edge(Clk) then
            -- Default pulses
            Scrub_EccSec   <= '0';
            Scrub_EccDed   <= '0';
            Scrub_PassDone <= '0';

            case State is

                when Idle_s =>
                    if Scrub_Stop = '1' then
                        State <= Yielded_s;
                    elsif PeriodCnt = ScrubPeriod_g - 1 then
                        PeriodCnt <= (others => '0');
                        State     <= Read_s;
                    else
                        PeriodCnt <= PeriodCnt + 1;
                    end if;

                when Read_s =>
                    -- This is the cycle where the scrubber issues the read
                    -- (Ram_Rd_Addr/Ram_Rd_Ena are driven combinationally below)
                    WaitCnt <= (others => '0');
                    State   <= Wait_s;

                when Wait_s =>
                    if WaitCnt = TotalReadLatency_c - 1 then
                        State <= Decide_s;
                    else
                        WaitCnt <= WaitCnt + 1;
                    end if;

                when Decide_s =>
                    -- Capture decoded read data and error flags
                    CapturedData <= Ram_Rd_Data;
                    CapturedSec  <= Ram_Rd_Sec;
                    CapturedDed  <= Ram_Rd_Ded;
                    -- Pulse scrubber error flags
                    Scrub_EccSec <= Ram_Rd_Sec;
                    Scrub_EccDed <= Ram_Rd_Ded;
                    State        <= Write_s;

                when Write_s =>
                    -- Combinational write driven below
                    State <= Incr_s;

                when Incr_s =>
                    if ScrubAddr_v = Depth_g - 1 then
                        ScrubAddr_v    <= (others => '0');
                        Scrub_PassDone <= '1';
                    else
                        ScrubAddr_v <= ScrubAddr_v + 1;
                    end if;
                    -- After completing R-M-W, honor user stop request
                    if Scrub_Stop = '1' then
                        State <= Yielded_s;
                    else
                        State <= Idle_s;
                    end if;

                when Yielded_s =>
                    if Scrub_Stop = '0' then
                        State <= Idle_s;
                    end if;

            end case;

            -- Reset
            if Rst = '1' then
                State        <= Idle_s;
                ScrubAddr_v  <= (others => '0');
                PeriodCnt    <= (others => '0');
                WaitCnt      <= (others => '0');
                CapturedSec  <= '0';
                CapturedDed  <= '0';
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Combinational status outputs
    -----------------------------------------------------------------------------------------------
    Scrub_Stopped <= '1' when (State = Idle_s) or (State = Yielded_s) else '0';
    Scrub_Active  <= '0' when (State = Idle_s) or (State = Yielded_s) else '1';
    Scrub_Addr    <= std_logic_vector(ScrubAddr_v);

    -----------------------------------------------------------------------------------------------
    -- Bus arbitration: scrubber drives the RAM during all active states
    -----------------------------------------------------------------------------------------------
    ScrubMaster <= '0' when (State = Idle_s) or (State = Yielded_s) else '1';

    -- Scrubber wants to write in Write_s
    -- Never write on DedErr: the decoded data is unreliable (SECDED can't correct double-bit
    -- errors), and writing it back would silently corrupt memory with a "valid" codeword over
    -- a previously-detectable double-bit error.
    ScrubWriteReq <= '1' when State = Write_s and CapturedDed = '0' and
                              (ModeAlways_c or CapturedSec = '1')
                     else '0';

    -- Write port mux
    Ram_Wr_Addr <= std_logic_vector(ScrubAddr_v) when ScrubMaster = '1' else Wr_Addr;
    Ram_Wr_Ena  <= ScrubWriteReq                 when ScrubMaster = '1' else Wr_Ena;
    Ram_Wr_Data <= CapturedData                  when ScrubMaster = '1' else Wr_Data;
    Ram_Wr_Flip <= (Ram_Wr_Flip'range => '0')    when ScrubMaster = '1' else Wr_EccBitFlip;

    -- Read port mux
    Ram_Rd_Addr <= std_logic_vector(ScrubAddr_v) when ScrubMaster = '1' else Rd_Addr;
    Ram_Rd_Ena  <= '1'                           when ScrubMaster = '1' else Rd_Ena;

    -----------------------------------------------------------------------------------------------
    -- Internal FT SDP RAM
    -----------------------------------------------------------------------------------------------
    i_ram : entity work.olo_ft_ram_sdp
        generic map (
            Depth_g       => Depth_g,
            Width_g       => Width_g,
            IsAsync_g     => false,
            RdLatency_g   => RdLatency_g,
            RamStyle_g    => RamStyle_g,
            RamBehavior_g => RamBehavior_g,
            EccPipeline_g => EccPipeline_g
        )
        port map (
            Clk           => Clk,
            Wr_Addr       => Ram_Wr_Addr,
            Wr_Ena        => Ram_Wr_Ena,
            Wr_Data       => Ram_Wr_Data,
            Wr_EccBitFlip => Ram_Wr_Flip,
            Rd_Clk        => '0',
            Rd_Addr       => Ram_Rd_Addr,
            Rd_Ena        => Ram_Rd_Ena,
            Rd_Data       => Ram_Rd_Data,
            Rd_EccSec     => Ram_Rd_Sec,
            Rd_EccDed     => Ram_Rd_Ded
        );

    -----------------------------------------------------------------------------------------------
    -- User read outputs
    -- Pass through directly. The user is responsible for tracking RdLatency_g+EccPipeline_g
    -- after issuing a read, exactly like a normal olo_ft_ram_sdp.
    -----------------------------------------------------------------------------------------------
    Rd_Data   <= Ram_Rd_Data;
    Rd_EccSec <= Ram_Rd_Sec;
    Rd_EccDed <= Ram_Rd_Ded;

end architecture;

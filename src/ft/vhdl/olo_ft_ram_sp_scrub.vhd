---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected single port RAM with built-in memory scrubber. Wraps
-- olo_ft_ram_sp and adds a scrubber FSM that periodically reads each address,
-- triggers ECC correction, and writes the corrected value back. This prevents
-- single-event upsets (SEUs) from accumulating into uncorrectable double-bit
-- errors over time.
--
-- The scrubber and the user share a single port through a multiplexer. The
-- user explicitly halts the scrubber via the Scrub_Stop input and waits for
-- Scrub_Stopped to acknowledge. While Scrub_Stopped='1', the user can issue
-- accesses with normal SP RAM semantics. The scrubber resumes when Scrub_Stop
-- is deasserted.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_ram_sp_scrub.md
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
entity olo_ft_ram_sp_scrub is
    generic (
        Depth_g          : positive;
        Width_g          : positive;
        RamRdLatency_g   : positive             := 1;
        RamStyle_g       : string               := "auto";
        RamBehavior_g    : string               := "RBW";
        EccPipeline_g    : natural range 0 to 2 := 0;
        ScrubPeriod_g    : positive             := 1024;
        ScrubMode_g      : string               := "ON_ERROR"
    );
    port (
        -- Control
        Clk            : in    std_logic;
        Rst            : in    std_logic;
        -- User interface (matches olo_ft_ram_sp)
        Addr           : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        WrEna          : in    std_logic                                                := '0';
        WrData         : in    std_logic_vector(Width_g - 1 downto 0)                   := (others => '0');
        ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        ErrInj_Valid   : in    std_logic                                                := '0';
        RdData         : out   std_logic_vector(Width_g - 1 downto 0);
        RdValid        : out   std_logic;
        RdEccSec       : out   std_logic;
        RdEccDed       : out   std_logic;
        -- Scrubber arbitration
        Scrub_Stop     : in    std_logic                                                := '0';
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
architecture rtl of olo_ft_ram_sp_scrub is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant TotalReadLatency_c : positive := RamRdLatency_g + EccPipeline_g;
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
    signal ScrubAddr    : unsigned(AddrWidth_c - 1 downto 0);
    signal PeriodCnt    : unsigned(log2ceil(ScrubPeriod_g + 1) - 1 downto 0);
    signal WaitCnt      : unsigned(log2ceil(TotalReadLatency_c + 1) - 1 downto 0);
    signal CapturedData : std_logic_vector(Width_g - 1 downto 0);
    signal CapturedSec  : std_logic;
    signal CapturedDed  : std_logic;

    -- Multiplexed RAM signals
    signal Ram_Addr       : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal Ram_WrEna      : std_logic;
    signal Ram_WrData     : std_logic_vector(Width_g - 1 downto 0);
    signal Ram_ErrInjFlip : std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0);
    signal Ram_ErrInjVld  : std_logic;
    signal Ram_RdData     : std_logic_vector(Width_g - 1 downto 0);
    signal Ram_RdValid    : std_logic;
    signal Ram_RdSec      : std_logic;
    signal Ram_RdDed      : std_logic;

    -- User-facing RdValid pipeline (masks out scrubber cycles)
    signal UserRdValidPipe : std_logic_vector(1 to TotalReadLatency_c) := (others => '0');

    -- Helper
    signal ScrubMaster   : std_logic;
    signal ScrubWriteReq : std_logic;

begin

    -----------------------------------------------------------------------------------------------
    -- Assertions
    -----------------------------------------------------------------------------------------------
    assert compareNoCase(ScrubMode_g, "ON_ERROR") or compareNoCase(ScrubMode_g, "ALWAYS")
        report "olo_ft_ram_sp_scrub: ScrubMode_g must be ON_ERROR or ALWAYS. Got: " & ScrubMode_g
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
                    -- (Ram_Addr/Ram_WrEna are driven combinationally below)
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
                    CapturedData <= Ram_RdData;
                    CapturedSec  <= Ram_RdSec;
                    CapturedDed  <= Ram_RdDed;
                    -- Pulse scrubber error flags
                    Scrub_EccSec <= Ram_RdSec;
                    Scrub_EccDed <= Ram_RdDed;
                    State        <= Write_s;

                when Write_s =>
                    -- Combinational write driven below
                    State <= Incr_s;

                when Incr_s =>
                    if ScrubAddr = Depth_g - 1 then
                        ScrubAddr      <= (others => '0');
                        Scrub_PassDone <= '1';
                    else
                        ScrubAddr <= ScrubAddr + 1;
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
                State       <= Idle_s;
                ScrubAddr   <= (others => '0');
                PeriodCnt   <= (others => '0');
                WaitCnt     <= (others => '0');
                CapturedSec <= '0';
                CapturedDed <= '0';
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Combinational status outputs
    -----------------------------------------------------------------------------------------------
    Scrub_Stopped <= '1' when (State = Idle_s) or (State = Yielded_s) else '0';
    Scrub_Active  <= '0' when (State = Idle_s) or (State = Yielded_s) else '1';
    Scrub_Addr    <= std_logic_vector(ScrubAddr);

    -----------------------------------------------------------------------------------------------
    -- Bus arbitration: scrubber drives the RAM during all active states
    -----------------------------------------------------------------------------------------------
    ScrubMaster <= '0' when (State = Idle_s) or (State = Yielded_s) else '1';

    -- Scrubber wants to write in Write_s
    -- Never write on DedErr: the decoded data is unreliable (SECDED can't correct double-bit
    -- errors), and writing it back would silently corrupt memory with a "valid" codeword over
    -- a previously-detectable double-bit error.
    ScrubWriteReq <= '1' when State = Write_s and CapturedDed = '0' and (ModeAlways_c or CapturedSec = '1') else
                     '0';

    -- Address mux
    Ram_Addr <= std_logic_vector(ScrubAddr) when ScrubMaster = '1' else Addr;

    -- WrEna mux: scrubber only writes in Write_s, user passes through in idle/yielded
    Ram_WrEna <= ScrubWriteReq when ScrubMaster = '1' else WrEna;

    -- WrData mux
    Ram_WrData <= CapturedData when ScrubMaster = '1' else WrData;

    -- Error injection mux: gate user error injection out while the scrubber owns the port.
    Ram_ErrInjFlip <= (Ram_ErrInjFlip'range => '0') when ScrubMaster = '1' else ErrInj_BitFlip;
    Ram_ErrInjVld  <= '0' when ScrubMaster = '1' else ErrInj_Valid;

    -----------------------------------------------------------------------------------------------
    -- Internal FT SP RAM
    -----------------------------------------------------------------------------------------------
    i_ram : entity work.olo_ft_ram_sp
        generic map (
            Depth_g        => Depth_g,
            Width_g        => Width_g,
            RamRdLatency_g => RamRdLatency_g,
            RamStyle_g     => RamStyle_g,
            RamBehavior_g  => RamBehavior_g,
            EccPipeline_g  => EccPipeline_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Addr           => Ram_Addr,
            WrEna          => Ram_WrEna,
            WrData         => Ram_WrData,
            ErrInj_BitFlip => Ram_ErrInjFlip,
            ErrInj_Valid   => Ram_ErrInjVld,
            RdData         => Ram_RdData,
            RdValid        => Ram_RdValid,
            RdEccSec       => Ram_RdSec,
            RdEccDed       => Ram_RdDed
        );

    -----------------------------------------------------------------------------------------------
    -- User read outputs
    -- Data, SEC and DED flags are passed through directly. The user is responsible for tracking
    -- RamRdLatency_g+EccPipeline_g after issuing a read, exactly like a normal olo_ft_ram_sp.
    -- RdValid only pulses for user-initiated reads (i.e. cycles where the user issued WrEna='0'
    -- while the scrubber was idle); cycles consumed by the scrubber are masked out.
    -----------------------------------------------------------------------------------------------
    RdData   <= Ram_RdData;
    RdEccSec <= Ram_RdSec;
    RdEccDed <= Ram_RdDed;

    p_user_rd_valid : process (Clk) is
    begin
        if rising_edge(Clk) then
            UserRdValidPipe(1) <= (not ScrubMaster) and (not WrEna);

            for i in 2 to TotalReadLatency_c loop
                UserRdValidPipe(i) <= UserRdValidPipe(i - 1);
            end loop;

        end if;
    end process;

    RdValid <= UserRdValidPipe(TotalReadLatency_c);

end architecture;

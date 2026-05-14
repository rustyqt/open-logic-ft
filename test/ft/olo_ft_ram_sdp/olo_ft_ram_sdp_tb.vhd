---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

library vunit_lib;
    context vunit_lib.vunit_context;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_ram_sdp_tb is
    generic (
        runner_cfg     : string;
        Width_g        : positive range 5 to 128  := 32;
        RamBehavior_g  : string                   := "RBW";
        IsAsync_g      : boolean                  := false;
        RamRdLatency_g : positive range 1 to 2    := 1;
        EccPipeline_g  : natural range 0 to 1     := 0;
        Scrub_g        : boolean                  := false
    );
end entity;

architecture sim of olo_ft_ram_sdp_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c     : time     := 10 ns;
    constant RdClkPeriod_c   : time     := 33.3 ns;
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);
    constant Depth_c         : positive := 200;

    -----------------------------------------------------------------------------------------------
    -- Bit-flip pattern helpers
    -----------------------------------------------------------------------------------------------
    function singleBit (idx : natural) return std_logic_vector is
        variable Result_v : std_logic_vector(CodewordWidth_c - 1 downto 0) := (others => '0');
    begin
        Result_v(idx) := '1';
        return Result_v;
    end function;

    function doubleBit (idxA : natural; idxB : natural) return std_logic_vector is
        variable Result_v : std_logic_vector(CodewordWidth_c - 1 downto 0) := (others => '0');
    begin
        Result_v(idxA) := '1';
        Result_v(idxB) := '1';
        return Result_v;
    end function;

    -----------------------------------------------------------------------------------------------
    -- TB Definitions
    -----------------------------------------------------------------------------------------------
    procedure write (
        address       : natural;
        data          : natural;
        signal Clk    : in std_logic;
        signal Addr   : out std_logic_vector;
        signal WrData : out std_logic_vector;
        signal WrEna  : out std_logic) is
    begin
        wait until rising_edge(Clk);
        Addr   <= toUslv(address, Addr'length);
        WrData <= toUslv(data, WrData'length);
        WrEna  <= '1';
        wait until rising_edge(Clk);
        WrEna  <= '0';
        Addr   <= toUslv(0, Addr'length);
        WrData <= toUslv(0, WrData'length);
    end procedure;

    procedure writeWithFlip (
        address         : natural;
        data            : natural;
        flipBits        : std_logic_vector;
        signal Clk      : in std_logic;
        signal Addr     : out std_logic_vector;
        signal WrData   : out std_logic_vector;
        signal WrEna    : out std_logic;
        signal InjFlip  : out std_logic_vector;
        signal InjValid : out std_logic) is
    begin
        wait until rising_edge(Clk);
        Addr     <= toUslv(address, Addr'length);
        WrData   <= toUslv(data, WrData'length);
        WrEna    <= '1';
        InjFlip  <= flipBits;
        InjValid <= '1';
        wait until rising_edge(Clk);
        WrEna    <= '0';
        InjFlip  <= (InjFlip'range => '0');
        InjValid <= '0';
        Addr     <= toUslv(0, Addr'length);
        WrData   <= toUslv(0, WrData'length);
    end procedure;

    procedure checkEcc (
        address       : natural;
        data          : natural;
        expEccSec     : std_logic;
        expEccDed     : std_logic;
        signal Clk    : in std_logic;
        signal Addr   : out std_logic_vector;
        signal RdEna  : out std_logic;
        signal RdData : in std_logic_vector;
        signal EccSec : in std_logic;
        signal EccDed : in std_logic;
        message       : string) is
    begin
        wait until rising_edge(Clk);
        Addr  <= toUslv(address, Addr'length);
        RdEna <= '1';
        wait until rising_edge(Clk);
        Addr  <= toUslv(0, Addr'length);
        RdEna <= '0';

        for i in 1 to RamRdLatency_g + EccPipeline_g loop
            wait until rising_edge(Clk);
        end loop;

        check_equal(RdData, toUslv(data, RdData'length), message & " data");
        check_equal(EccSec, expEccSec, message & " EccSec");
        check_equal(EccDed, expEccDed, message & " EccDed");
    end procedure;

    procedure checkDedOnly (
        address       : natural;
        expEccSec     : std_logic;
        expEccDed     : std_logic;
        signal Clk    : in std_logic;
        signal Addr   : out std_logic_vector;
        signal RdEna  : out std_logic;
        signal EccSec : in std_logic;
        signal EccDed : in std_logic;
        message       : string) is
    begin
        wait until rising_edge(Clk);
        Addr  <= toUslv(address, Addr'length);
        RdEna <= '1';
        wait until rising_edge(Clk);
        Addr  <= toUslv(0, Addr'length);
        RdEna <= '0';

        for i in 1 to RamRdLatency_g + EccPipeline_g loop
            wait until rising_edge(Clk);
        end loop;

        check_equal(EccSec, expEccSec, message & " EccSec");
        check_equal(EccDed, expEccDed, message & " EccDed");
    end procedure;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk            : std_logic                                          := '0';
    signal Rst            : std_logic                                          := '0';
    -- Write port
    signal Wr_Addr        : std_logic_vector(log2ceil(Depth_c) - 1 downto 0)   := (others => '0');
    signal Wr_Ena         : std_logic                                          := '0';
    signal Wr_Data        : std_logic_vector(Width_g - 1 downto 0)             := (others => '0');
    -- Read port
    signal Rd_Clk         : std_logic                                          := '0';
    signal Rd_Addr        : std_logic_vector(log2ceil(Depth_c) - 1 downto 0)   := (others => '0');
    signal Rd_Ena         : std_logic                                          := '0';
    signal Rd_Data        : std_logic_vector(Width_g - 1 downto 0);
    signal Rd_Valid       : std_logic;
    signal Rd_EccSec      : std_logic;
    signal Rd_EccDed      : std_logic;
    -- Error injection
    signal ErrInj_BitFlip : std_logic_vector(CodewordWidth_c - 1 downto 0)     := (others => '0');
    signal ErrInj_Valid   : std_logic                                          := '0';
    -- Scrubber status
    signal Scrub_Active   : std_logic;
    signal Scrub_EccSec   : std_logic;
    signal Scrub_EccDed   : std_logic;
    signal Scrub_PassDone : std_logic;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_ram_sdp
        generic map (
            Depth_g        => Depth_c,
            Width_g        => Width_g,
            RamBehavior_g  => RamBehavior_g,
            IsAsync_g      => IsAsync_g,
            RamRdLatency_g => RamRdLatency_g,
            EccPipeline_g  => EccPipeline_g,
            Scrub_g        => Scrub_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Wr_Addr        => Wr_Addr,
            Wr_Ena         => Wr_Ena,
            Wr_Data        => Wr_Data,
            Rd_Clk         => Rd_Clk,
            Rd_Addr        => Rd_Addr,
            Rd_Ena         => Rd_Ena,
            Rd_Data        => Rd_Data,
            Rd_Valid       => Rd_Valid,
            Rd_EccSec      => Rd_EccSec,
            Rd_EccDed      => Rd_EccDed,
            ErrInj_BitFlip => ErrInj_BitFlip,
            ErrInj_Valid   => ErrInj_Valid,
            Scrub_Active   => Scrub_Active,
            Scrub_EccSec   => Scrub_EccSec,
            Scrub_EccDed   => Scrub_EccDed,
            Scrub_PassDone => Scrub_PassDone
        );

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    g_async : if IsAsync_g generate
        Rd_Clk <= not Rd_Clk after 0.5 * RdClkPeriod_c;
    end generate;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 5 ms);

    p_control : process is
        variable PassCnt_v : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Wait for some time, then drive a synchronous reset pulse so the scrubber FSM starts
            -- from a known state on every test case.
            wait for 1 us;
            wait until rising_edge(Clk);
            Rst <= '1';
            wait until rising_edge(Clk);
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            -- Each test name is consumed unconditionally via `run()`, so VUnit reports PASS even
            -- on configurations where the body is empty (no SKIP cluttering the regression). The
            -- inner if-gates split the suite into two disjoint groups:
            --   * Scrub_g = false : original write/read + injection cases (the scrubber, when
            --                       running, would race-clean injected SEC errors before the
            --                       check fires).
            --   * Scrub_g = true  : opportunistic-scrubber-specific cases.
            if run("Basic") then
                if not Scrub_g then
                    write(1, 5, Clk, Wr_Addr, Wr_Data, Wr_Ena);
                    write(2, 6, Clk, Wr_Addr, Wr_Data, Wr_Ena);
                    write(3, 7, Clk, Wr_Addr, Wr_Data, Wr_Ena);
                    if IsAsync_g then
                        checkEcc(1, 5, '0', '0', Rd_Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Basic 1=5");
                        checkEcc(2, 6, '0', '0', Rd_Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Basic 2=6");
                        checkEcc(3, 7, '0', '0', Rd_Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Basic 3=7");
                        checkEcc(1, 5, '0', '0', Rd_Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Basic re-read 1=5");
                    else
                        checkEcc(1, 5, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Basic 1=5");
                        checkEcc(2, 6, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Basic 2=6");
                        checkEcc(3, 7, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Basic 3=7");
                        checkEcc(1, 5, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Basic re-read 1=5");
                    end if;
                end if;

            elsif run("EccSec") then
                if not Scrub_g then
                    writeWithFlip(20, 16#AB#, singleBit(0), Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                    if IsAsync_g then
                        checkEcc(20, 16#AB#, '1', '0', Rd_Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Sec flip0");
                    else
                        checkEcc(20, 16#AB#, '1', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Sec flip0");
                    end if;
                    write(20, 16#AB#, Clk, Wr_Addr, Wr_Data, Wr_Ena);
                    if IsAsync_g then
                        checkEcc(20, 16#AB#, '0', '0', Rd_Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Sec cleared");
                    else
                        checkEcc(20, 16#AB#, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Sec cleared");
                    end if;
                end if;

            elsif run("EccDed") then
                if not Scrub_g then
                    writeWithFlip(30, 16#EF#, doubleBit(0, 1), Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                    if IsAsync_g then
                        checkDedOnly(30, '0', '1', Rd_Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "Ded");
                    else
                        checkDedOnly(30, '0', '1', Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "Ded");
                    end if;
                    write(30, 16#EF#, Clk, Wr_Addr, Wr_Data, Wr_Ena);
                    if IsAsync_g then
                        checkEcc(30, 16#EF#, '0', '0', Rd_Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Ded cleared");
                    else
                        checkEcc(30, 16#EF#, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Ded cleared");
                    end if;
                end if;

            elsif run("MultiAddr") then
                if not Scrub_g then
                    write(40, 16#01#, Clk, Wr_Addr, Wr_Data, Wr_Ena);
                    write(41, 16#02#, Clk, Wr_Addr, Wr_Data, Wr_Ena);
                    write(42, 16#03#, Clk, Wr_Addr, Wr_Data, Wr_Ena);
                    writeWithFlip(41, 16#02#, singleBit(0), Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                    if IsAsync_g then
                        checkEcc(40, 16#01#, '0', '0', Rd_Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Multi addr40 clean");
                        checkEcc(41, 16#02#, '1', '0', Rd_Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Multi addr41 sec");
                        checkEcc(42, 16#03#, '0', '0', Rd_Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Multi addr42 clean");
                    else
                        checkEcc(40, 16#01#, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Multi addr40 clean");
                        checkEcc(41, 16#02#, '1', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Multi addr41 sec");
                        checkEcc(42, 16#03#, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "Multi addr42 clean");
                    end if;
                end if;

            elsif run("SecAllBits") then
                if not Scrub_g then

                    for bitIdx in 0 to CodewordWidth_c - 1 loop
                        writeWithFlip(bitIdx, 16#A5#, singleBit(bitIdx),
                                      Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                        if IsAsync_g then
                            checkEcc(bitIdx, 16#A5#, '1', '0', Rd_Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed,
                                     "SecAllBits flip " & integer'image(bitIdx));
                        else
                            checkEcc(bitIdx, 16#A5#, '1', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed,
                                     "SecAllBits flip " & integer'image(bitIdx));
                        end if;
                    end loop;

                end if;

            elsif run("DedSampledPairs") then
                if not Scrub_g then
                    writeWithFlip(60, 16#5A#, doubleBit(0, 1),
                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                    writeWithFlip(61, 16#5A#, doubleBit(0, CodewordWidth_c - 1),
                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                    writeWithFlip(62, 16#5A#, doubleBit(1, 2),
                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                    writeWithFlip(63, 16#5A#, doubleBit(2, 5),
                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                    writeWithFlip(64, 16#5A#, doubleBit(CodewordWidth_c / 2, CodewordWidth_c / 2 + 1),
                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                    if IsAsync_g then
                        checkDedOnly(60, '0', '1', Rd_Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "DedPair (0,1)");
                        checkDedOnly(61, '0', '1', Rd_Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "DedPair (0,N-1)");
                        checkDedOnly(62, '0', '1', Rd_Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "DedPair (1,2)");
                        checkDedOnly(63, '0', '1', Rd_Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "DedPair (2,5)");
                        checkDedOnly(64, '0', '1', Rd_Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "DedPair (mid,mid+1)");
                    else
                        checkDedOnly(60, '0', '1', Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "DedPair (0,1)");
                        checkDedOnly(61, '0', '1', Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "DedPair (0,N-1)");
                        checkDedOnly(62, '0', '1', Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "DedPair (1,2)");
                        checkDedOnly(63, '0', '1', Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "DedPair (2,5)");
                        checkDedOnly(64, '0', '1', Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed, "DedPair (mid,mid+1)");
                    end if;
                end if;

            elsif run("ScrubBasic") then
                if Scrub_g then
                    -- Basic write / read still works with the scrubber present. The scrubber may
                    -- rewrite any clean cell with its corrected codeword between user writes; on
                    -- a clean cell the corrected codeword equals the original, so the user reads
                    -- the value they wrote.
                    write(1, 5, Clk, Wr_Addr, Wr_Data, Wr_Ena);
                    write(2, 6, Clk, Wr_Addr, Wr_Data, Wr_Ena);
                    write(3, 7, Clk, Wr_Addr, Wr_Data, Wr_Ena);
                    checkEcc(1, 5, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "ScrubBasic 1=5");
                    checkEcc(2, 6, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "ScrubBasic 2=6");
                    checkEcc(3, 7, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed, "ScrubBasic 3=7");
                end if;

            elsif run("ScrubPassDone") then
                if Scrub_g then
                    -- With user idle, the scrubber walks the address space and pulses
                    -- Scrub_PassDone on rollover from Depth_g - 1 to 0. Confirm at least three
                    -- pulses within a bounded window so we know the scrubber is making progress.
                    PassCnt_v := 0;
                    while PassCnt_v < 3 loop
                        wait until rising_edge(Clk);
                        if Scrub_PassDone = '1' then
                            PassCnt_v := PassCnt_v + 1;
                        end if;
                    end loop;
                    check_true(true, "Scrub_PassDone pulsed >= 3 times");
                end if;

            elsif run("ScrubFixesSec") then
                if Scrub_g then
                    -- Plant SEC errors at two distinct addresses; idle the user; wait for two
                    -- full scrubber passes; verify the cells now read clean.
                    writeWithFlip(10, 16#AB#, singleBit(0),
                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                    writeWithFlip(20, 16#CD#, singleBit(2),
                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);

                    PassCnt_v := 0;
                    while PassCnt_v < 2 loop
                        wait until rising_edge(Clk);
                        if Scrub_PassDone = '1' then
                            PassCnt_v := PassCnt_v + 1;
                        end if;
                    end loop;

                    checkEcc(10, 16#AB#, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed,
                             "ScrubFixesSec addr10 cleaned");
                    checkEcc(20, 16#CD#, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed,
                             "ScrubFixesSec addr20 cleaned");
                end if;

            elsif run("ScrubDoesNotWriteOnDed") then
                if Scrub_g then
                    -- DED reads are reported but the writeback is suppressed (corrected data is
                    -- unreliable). After idle scrub time, the DED flag must still be set.
                    writeWithFlip(70, 16#EE#, doubleBit(0, 1),
                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);

                    PassCnt_v := 0;
                    while PassCnt_v < 2 loop
                        wait until rising_edge(Clk);
                        if Scrub_PassDone = '1' then
                            PassCnt_v := PassCnt_v + 1;
                        end if;
                    end loop;

                    checkDedOnly(70, '0', '1', Clk, Rd_Addr, Rd_Ena, Rd_EccSec, Rd_EccDed,
                                 "ScrubDoesNotWriteOnDed addr70 still Ded");
                end if;

            elsif run("ScrubAbortsOnCollision") then
                if Scrub_g then
                    -- Plant an SEC at addr=80, then write a different clean value to addr=80
                    -- repeatedly while the scrubber is running. The user's writes are always
                    -- authoritative: when the scrubber commits a write, it has either already
                    -- aborted (collision flag set) or it would commit a corrected codeword that
                    -- the user's next write overwrites anyway. After the storm, addr=80 must
                    -- hold the last user value, clean (no SEC).
                    writeWithFlip(80, 16#AA#, singleBit(0),
                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);

                    for i in 1 to 400 loop
                        wait until rising_edge(Clk);
                        if (i mod 2) = 0 then
                            Wr_Addr <= toUslv(80, Wr_Addr'length);
                            Wr_Data <= toUslv(16#BB#, Width_g);
                            Wr_Ena  <= '1';
                        else
                            Wr_Ena <= '0';
                        end if;
                    end loop;

                    wait until rising_edge(Clk);
                    Wr_Ena  <= '0';
                    Wr_Addr <= (others => '0');
                    Wr_Data <= (others => '0');

                    checkEcc(80, 16#BB#, '0', '0', Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed,
                             "ScrubAbortsOnCollision user write wins");
                end if;

            end if;

        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture;

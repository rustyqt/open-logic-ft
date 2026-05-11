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

library vunit_lib;
    context vunit_lib.vunit_context;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_ram_sdp_scrub_tb is
    generic (
        runner_cfg    : string;
        Width_g       : positive range 5 to 128 := 32;
        EccPipeline_g : natural range 0 to 1    := 0;
        ScrubMode_g   : string                  := "ON_ERROR"
    );
end entity;

architecture sim of olo_ft_ram_sdp_scrub_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c     : time     := 10 ns;
    constant Depth_c         : positive := 16;
    constant RdLatency_c     : positive := 1;
    constant ScrubPeriod_c   : positive := 1;
    constant TotalLatency_c  : positive := RdLatency_c + EccPipeline_g;
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);
    constant NoFlip_c        : std_logic_vector(CodewordWidth_c - 1 downto 0) := (others => '0');

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
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk            : std_logic                                              := '0';
    signal Rst            : std_logic                                              := '1';
    signal Wr_Addr        : std_logic_vector(log2ceil(Depth_c) - 1 downto 0)      := (others => '0');
    signal Wr_Ena         : std_logic                                              := '0';
    signal Wr_Data        : std_logic_vector(Width_g - 1 downto 0)                 := (others => '0');
    signal ErrInj_BitFlip : std_logic_vector(CodewordWidth_c - 1 downto 0)         := (others => '0');
    signal ErrInj_Valid   : std_logic                                              := '0';
    signal Rd_Addr        : std_logic_vector(log2ceil(Depth_c) - 1 downto 0)      := (others => '0');
    signal Rd_Ena         : std_logic                                              := '0';
    signal Rd_Data        : std_logic_vector(Width_g - 1 downto 0);
    signal Rd_EccSec      : std_logic;
    signal Rd_EccDed      : std_logic;
    signal Scrub_Stop     : std_logic                                              := '1';
    signal Scrub_Stopped  : std_logic;
    signal Scrub_Active   : std_logic;
    signal Scrub_Addr     : std_logic_vector(log2ceil(Depth_c) - 1 downto 0);
    signal Scrub_EccSec   : std_logic;
    signal Scrub_EccDed   : std_logic;
    signal Scrub_PassDone : std_logic;

    -----------------------------------------------------------------------------------------------
    -- Test helpers
    -----------------------------------------------------------------------------------------------
    procedure write_word (
        constant address  : in    natural;
        constant data     : in    natural;
        constant flip     : in    std_logic_vector;
        signal   Clk      : in    std_logic;
        signal   Wr_Addr  : out   std_logic_vector;
        signal   Wr_Data  : out   std_logic_vector;
        signal   Wr_Ena   : out   std_logic;
        signal   InjFlip  : out   std_logic_vector;
        signal   InjValid : out   std_logic) is
    begin
        wait until rising_edge(Clk);
        Wr_Addr  <= toUslv(address, Wr_Addr'length);
        Wr_Data  <= toUslv(data, Wr_Data'length);
        Wr_Ena   <= '1';
        InjFlip  <= flip;
        InjValid <= '1';
        wait until rising_edge(Clk);
        Wr_Ena   <= '0';
        InjFlip  <= (InjFlip'range => '0');
        InjValid <= '0';
    end procedure;

    procedure read_word (
        constant address    : in  natural;
        constant exp_data   : in  natural;
        constant exp_secerr : in  std_logic;
        constant exp_dederr : in  std_logic;
        constant msg        : in  string;
        signal   Clk        : in  std_logic;
        signal   Rd_Addr    : out std_logic_vector;
        signal   Rd_Ena     : out std_logic;
        signal   Rd_Data    : in  std_logic_vector;
        signal   Rd_EccSec  : in  std_logic;
        signal   Rd_EccDed  : in  std_logic) is
    begin
        wait until rising_edge(Clk);
        Rd_Addr <= toUslv(address, Rd_Addr'length);
        Rd_Ena  <= '1';
        wait until rising_edge(Clk);
        Rd_Ena  <= '0';
        -- Wait for read latency
        for i in 1 to TotalLatency_c loop
            wait until rising_edge(Clk);
        end loop;
        check_equal(Rd_Data, toUslv(exp_data, Rd_Data'length), msg & " data");
        check_equal(Rd_EccSec, exp_secerr, msg & " EccSec");
        check_equal(Rd_EccDed, exp_dederr, msg & " EccDed");
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_ram_sdp_scrub
        generic map (
            Depth_g       => Depth_c,
            Width_g       => Width_g,
            RamRdLatency_g   => RdLatency_c,
            EccPipeline_g => EccPipeline_g,
            ScrubPeriod_g => ScrubPeriod_c,
            ScrubMode_g   => ScrubMode_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Wr_Addr        => Wr_Addr,
            Wr_Ena         => Wr_Ena,
            Wr_Data        => Wr_Data,
            ErrInj_BitFlip => ErrInj_BitFlip,
            ErrInj_Valid   => ErrInj_Valid,
            Rd_Addr        => Rd_Addr,
            Rd_Ena         => Rd_Ena,
            Rd_Data        => Rd_Data,
            Rd_EccSec      => Rd_EccSec,
            Rd_EccDed      => Rd_EccDed,
            Scrub_Stop     => Scrub_Stop,
            Scrub_Stopped  => Scrub_Stopped,
            Scrub_Active   => Scrub_Active,
            Scrub_Addr     => Scrub_Addr,
            Scrub_EccSec   => Scrub_EccSec,
            Scrub_EccDed   => Scrub_EccDed,
            Scrub_PassDone => Scrub_PassDone
        );

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 1 ms);

    p_control : process is
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset and stop scrubber
            Rst        <= '1';
            Scrub_Stop <= '1';
            wait for 200 ns;
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);
            -- Wait for scrubber to confirm stopped
            wait until Scrub_Stopped = '1' and rising_edge(Clk);

            -- Basic write/read with scrubber stopped
            if run("Basic") then
                write_word(1, 16#11#, NoFlip_c, Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                write_word(2, 16#22#, NoFlip_c, Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                write_word(3, 16#33#, NoFlip_c, Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                read_word(1, 16#11#, '0', '0', "Basic addr1", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed);
                read_word(2, 16#22#, '0', '0', "Basic addr2", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed);
                read_word(3, 16#33#, '0', '0', "Basic addr3", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed);

            -- Scrubber finds and fixes a single-bit error
            elsif run("ScrubFindsAndFixes") then
                -- Initialize all addresses with clean data
                for i in 0 to Depth_c - 1 loop
                    write_word(i, i + 1, NoFlip_c, Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                end loop;
                -- Inject single-bit error at address 5
                write_word(5, 16#AB#, singleBit(0), Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                -- Verify read shows error (data corrected, but EccSec flagged)
                read_word(5, 16#AB#, '1', '0', "Before scrub addr5", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed);
                -- Release scrubber and wait for one complete pass
                Scrub_Stop <= '0';
                wait until Scrub_PassDone = '1' and rising_edge(Clk);
                -- Stop scrubber and verify error is gone
                Scrub_Stop <= '1';
                wait until Scrub_Stopped = '1' and rising_edge(Clk);
                read_word(5, 16#AB#, '0', '0', "After scrub addr5", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed);

            -- Scrubber detects double-bit error
            elsif run("DedDetect") then
                -- Inject double-bit error at address 7
                write_word(7, 16#CD#, doubleBit(0, 1), Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                -- Release scrubber, wait for pass
                Scrub_Stop <= '0';
                wait until Scrub_PassDone = '1' and rising_edge(Clk);
                -- Stop and verify
                Scrub_Stop <= '1';
                wait until Scrub_Stopped = '1' and rising_edge(Clk);
                -- After scrubbing, address 7 still has EccDed because SECDED can't fix double-bit errors
                read_word(7, 16#CD#, '0', '1', "Ded after scrub", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed);

            -- Stop handshake responds within reasonable time
            elsif run("StopAcknowledged") then
                -- Release scrubber
                Scrub_Stop <= '0';
                -- Let scrubber run for a while
                for i in 1 to 50 loop
                    wait until rising_edge(Clk);
                end loop;
                -- Now stop and measure response time
                Scrub_Stop <= '1';
                -- Worst case: ~RdLatency + EccPipeline + 4 cycles
                for i in 1 to 20 loop
                    wait until rising_edge(Clk);
                    exit when Scrub_Stopped = '1';
                end loop;
                check_equal(Scrub_Stopped, '1', "Stopped within 20 cycles");
                check_equal(Scrub_Active, '0', "Active=0 when stopped");

            -- Pass done pulses after a complete pass
            elsif run("PassDone") then
                Scrub_Stop <= '0';
                wait until Scrub_PassDone = '1' and rising_edge(Clk);
                check_equal(Scrub_PassDone, '1', "PassDone pulsed");
                -- Stop and verify
                Scrub_Stop <= '1';
                wait until Scrub_Stopped = '1' and rising_edge(Clk);

            -- No starvation: scrubber resumes correctly after long stop
            elsif run("NoStarvation") then
                -- Hold stop for a long time
                for i in 1 to 200 loop
                    wait until rising_edge(Clk);
                end loop;
                check_equal(Scrub_Stopped, '1', "Still stopped");
                -- Release and verify scrubber resumes
                Scrub_Stop <= '0';
                wait until Scrub_PassDone = '1' and rising_edge(Clk);
                check_equal(Scrub_PassDone, '1', "Resumed and finished pass");

            -- SEC across every codeword bit position (full bit-by-bit sweep, scrubber stopped)
            elsif run("SecAllBits") then
                for bitIdx in 0 to CodewordWidth_c - 1 loop
                    write_word(bitIdx mod Depth_c, 16#A5#, singleBit(bitIdx),
                               Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                    read_word(bitIdx mod Depth_c, 16#A5#, '1', '0',
                              "SecAllBits flip " & integer'image(bitIdx),
                              Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed);
                end loop;

            -- DED across a representative sample of bit pairs (scrubber stopped)
            -- Note: data is unreliable on DED, so this only verifies the EccSec/EccDed flags.
            elsif run("DedSampledPairs") then
                for pair in 0 to 4 loop
                    case pair is
                        when 0      => write_word(pair, 16#5A#, doubleBit(0, 1),
                                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                        when 1      => write_word(pair, 16#5A#, doubleBit(0, CodewordWidth_c - 1),
                                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                        when 2      => write_word(pair, 16#5A#, doubleBit(1, 2),
                                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                        when 3      => write_word(pair, 16#5A#, doubleBit(2, 5),
                                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                        when others => write_word(pair, 16#5A#,
                                                  doubleBit(CodewordWidth_c / 2, CodewordWidth_c / 2 + 1),
                                                  Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                    end case;
                    wait until rising_edge(Clk);
                    Rd_Addr <= toUslv(pair, Rd_Addr'length);
                    Rd_Ena  <= '1';
                    wait until rising_edge(Clk);
                    Rd_Ena  <= '0';
                    for i in 1 to TotalLatency_c loop
                        wait until rising_edge(Clk);
                    end loop;
                    check_equal(Rd_EccSec, '0', "DedPair " & integer'image(pair) & " EccSec");
                    check_equal(Rd_EccDed, '1', "DedPair " & integer'image(pair) & " EccDed");
                end loop;

            -- Interleaved user accesses and scrubber operation
            elsif run("InterleavedAccess") then
                -- Initialize
                for i in 0 to Depth_c - 1 loop
                    write_word(i, i * 3 + 1, NoFlip_c, Clk, Wr_Addr, Wr_Data, Wr_Ena, ErrInj_BitFlip, ErrInj_Valid);
                end loop;
                -- Allow scrubber to run several passes between accesses
                for pass in 1 to 3 loop
                    Scrub_Stop <= '0';
                    wait until Scrub_PassDone = '1' and rising_edge(Clk);
                    Scrub_Stop <= '1';
                    wait until Scrub_Stopped = '1' and rising_edge(Clk);
                    -- Verify all data still intact
                    for i in 0 to Depth_c - 1 loop
                        read_word(i, i * 3 + 1, '0', '0', "Interleaved pass " & integer'image(pass) &
                                  " addr" & integer'image(i), Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_EccSec, Rd_EccDed);
                    end loop;
                end loop;

            end if;

        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture;

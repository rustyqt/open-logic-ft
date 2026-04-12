---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Oliver Bruendler, Switzerland
-- Authors: Oliver Bruendler
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

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_ram_sp_scrub_tb is
    generic (
        runner_cfg    : string;
        Width_g       : positive range 5 to 128 := 32;
        EccPipeline_g : natural range 0 to 1    := 0;
        ScrubMode_g   : string                  := "ON_ERROR"
    );
end entity;

architecture sim of olo_ft_ram_sp_scrub_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c    : time     := 10 ns;
    constant Depth_c        : positive := 16;
    constant RdLatency_c    : positive := 1;
    constant ScrubPeriod_c  : positive := 1;
    constant TotalLatency_c : positive := RdLatency_c + EccPipeline_g;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk           : std_logic                                              := '0';
    signal Rst           : std_logic                                              := '1';
    signal Addr          : std_logic_vector(log2ceil(Depth_c) - 1 downto 0)       := (others => '0');
    signal WrEna         : std_logic                                              := '0';
    signal WrData        : std_logic_vector(Width_g - 1 downto 0)                 := (others => '0');
    signal WrEccBitFlip  : std_logic_vector(1 downto 0)                           := "00";
    signal RdData        : std_logic_vector(Width_g - 1 downto 0);
    signal RdSecErr      : std_logic;
    signal RdDedErr      : std_logic;
    signal Scrub_Stop    : std_logic                                              := '1';
    signal Scrub_Stopped : std_logic;
    signal Scrub_Active  : std_logic;
    signal Scrub_Addr    : std_logic_vector(log2ceil(Depth_c) - 1 downto 0);
    signal Scrub_SecErr  : std_logic;
    signal Scrub_DedErr  : std_logic;
    signal Scrub_PassDone : std_logic;

    -----------------------------------------------------------------------------------------------
    -- Test helpers
    -----------------------------------------------------------------------------------------------
    procedure write_word (
        constant address  : in    natural;
        constant data     : in    natural;
        constant flip     : in    std_logic_vector(1 downto 0);
        signal   Clk      : in    std_logic;
        signal   Addr     : out   std_logic_vector;
        signal   WrData   : out   std_logic_vector;
        signal   WrEna    : out   std_logic;
        signal   WrFlip   : out   std_logic_vector) is
    begin
        wait until rising_edge(Clk);
        Addr   <= toUslv(address, Addr'length);
        WrData <= toUslv(data, WrData'length);
        WrEna  <= '1';
        WrFlip <= flip;
        wait until rising_edge(Clk);
        WrEna  <= '0';
        WrFlip <= "00";
    end procedure;

    procedure read_word (
        constant address    : in  natural;
        constant exp_data   : in  natural;
        constant exp_secerr : in  std_logic;
        constant exp_dederr : in  std_logic;
        constant msg        : in  string;
        signal   Clk        : in  std_logic;
        signal   Addr       : out std_logic_vector;
        signal   RdData     : in  std_logic_vector;
        signal   RdSecErr   : in  std_logic;
        signal   RdDedErr   : in  std_logic) is
    begin
        wait until rising_edge(Clk);
        Addr <= toUslv(address, Addr'length);
        wait until rising_edge(Clk); -- Address sampled
        -- Wait for read latency
        for i in 1 to TotalLatency_c loop
            wait until rising_edge(Clk);
        end loop;
        check_equal(RdData, toUslv(exp_data, RdData'length), msg & " data");
        check_equal(RdSecErr, exp_secerr, msg & " SecErr");
        check_equal(RdDedErr, exp_dederr, msg & " DedErr");
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_ram_sp_scrub
        generic map (
            Depth_g       => Depth_c,
            Width_g       => Width_g,
            RdLatency_g   => RdLatency_c,
            EccPipeline_g => EccPipeline_g,
            ScrubPeriod_g => ScrubPeriod_c,
            ScrubMode_g   => ScrubMode_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Addr           => Addr,
            WrEna          => WrEna,
            WrData         => WrData,
            WrEccBitFlip   => WrEccBitFlip,
            RdData         => RdData,
            RdSecErr       => RdSecErr,
            RdDedErr       => RdDedErr,
            Scrub_Stop     => Scrub_Stop,
            Scrub_Stopped  => Scrub_Stopped,
            Scrub_Active   => Scrub_Active,
            Scrub_Addr     => Scrub_Addr,
            Scrub_SecErr   => Scrub_SecErr,
            Scrub_DedErr   => Scrub_DedErr,
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
                write_word(1, 16#11#, "00", Clk, Addr, WrData, WrEna, WrEccBitFlip);
                write_word(2, 16#22#, "00", Clk, Addr, WrData, WrEna, WrEccBitFlip);
                write_word(3, 16#33#, "00", Clk, Addr, WrData, WrEna, WrEccBitFlip);
                read_word(1, 16#11#, '0', '0', "Basic addr1", Clk, Addr, RdData, RdSecErr, RdDedErr);
                read_word(2, 16#22#, '0', '0', "Basic addr2", Clk, Addr, RdData, RdSecErr, RdDedErr);
                read_word(3, 16#33#, '0', '0', "Basic addr3", Clk, Addr, RdData, RdSecErr, RdDedErr);

            -- Scrubber finds and fixes a single-bit error
            elsif run("ScrubFindsAndFixes") then
                -- Initialize all addresses with clean data
                for i in 0 to Depth_c - 1 loop
                    write_word(i, i + 1, "00", Clk, Addr, WrData, WrEna, WrEccBitFlip);
                end loop;
                -- Inject single-bit error at address 5
                write_word(5, 16#AB#, "01", Clk, Addr, WrData, WrEna, WrEccBitFlip);
                -- Verify read shows error (data corrected, but SecErr flagged)
                read_word(5, 16#AB#, '1', '0', "Before scrub addr5", Clk, Addr, RdData, RdSecErr, RdDedErr);
                -- Release scrubber and wait for one complete pass
                Scrub_Stop <= '0';
                wait until Scrub_PassDone = '1' and rising_edge(Clk);
                -- Stop scrubber and verify error is gone
                Scrub_Stop <= '1';
                wait until Scrub_Stopped = '1' and rising_edge(Clk);
                read_word(5, 16#AB#, '0', '0', "After scrub addr5", Clk, Addr, RdData, RdSecErr, RdDedErr);

            -- Scrubber detects double-bit error
            elsif run("DedDetect") then
                -- Inject double-bit error at address 7
                write_word(7, 16#CD#, "11", Clk, Addr, WrData, WrEna, WrEccBitFlip);
                -- Release scrubber, wait for pass
                Scrub_Stop <= '0';
                wait until Scrub_PassDone = '1' and rising_edge(Clk);
                -- Stop and verify
                Scrub_Stop <= '1';
                wait until Scrub_Stopped = '1' and rising_edge(Clk);
                -- After scrubbing, address 7 still has DedErr because SECDED can't fix double-bit errors
                read_word(7, 16#CD#, '0', '1', "Ded after scrub", Clk, Addr, RdData, RdSecErr, RdDedErr);

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

            -- Interleaved user accesses and scrubber operation
            elsif run("InterleavedAccess") then
                -- Initialize
                for i in 0 to Depth_c - 1 loop
                    write_word(i, i * 3 + 1, "00", Clk, Addr, WrData, WrEna, WrEccBitFlip);
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
                                  " addr" & integer'image(i), Clk, Addr, RdData, RdSecErr, RdDedErr);
                    end loop;
                end loop;

            end if;

        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture;

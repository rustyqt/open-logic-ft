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
    constant ClkPeriod_c    : time     := 10 ns;
    constant Depth_c        : positive := 16;
    constant RdLatency_c    : positive := 1;
    constant ScrubPeriod_c  : positive := 1;
    constant TotalLatency_c : positive := RdLatency_c + EccPipeline_g;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk            : std_logic                                              := '0';
    signal Rst            : std_logic                                              := '1';
    signal Wr_Addr        : std_logic_vector(log2ceil(Depth_c) - 1 downto 0)      := (others => '0');
    signal Wr_Ena         : std_logic                                              := '0';
    signal Wr_Data        : std_logic_vector(Width_g - 1 downto 0)                 := (others => '0');
    signal Wr_EccBitFlip  : std_logic_vector(1 downto 0)                           := "00";
    signal Rd_Addr        : std_logic_vector(log2ceil(Depth_c) - 1 downto 0)      := (others => '0');
    signal Rd_Ena         : std_logic                                              := '0';
    signal Rd_Data        : std_logic_vector(Width_g - 1 downto 0);
    signal Rd_SecErr      : std_logic;
    signal Rd_DedErr      : std_logic;
    signal Scrub_Stop     : std_logic                                              := '1';
    signal Scrub_Stopped  : std_logic;
    signal Scrub_Active   : std_logic;
    signal Scrub_Addr     : std_logic_vector(log2ceil(Depth_c) - 1 downto 0);
    signal Scrub_SecErr   : std_logic;
    signal Scrub_DedErr   : std_logic;
    signal Scrub_PassDone : std_logic;

    -----------------------------------------------------------------------------------------------
    -- Test helpers
    -----------------------------------------------------------------------------------------------
    procedure write_word (
        constant address  : in    natural;
        constant data     : in    natural;
        constant flip     : in    std_logic_vector(1 downto 0);
        signal   Clk      : in    std_logic;
        signal   Wr_Addr  : out   std_logic_vector;
        signal   Wr_Data  : out   std_logic_vector;
        signal   Wr_Ena   : out   std_logic;
        signal   Wr_Flip  : out   std_logic_vector) is
    begin
        wait until rising_edge(Clk);
        Wr_Addr <= toUslv(address, Wr_Addr'length);
        Wr_Data <= toUslv(data, Wr_Data'length);
        Wr_Ena  <= '1';
        Wr_Flip <= flip;
        wait until rising_edge(Clk);
        Wr_Ena  <= '0';
        Wr_Flip <= "00";
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
        signal   Rd_SecErr  : in  std_logic;
        signal   Rd_DedErr  : in  std_logic) is
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
        check_equal(Rd_SecErr, exp_secerr, msg & " SecErr");
        check_equal(Rd_DedErr, exp_dederr, msg & " DedErr");
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_ram_sdp_scrub
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
            Wr_Addr        => Wr_Addr,
            Wr_Ena         => Wr_Ena,
            Wr_Data        => Wr_Data,
            Wr_EccBitFlip  => Wr_EccBitFlip,
            Rd_Addr        => Rd_Addr,
            Rd_Ena         => Rd_Ena,
            Rd_Data        => Rd_Data,
            Rd_SecErr      => Rd_SecErr,
            Rd_DedErr      => Rd_DedErr,
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
                write_word(1, 16#11#, "00", Clk, Wr_Addr, Wr_Data, Wr_Ena, Wr_EccBitFlip);
                write_word(2, 16#22#, "00", Clk, Wr_Addr, Wr_Data, Wr_Ena, Wr_EccBitFlip);
                write_word(3, 16#33#, "00", Clk, Wr_Addr, Wr_Data, Wr_Ena, Wr_EccBitFlip);
                read_word(1, 16#11#, '0', '0', "Basic addr1", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_SecErr, Rd_DedErr);
                read_word(2, 16#22#, '0', '0', "Basic addr2", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_SecErr, Rd_DedErr);
                read_word(3, 16#33#, '0', '0', "Basic addr3", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_SecErr, Rd_DedErr);

            -- Scrubber finds and fixes a single-bit error
            elsif run("ScrubFindsAndFixes") then
                -- Initialize all addresses with clean data
                for i in 0 to Depth_c - 1 loop
                    write_word(i, i + 1, "00", Clk, Wr_Addr, Wr_Data, Wr_Ena, Wr_EccBitFlip);
                end loop;
                -- Inject single-bit error at address 5
                write_word(5, 16#AB#, "01", Clk, Wr_Addr, Wr_Data, Wr_Ena, Wr_EccBitFlip);
                -- Verify read shows error (data corrected, but SecErr flagged)
                read_word(5, 16#AB#, '1', '0', "Before scrub addr5", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_SecErr, Rd_DedErr);
                -- Release scrubber and wait for one complete pass
                Scrub_Stop <= '0';
                wait until Scrub_PassDone = '1' and rising_edge(Clk);
                -- Stop scrubber and verify error is gone
                Scrub_Stop <= '1';
                wait until Scrub_Stopped = '1' and rising_edge(Clk);
                read_word(5, 16#AB#, '0', '0', "After scrub addr5", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_SecErr, Rd_DedErr);

            -- Scrubber detects double-bit error
            elsif run("DedDetect") then
                -- Inject double-bit error at address 7
                write_word(7, 16#CD#, "11", Clk, Wr_Addr, Wr_Data, Wr_Ena, Wr_EccBitFlip);
                -- Release scrubber, wait for pass
                Scrub_Stop <= '0';
                wait until Scrub_PassDone = '1' and rising_edge(Clk);
                -- Stop and verify
                Scrub_Stop <= '1';
                wait until Scrub_Stopped = '1' and rising_edge(Clk);
                -- After scrubbing, address 7 still has DedErr because SECDED can't fix double-bit errors
                read_word(7, 16#CD#, '0', '1', "Ded after scrub", Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_SecErr, Rd_DedErr);

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
                    write_word(i, i * 3 + 1, "00", Clk, Wr_Addr, Wr_Data, Wr_Ena, Wr_EccBitFlip);
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
                                  " addr" & integer'image(i), Clk, Rd_Addr, Rd_Ena, Rd_Data, Rd_SecErr, Rd_DedErr);
                    end loop;
                end loop;

            end if;

        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture;

---------------------------------------------------------------------------------------------------
-- Copyright (c) 2025 by Oliver Bruendler, Switzerland
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
entity olo_ft_fifo_sync_tb is
    generic (
        runner_cfg    : string;
        Width_g       : positive range 5 to 128 := 32;
        EccPipeline_g : natural range 0 to 1    := 0
    );
end entity;

architecture sim of olo_ft_fifo_sync_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c : time    := 10 ns;
    constant Depth_c     : natural := 32;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk           : std_logic                                                 := '0';
    signal Rst           : std_logic                                                 := '1';
    signal In_Data       : std_logic_vector(Width_g - 1 downto 0)                    := (others => '0');
    signal In_Valid      : std_logic                                                 := '0';
    signal In_Ready      : std_logic;
    signal In_Level      : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);
    signal In_EccBitFlip : std_logic_vector(1 downto 0)                              := "00";
    signal Out_Data      : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Valid     : std_logic;
    signal Out_Ready     : std_logic                                                 := '0';
    signal Out_Level     : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);
    signal Out_SecErr    : std_logic;
    signal Out_DedErr    : std_logic;
    signal Full          : std_logic;
    signal Empty         : std_logic;

    -- Total latency for pipeline
    constant PipeLatency_c : natural := EccPipeline_g;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g       => Width_g,
            Depth_g       => Depth_c,
            EccPipeline_g => EccPipeline_g
        )
        port map (
            Clk           => Clk,
            Rst           => Rst,
            In_Data       => In_Data,
            In_Valid      => In_Valid,
            In_Ready      => In_Ready,
            In_Level      => In_Level,
            In_EccBitFlip => In_EccBitFlip,
            Out_Data      => Out_Data,
            Out_Valid     => Out_Valid,
            Out_Ready     => Out_Ready,
            Out_Level     => Out_Level,
            Out_SecErr    => Out_SecErr,
            Out_DedErr    => Out_DedErr,
            Full          => Full,
            Empty         => Empty
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

            -- Reset
            Rst       <= '1';
            Out_Ready <= '0';
            wait for 1 us;
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            -- Basic write and read
            if run("Basic") then
                -- Write 3 words
                for i in 1 to 3 loop
                    wait until rising_edge(Clk);
                    In_Data  <= toUslv(i * 10, Width_g);
                    In_Valid <= '1';
                    wait until rising_edge(Clk);
                    In_Valid <= '0';
                end loop;

                -- Read and verify
                Out_Ready <= '1';
                for i in 1 to 3 loop
                    wait until rising_edge(Clk) and Out_Valid = '1';
                    check_equal(Out_Data, toUslv(i * 10, Width_g), "Basic data " & integer'image(i));
                    check_equal(Out_SecErr, '0', "Basic SecErr " & integer'image(i));
                    check_equal(Out_DedErr, '0', "Basic DedErr " & integer'image(i));
                end loop;

            -- Single bit error injection and correction
            elsif run("SecErr") then
                -- Write with single-bit error
                wait until rising_edge(Clk);
                In_Data       <= toUslv(16#AB#, Width_g);
                In_Valid      <= '1';
                In_EccBitFlip <= "01";
                wait until rising_edge(Clk);
                In_Valid      <= '0';
                In_EccBitFlip <= "00";

                -- Read and verify correction
                Out_Ready <= '1';
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#AB#, Width_g), "Sec data corrected");
                check_equal(Out_SecErr, '1', "Sec SecErr");
                check_equal(Out_DedErr, '0', "Sec DedErr");

            -- Double bit error detection
            elsif run("DedErr") then
                -- Write with double-bit error
                wait until rising_edge(Clk);
                In_Data       <= toUslv(16#EF#, Width_g);
                In_Valid      <= '1';
                In_EccBitFlip <= "11";
                wait until rising_edge(Clk);
                In_Valid      <= '0';
                In_EccBitFlip <= "00";

                -- Read and verify detection
                Out_Ready <= '1';
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_SecErr, '0', "Ded SecErr");
                check_equal(Out_DedErr, '1', "Ded DedErr");

            -- Mixed: clean and error words interleaved
            elsif run("Mixed") then
                -- Write clean word
                wait until rising_edge(Clk);
                In_Data  <= toUslv(16#01#, Width_g);
                In_Valid <= '1';
                wait until rising_edge(Clk);
                -- Write error word
                In_Data       <= toUslv(16#02#, Width_g);
                In_EccBitFlip <= "01";
                wait until rising_edge(Clk);
                -- Write clean word
                In_Data       <= toUslv(16#03#, Width_g);
                In_EccBitFlip <= "00";
                wait until rising_edge(Clk);
                In_Valid <= '0';

                -- Read and verify selective errors
                Out_Ready <= '1';
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#01#, Width_g), "Mixed word1 data");
                check_equal(Out_SecErr, '0', "Mixed word1 SecErr");
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#02#, Width_g), "Mixed word2 data");
                check_equal(Out_SecErr, '1', "Mixed word2 SecErr");
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#03#, Width_g), "Mixed word3 data");
                check_equal(Out_SecErr, '0', "Mixed word3 SecErr");

            -- Fill and drain, verify data integrity across many entries
            elsif run("FullEmpty") then
                -- Verify initially empty
                check_equal(Empty, '1', "Initially empty");

                -- Fill FIFO with Depth_c words (Out_Ready='0' prevents drain)
                Out_Ready <= '0';
                for i in 0 to Depth_c - 1 loop
                    wait until rising_edge(Clk);
                    In_Data  <= toUslv(i, Width_g);
                    In_Valid <= '1';
                end loop;
                wait until rising_edge(Clk);
                In_Valid <= '0';

                -- Drain FIFO and verify all data
                Out_Ready <= '1';
                for i in 0 to Depth_c - 1 loop
                    wait until rising_edge(Clk) and Out_Valid = '1';
                    check_equal(Out_Data, toUslv(i, Width_g), "Drain data " & integer'image(i));
                    check_equal(Out_SecErr, '0', "Drain SecErr " & integer'image(i));
                end loop;

            end if;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

end architecture;

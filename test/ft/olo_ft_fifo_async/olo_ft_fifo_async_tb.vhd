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

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_fifo_async_tb is
    generic (
        runner_cfg     : string;
        Width_g        : positive range 5 to 128 := 32;
        Optimization_g : string                  := "SPEED";
        EccPipeline_g  : natural range 0 to 1    := 0
    );
end entity;

architecture sim of olo_ft_fifo_async_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant InClkPeriod_c  : time    := 10 ns;
    constant OutClkPeriod_c : time    := 33.3 ns;
    constant Depth_c        : natural := 32;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal In_Clk        : std_logic                                              := '0';
    signal In_Rst        : std_logic                                              := '1';
    signal In_RstOut     : std_logic;
    signal In_Data       : std_logic_vector(Width_g - 1 downto 0)                 := (others => '0');
    signal In_Valid      : std_logic                                              := '0';
    signal In_Ready      : std_logic;
    signal In_EccBitFlip : std_logic_vector(1 downto 0)                           := "00";
    signal In_Level      : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);
    signal Out_Clk       : std_logic                                              := '0';
    signal Out_Rst       : std_logic                                              := '0';
    signal Out_RstOut    : std_logic;
    signal Out_Data      : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Valid     : std_logic;
    signal Out_Ready     : std_logic                                              := '0';
    signal Out_SecErr    : std_logic;
    signal Out_DedErr    : std_logic;
    signal Out_Level     : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_fifo_async
        generic map (
            Width_g        => Width_g,
            Depth_g        => Depth_c,
            Optimization_g => Optimization_g,
            EccPipeline_g  => EccPipeline_g
        )
        port map (
            In_Clk        => In_Clk,
            In_Rst        => In_Rst,
            In_RstOut     => In_RstOut,
            In_Data       => In_Data,
            In_Valid      => In_Valid,
            In_Ready      => In_Ready,
            In_EccBitFlip => In_EccBitFlip,
            In_Level      => In_Level,
            Out_Clk       => Out_Clk,
            Out_Rst       => Out_Rst,
            Out_RstOut    => Out_RstOut,
            Out_Data      => Out_Data,
            Out_Valid     => Out_Valid,
            Out_Ready     => Out_Ready,
            Out_SecErr    => Out_SecErr,
            Out_DedErr    => Out_DedErr,
            Out_Level     => Out_Level
        );

    -----------------------------------------------------------------------------------------------
    -- Clocks
    -----------------------------------------------------------------------------------------------
    In_Clk  <= not In_Clk after 0.5 * InClkPeriod_c;
    Out_Clk <= not Out_Clk after 0.5 * OutClkPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 1 ms);

    p_control : process is
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            In_Rst    <= '1';
            Out_Ready <= '0';
            wait for 1 us;
            wait until rising_edge(In_Clk);
            In_Rst <= '0';
            wait for 1 us;

            -- Basic write and read across clock domains
            if run("Basic") then
                -- Write 3 words on In_Clk
                for i in 1 to 3 loop
                    wait until rising_edge(In_Clk);
                    In_Data  <= toUslv(i * 10, Width_g);
                    In_Valid <= '1';
                    wait until rising_edge(In_Clk);
                    In_Valid <= '0';
                    wait for 100 ns; -- allow CDC
                end loop;

                -- Read and verify on Out_Clk
                Out_Ready <= '1';
                for i in 1 to 3 loop
                    wait until rising_edge(Out_Clk) and Out_Valid = '1';
                    check_equal(Out_Data, toUslv(i * 10, Width_g), "Basic data " & integer'image(i));
                    check_equal(Out_SecErr, '0', "Basic SecErr " & integer'image(i));
                    check_equal(Out_DedErr, '0', "Basic DedErr " & integer'image(i));
                end loop;

            -- Single bit error injection
            elsif run("SecErr") then
                wait until rising_edge(In_Clk);
                In_Data       <= toUslv(16#AB#, Width_g);
                In_Valid      <= '1';
                In_EccBitFlip <= "01";
                wait until rising_edge(In_Clk);
                In_Valid      <= '0';
                In_EccBitFlip <= "00";
                wait for 200 ns;

                Out_Ready <= '1';
                wait until rising_edge(Out_Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#AB#, Width_g), "Sec data corrected");
                check_equal(Out_SecErr, '1', "Sec SecErr");
                check_equal(Out_DedErr, '0', "Sec DedErr");

            -- Double bit error detection
            elsif run("DedErr") then
                wait until rising_edge(In_Clk);
                In_Data       <= toUslv(16#EF#, Width_g);
                In_Valid      <= '1';
                In_EccBitFlip <= "11";
                wait until rising_edge(In_Clk);
                In_Valid      <= '0';
                In_EccBitFlip <= "00";
                wait for 200 ns;

                Out_Ready <= '1';
                wait until rising_edge(Out_Clk) and Out_Valid = '1';
                check_equal(Out_SecErr, '0', "Ded SecErr");
                check_equal(Out_DedErr, '1', "Ded DedErr");

            end if;

        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture;

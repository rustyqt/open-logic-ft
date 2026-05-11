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
    constant InClkPeriod_c   : time     := 10 ns;
    constant OutClkPeriod_c  : time     := 33.3 ns;
    constant Depth_c         : natural  := 32;
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);

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
    signal In_Clk        : std_logic                                              := '0';
    signal In_Rst        : std_logic                                              := '1';
    signal In_RstOut     : std_logic;
    signal In_Data       : std_logic_vector(Width_g - 1 downto 0)                 := (others => '0');
    signal In_Valid      : std_logic                                              := '0';
    signal In_Ready      : std_logic;
    signal In_ErrInj_BitFlip : std_logic_vector(CodewordWidth_c - 1 downto 0)         := (others => '0');
    signal In_ErrInj_Valid   : std_logic                                                := '0';
    signal In_Level      : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);
    signal Out_Clk       : std_logic                                              := '0';
    signal Out_Rst       : std_logic                                              := '0';
    signal Out_RstOut    : std_logic;
    signal Out_Data      : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Valid     : std_logic;
    signal Out_Ready     : std_logic                                              := '0';
    signal Out_EccSec    : std_logic;
    signal Out_EccDed    : std_logic;
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
            In_ErrInj_BitFlip => In_ErrInj_BitFlip,
            In_ErrInj_Valid   => In_ErrInj_Valid,
            In_Level      => In_Level,
            Out_Clk       => Out_Clk,
            Out_Rst       => Out_Rst,
            Out_RstOut    => Out_RstOut,
            Out_Data      => Out_Data,
            Out_Valid     => Out_Valid,
            Out_Ready     => Out_Ready,
            Out_EccSec    => Out_EccSec,
            Out_EccDed    => Out_EccDed,
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
                    check_equal(Out_EccSec, '0', "Basic EccSec " & integer'image(i));
                    check_equal(Out_EccDed, '0', "Basic EccDed " & integer'image(i));
                end loop;

            -- Single bit error injection
            elsif run("EccSec") then
                wait until rising_edge(In_Clk);
                In_Data       <= toUslv(16#AB#, Width_g);
                In_Valid      <= '1';
                In_ErrInj_BitFlip <= singleBit(0);
                In_ErrInj_Valid   <= '1';
                wait until rising_edge(In_Clk);
                In_Valid      <= '0';
                In_ErrInj_BitFlip <= (others => '0');
                In_ErrInj_Valid   <= '0';
                wait for 200 ns;

                Out_Ready <= '1';
                wait until rising_edge(Out_Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#AB#, Width_g), "Sec data corrected");
                check_equal(Out_EccSec, '1', "Sec EccSec");
                check_equal(Out_EccDed, '0', "Sec EccDed");

            -- Double bit error detection
            elsif run("EccDed") then
                wait until rising_edge(In_Clk);
                In_Data       <= toUslv(16#EF#, Width_g);
                In_Valid      <= '1';
                In_ErrInj_BitFlip <= doubleBit(0, 1);
                In_ErrInj_Valid   <= '1';
                wait until rising_edge(In_Clk);
                In_Valid      <= '0';
                In_ErrInj_BitFlip <= (others => '0');
                In_ErrInj_Valid   <= '0';
                wait for 200 ns;

                Out_Ready <= '1';
                wait until rising_edge(Out_Clk) and Out_Valid = '1';
                check_equal(Out_EccSec, '0', "Ded EccSec");
                check_equal(Out_EccDed, '1', "Ded EccDed");

            -- SEC across every codeword bit position (full bit-by-bit sweep)
            elsif run("SecAllBits") then
                Out_Ready <= '1';
                for bitIdx in 0 to CodewordWidth_c - 1 loop
                    wait until rising_edge(In_Clk);
                    In_Data       <= toUslv(16#A5#, Width_g);
                    In_Valid      <= '1';
                    In_ErrInj_BitFlip <= singleBit(bitIdx);
                    In_ErrInj_Valid   <= '1';
                    wait until rising_edge(In_Clk);
                    In_Valid      <= '0';
                    In_ErrInj_BitFlip <= (others => '0');
                    In_ErrInj_Valid   <= '0';
                    wait until rising_edge(Out_Clk) and Out_Valid = '1';
                    check_equal(Out_Data, toUslv(16#A5#, Width_g),
                                "SecAllBits data flip " & integer'image(bitIdx));
                    check_equal(Out_EccSec, '1', "SecAllBits EccSec flip " & integer'image(bitIdx));
                    check_equal(Out_EccDed, '0', "SecAllBits EccDed flip " & integer'image(bitIdx));
                end loop;

            -- DED across a representative sample of bit pairs
            elsif run("DedSampledPairs") then
                Out_Ready <= '1';
                for pair in 0 to 4 loop
                    wait until rising_edge(In_Clk);
                    In_Data  <= toUslv(16#5A#, Width_g);
                    In_Valid <= '1';
                    case pair is
                        when 0 => In_ErrInj_BitFlip <= doubleBit(0, 1);
                        when 1 => In_ErrInj_BitFlip <= doubleBit(0, CodewordWidth_c - 1);
                        when 2 => In_ErrInj_BitFlip <= doubleBit(1, 2);
                        when 3 => In_ErrInj_BitFlip <= doubleBit(2, 5);
                        when others => In_ErrInj_BitFlip <= doubleBit(CodewordWidth_c / 2, CodewordWidth_c / 2 + 1);
                    end case;
                    In_ErrInj_Valid <= '1';
                    wait until rising_edge(In_Clk);
                    In_Valid      <= '0';
                    In_ErrInj_BitFlip <= (others => '0');
                    In_ErrInj_Valid   <= '0';
                    wait until rising_edge(Out_Clk) and Out_Valid = '1';
                    check_equal(Out_EccSec, '0', "DedPair EccSec pair " & integer'image(pair));
                    check_equal(Out_EccDed, '1', "DedPair EccDed pair " & integer'image(pair));
                end loop;

            end if;

        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture;

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
    constant ClkPeriod_c     : time     := 10 ns;
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
    signal Clk           : std_logic                                                 := '0';
    signal Rst           : std_logic                                                 := '1';
    signal In_Data       : std_logic_vector(Width_g - 1 downto 0)                    := (others => '0');
    signal In_Valid      : std_logic                                                 := '0';
    signal In_Ready      : std_logic;
    signal In_Level      : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);
    signal In_ErrInj_BitFlip : std_logic_vector(CodewordWidth_c - 1 downto 0)            := (others => '0');
    signal In_ErrInj_Valid : std_logic                                                := '0';
    signal Out_Data      : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Valid     : std_logic;
    signal Out_Ready     : std_logic                                                 := '0';
    signal Out_Level     : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);
    signal Out_EccSec    : std_logic;
    signal Out_EccDed    : std_logic;
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
            In_ErrInj_BitFlip => In_ErrInj_BitFlip,
            In_ErrInj_Valid   => In_ErrInj_Valid,
            Out_Data      => Out_Data,
            Out_Valid     => Out_Valid,
            Out_Ready     => Out_Ready,
            Out_Level     => Out_Level,
            Out_EccSec    => Out_EccSec,
            Out_EccDed    => Out_EccDed,
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
                    check_equal(Out_EccSec, '0', "Basic EccSec " & integer'image(i));
                    check_equal(Out_EccDed, '0', "Basic EccDed " & integer'image(i));
                end loop;

            -- Single bit error injection and correction
            elsif run("EccSec") then
                -- Write with single-bit error
                wait until rising_edge(Clk);
                In_Data       <= toUslv(16#AB#, Width_g);
                In_Valid      <= '1';
                In_ErrInj_BitFlip <= singleBit(0);
                In_ErrInj_Valid   <= '1';
                wait until rising_edge(Clk);
                In_Valid      <= '0';
                In_ErrInj_BitFlip <= (others => '0');
                In_ErrInj_Valid   <= '0';

                -- Read and verify correction
                Out_Ready <= '1';
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#AB#, Width_g), "Sec data corrected");
                check_equal(Out_EccSec, '1', "Sec EccSec");
                check_equal(Out_EccDed, '0', "Sec EccDed");

            -- Double bit error detection
            elsif run("EccDed") then
                -- Write with double-bit error
                wait until rising_edge(Clk);
                In_Data       <= toUslv(16#EF#, Width_g);
                In_Valid      <= '1';
                In_ErrInj_BitFlip <= doubleBit(0, 1);
                In_ErrInj_Valid   <= '1';
                wait until rising_edge(Clk);
                In_Valid      <= '0';
                In_ErrInj_BitFlip <= (others => '0');
                In_ErrInj_Valid   <= '0';

                -- Read and verify detection
                Out_Ready <= '1';
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_EccSec, '0', "Ded EccSec");
                check_equal(Out_EccDed, '1', "Ded EccDed");

            -- Mixed: clean and error words interleaved
            elsif run("Mixed") then
                -- Write clean word
                wait until rising_edge(Clk);
                In_Data  <= toUslv(16#01#, Width_g);
                In_Valid <= '1';
                wait until rising_edge(Clk);
                -- Write error word
                In_Data       <= toUslv(16#02#, Width_g);
                In_ErrInj_BitFlip <= singleBit(0);
                In_ErrInj_Valid   <= '1';
                wait until rising_edge(Clk);
                -- Write clean word
                In_Data       <= toUslv(16#03#, Width_g);
                In_ErrInj_BitFlip <= (others => '0');
                In_ErrInj_Valid   <= '0';
                wait until rising_edge(Clk);
                In_Valid <= '0';

                -- Read and verify selective errors
                Out_Ready <= '1';
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#01#, Width_g), "Mixed word1 data");
                check_equal(Out_EccSec, '0', "Mixed word1 EccSec");
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#02#, Width_g), "Mixed word2 data");
                check_equal(Out_EccSec, '1', "Mixed word2 EccSec");
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#03#, Width_g), "Mixed word3 data");
                check_equal(Out_EccSec, '0', "Mixed word3 EccSec");

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
                    check_equal(Out_EccSec, '0', "Drain EccSec " & integer'image(i));
                end loop;

            -- SEC across every codeword bit position (full bit-by-bit sweep)
            elsif run("SecAllBits") then
                Out_Ready <= '1';
                for bitIdx in 0 to CodewordWidth_c - 1 loop
                    wait until rising_edge(Clk);
                    In_Data       <= toUslv(16#A5#, Width_g);
                    In_Valid      <= '1';
                    In_ErrInj_BitFlip <= singleBit(bitIdx);
                    In_ErrInj_Valid   <= '1';
                    wait until rising_edge(Clk);
                    In_Valid      <= '0';
                    In_ErrInj_BitFlip <= (others => '0');
                    In_ErrInj_Valid   <= '0';
                    wait until rising_edge(Clk) and Out_Valid = '1';
                    check_equal(Out_Data, toUslv(16#A5#, Width_g),
                                "SecAllBits data flip " & integer'image(bitIdx));
                    check_equal(Out_EccSec, '1', "SecAllBits EccSec flip " & integer'image(bitIdx));
                    check_equal(Out_EccDed, '0', "SecAllBits EccDed flip " & integer'image(bitIdx));
                end loop;

            -- DED across a representative sample of bit pairs
            elsif run("DedSampledPairs") then
                Out_Ready <= '1';
                for pair in 0 to 4 loop
                    wait until rising_edge(Clk);
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
                    wait until rising_edge(Clk);
                    In_Valid      <= '0';
                    In_ErrInj_BitFlip <= (others => '0');
                    In_ErrInj_Valid   <= '0';
                    wait until rising_edge(Clk) and Out_Valid = '1';
                    check_equal(Out_EccSec, '0', "DedPair EccSec pair " & integer'image(pair));
                    check_equal(Out_EccDed, '1', "DedPair EccDed pair " & integer'image(pair));
                end loop;

            end if;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

end architecture;

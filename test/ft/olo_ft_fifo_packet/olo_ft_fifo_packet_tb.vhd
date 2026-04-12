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
entity olo_ft_fifo_packet_tb is
    generic (
        runner_cfg    : string;
        Width_g       : positive range 5 to 128 := 32;
        FeatureSet_g  : string                  := "FULL";
        EccPipeline_g : natural range 0 to 1    := 0
    );
end entity;

architecture sim of olo_ft_fifo_packet_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c : time    := 10 ns;
    constant Depth_c     : natural := 64;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk           : std_logic                                              := '0';
    signal Rst           : std_logic                                              := '1';
    signal In_Valid      : std_logic                                              := '0';
    signal In_Ready      : std_logic;
    signal In_Data       : std_logic_vector(Width_g - 1 downto 0)                 := (others => '0');
    signal In_Last       : std_logic                                              := '0';
    signal In_Drop       : std_logic                                              := '0';
    signal In_IsDropped  : std_logic;
    signal In_EccBitFlip : std_logic_vector(1 downto 0)                           := "00";
    signal Out_Valid     : std_logic;
    signal Out_Ready     : std_logic                                              := '0';
    signal Out_Data      : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Size      : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);
    signal Out_Last      : std_logic;
    signal Out_Next      : std_logic                                              := '0';
    signal Out_Repeat    : std_logic                                              := '0';
    signal Out_SecErr    : std_logic;
    signal Out_DedErr    : std_logic;
    signal PacketLevel   : std_logic_vector(log2ceil(17 + 1) - 1 downto 0);
    signal FreeWords     : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_fifo_packet
        generic map (
            Width_g       => Width_g,
            Depth_g       => Depth_c,
            FeatureSet_g  => FeatureSet_g,
            EccPipeline_g => EccPipeline_g
        )
        port map (
            Clk           => Clk,
            Rst           => Rst,
            In_Valid      => In_Valid,
            In_Ready      => In_Ready,
            In_Data       => In_Data,
            In_Last       => In_Last,
            In_Drop       => In_Drop,
            In_IsDropped  => In_IsDropped,
            In_EccBitFlip => In_EccBitFlip,
            Out_Valid     => Out_Valid,
            Out_Ready     => Out_Ready,
            Out_Data      => Out_Data,
            Out_Size      => Out_Size,
            Out_Last      => Out_Last,
            Out_Next      => Out_Next,
            Out_Repeat    => Out_Repeat,
            Out_SecErr    => Out_SecErr,
            Out_DedErr    => Out_DedErr,
            PacketLevel   => PacketLevel,
            FreeWords     => FreeWords
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
            wait until rising_edge(Clk);

            -- Basic packet write and read
            if run("Basic") then
                -- Write a 3-word packet
                for i in 1 to 3 loop
                    wait until rising_edge(Clk);
                    In_Data  <= toUslv(i * 10, Width_g);
                    In_Valid <= '1';
                    if i = 3 then
                        In_Last <= '1';
                    else
                        In_Last <= '0';
                    end if;
                end loop;
                wait until rising_edge(Clk);
                In_Valid <= '0';
                In_Last  <= '0';
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);

                -- Read and verify packet
                Out_Ready <= '1';
                for i in 1 to 3 loop
                    wait until rising_edge(Clk) and Out_Valid = '1';
                    check_equal(Out_Data, toUslv(i * 10, Width_g), "Basic data " & integer'image(i));
                    check_equal(Out_SecErr, '0', "Basic SecErr " & integer'image(i));
                    check_equal(Out_DedErr, '0', "Basic DedErr " & integer'image(i));
                    if i = 3 then
                        check_equal(Out_Last, '1', "Basic Last on word 3");
                    else
                        check_equal(Out_Last, '0', "Basic Last=0 on word " & integer'image(i));
                    end if;
                end loop;

            -- Single bit error injection on packet data
            elsif run("SecErr") then
                -- Write a 2-word packet with error on word 1
                wait until rising_edge(Clk);
                In_Data       <= toUslv(16#AB#, Width_g);
                In_Valid      <= '1';
                In_Last       <= '0';
                In_EccBitFlip <= "01";
                wait until rising_edge(Clk);
                In_Data       <= toUslv(16#CD#, Width_g);
                In_Last       <= '1';
                In_EccBitFlip <= "00";
                wait until rising_edge(Clk);
                In_Valid <= '0';
                In_Last  <= '0';
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);

                -- Read and verify
                Out_Ready <= '1';
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#AB#, Width_g), "Sec word1 data");
                check_equal(Out_SecErr, '1', "Sec word1 SecErr");
                check_equal(Out_DedErr, '0', "Sec word1 DedErr");
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_Data, toUslv(16#CD#, Width_g), "Sec word2 data");
                check_equal(Out_SecErr, '0', "Sec word2 SecErr");
                check_equal(Out_Last, '1', "Sec word2 Last");

            -- Double bit error detection
            elsif run("DedErr") then
                -- Write single-word packet with double error
                wait until rising_edge(Clk);
                In_Data       <= toUslv(16#EF#, Width_g);
                In_Valid      <= '1';
                In_Last       <= '1';
                In_EccBitFlip <= "11";
                wait until rising_edge(Clk);
                In_Valid      <= '0';
                In_Last       <= '0';
                In_EccBitFlip <= "00";
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);

                -- Read and verify
                Out_Ready <= '1';
                wait until rising_edge(Clk) and Out_Valid = '1';
                check_equal(Out_SecErr, '0', "Ded SecErr");
                check_equal(Out_DedErr, '1', "Ded DedErr");
                check_equal(Out_Last, '1', "Ded Last");

            end if;

        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture;

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
entity olo_ft_ram_tdp_tb is
    generic (
        runner_cfg    : string;
        Width_g       : positive range 5 to 128 := 32;
        RamBehavior_g : string                  := "RBW";
        RdLatency_g   : positive range 1 to 2   := 1;
        EccPipeline_g : natural range 0 to 1    := 0
    );
end entity;

architecture sim of olo_ft_ram_tdp_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkAPeriod_c : time := 10 ns;
    constant ClkBPeriod_c : time := 33.3 ns;

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
        address       : natural;
        data          : natural;
        flipBits      : std_logic_vector(1 downto 0);
        signal Clk    : in std_logic;
        signal Addr   : out std_logic_vector;
        signal WrData : out std_logic_vector;
        signal WrEna  : out std_logic;
        signal WrFlip : out std_logic_vector) is
    begin
        wait until rising_edge(Clk);
        Addr   <= toUslv(address, Addr'length);
        WrData <= toUslv(data, WrData'length);
        WrEna  <= '1';
        WrFlip <= flipBits;
        wait until rising_edge(Clk);
        WrEna  <= '0';
        WrFlip <= "00";
        Addr   <= toUslv(0, Addr'length);
        WrData <= toUslv(0, WrData'length);
    end procedure;

    procedure checkEcc (
        address       : natural;
        data          : natural;
        expSecErr     : std_logic;
        expDedErr     : std_logic;
        signal Clk    : in std_logic;
        signal Addr   : out std_logic_vector;
        signal RdData : in std_logic_vector;
        signal SecErr : in std_logic;
        signal DedErr : in std_logic;
        message       : string) is
    begin
        wait until rising_edge(Clk);
        Addr <= toUslv(address, Addr'length);
        wait until rising_edge(Clk); -- Address sampled
        Addr <= toUslv(0, Addr'length);

        -- Wait for read data to arrive
        for i in 1 to RdLatency_g + EccPipeline_g loop
            wait until rising_edge(Clk);
        end loop;

        check_equal(RdData, toUslv(data, RdData'length), message & " data");
        check_equal(SecErr, expSecErr, message & " SecErr");
        check_equal(DedErr, expDedErr, message & " DedErr");
    end procedure;

    procedure checkDedOnly (
        address       : natural;
        expSecErr     : std_logic;
        expDedErr     : std_logic;
        signal Clk    : in std_logic;
        signal Addr   : out std_logic_vector;
        signal SecErr : in std_logic;
        signal DedErr : in std_logic;
        message       : string) is
    begin
        wait until rising_edge(Clk);
        Addr <= toUslv(address, Addr'length);
        wait until rising_edge(Clk); -- Address sampled
        Addr <= toUslv(0, Addr'length);

        -- Wait for read data to arrive
        for i in 1 to RdLatency_g + EccPipeline_g loop
            wait until rising_edge(Clk);
        end loop;

        check_equal(SecErr, expSecErr, message & " SecErr");
        check_equal(DedErr, expDedErr, message & " DedErr");
    end procedure;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal A_Clk           : std_logic                                := '0';
    signal A_Addr          : std_logic_vector(7 downto 0);
    signal A_WrEna         : std_logic                                := '0';
    signal A_WrData        : std_logic_vector(Width_g - 1 downto 0);
    signal A_WrEccBitFlip  : std_logic_vector(1 downto 0)             := "00";
    signal A_RdData        : std_logic_vector(Width_g - 1 downto 0);
    signal A_RdSecErr      : std_logic;
    signal A_RdDedErr      : std_logic;
    signal B_Clk           : std_logic                                := '0';
    signal B_Addr          : std_logic_vector(7 downto 0);
    signal B_WrEna         : std_logic                                := '0';
    signal B_WrData        : std_logic_vector(Width_g - 1 downto 0);
    signal B_WrEccBitFlip  : std_logic_vector(1 downto 0)             := "00";
    signal B_RdData        : std_logic_vector(Width_g - 1 downto 0);
    signal B_RdSecErr      : std_logic;
    signal B_RdDedErr      : std_logic;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_ram_tdp
        generic map (
            Depth_g       => 200,
            Width_g       => Width_g,
            RamBehavior_g => RamBehavior_g,
            RdLatency_g   => RdLatency_g,
            EccPipeline_g => EccPipeline_g
        )
        port map (
            A_Clk          => A_Clk,
            A_Addr         => A_Addr,
            A_WrEna        => A_WrEna,
            A_WrData       => A_WrData,
            A_WrEccBitFlip => A_WrEccBitFlip,
            A_RdData       => A_RdData,
            A_RdSecErr     => A_RdSecErr,
            A_RdDedErr     => A_RdDedErr,
            B_Clk          => B_Clk,
            B_Addr         => B_Addr,
            B_WrEna        => B_WrEna,
            B_WrData       => B_WrData,
            B_WrEccBitFlip => B_WrEccBitFlip,
            B_RdData       => B_RdData,
            B_RdSecErr     => B_RdSecErr,
            B_RdDedErr     => B_RdDedErr
        );

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    A_Clk <= not A_Clk after 0.5 * ClkAPeriod_c;
    B_Clk <= not B_Clk after 0.5 * ClkBPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 1 ms);

    p_control : process is
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Wait for some time
            wait for 1 us;

            -- Basic write and read, no errors expected
            if run("BasicA-A") then
                write(1, 5, A_Clk, A_Addr, A_WrData, A_WrEna);
                write(2, 6, A_Clk, A_Addr, A_WrData, A_WrEna);
                write(3, 7, A_Clk, A_Addr, A_WrData, A_WrEna);
                checkEcc(1, 5, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "A-A 1=5");
                checkEcc(2, 6, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "A-A 2=6");
                checkEcc(3, 7, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "A-A 3=7");
                -- Re-read
                checkEcc(1, 5, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "A-A re-read 1=5");

            elsif run("BasicB-B") then
                write(1, 5, B_Clk, B_Addr, B_WrData, B_WrEna);
                write(2, 6, B_Clk, B_Addr, B_WrData, B_WrEna);
                write(3, 7, B_Clk, B_Addr, B_WrData, B_WrEna);
                checkEcc(1, 5, '0', '0', B_Clk, B_Addr, B_RdData, B_RdSecErr, B_RdDedErr, "B-B 1=5");
                checkEcc(2, 6, '0', '0', B_Clk, B_Addr, B_RdData, B_RdSecErr, B_RdDedErr, "B-B 2=6");
                checkEcc(3, 7, '0', '0', B_Clk, B_Addr, B_RdData, B_RdSecErr, B_RdDedErr, "B-B 3=7");

            -- Cross-port: write A, read B
            elsif run("BasicA-B") then
                write(1, 5, A_Clk, A_Addr, A_WrData, A_WrEna);
                write(2, 6, A_Clk, A_Addr, A_WrData, A_WrEna);
                checkEcc(1, 5, '0', '0', B_Clk, B_Addr, B_RdData, B_RdSecErr, B_RdDedErr, "A-B 1=5");
                checkEcc(2, 6, '0', '0', B_Clk, B_Addr, B_RdData, B_RdSecErr, B_RdDedErr, "A-B 2=6");

            -- Cross-port: write B, read A
            elsif run("BasicB-A") then
                write(1, 5, B_Clk, B_Addr, B_WrData, B_WrEna);
                write(2, 6, B_Clk, B_Addr, B_WrData, B_WrEna);
                checkEcc(1, 5, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "B-A 1=5");
                checkEcc(2, 6, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "B-A 2=6");

            -- Various data patterns without errors
            elsif run("NoError-Patterns") then
                write(10, 16#AA#, A_Clk, A_Addr, A_WrData, A_WrEna);
                write(11, 16#55#, A_Clk, A_Addr, A_WrData, A_WrEna);
                write(12, 0, A_Clk, A_Addr, A_WrData, A_WrEna);
                checkEcc(10, 16#AA#, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "NoErr AA");
                checkEcc(11, 16#55#, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "NoErr 55");
                checkEcc(12, 0, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "NoErr 00");
                -- Cross-port
                checkEcc(10, 16#AA#, '0', '0', B_Clk, B_Addr, B_RdData, B_RdSecErr, B_RdDedErr, "NoErr AA B");

            -- Single bit error injection and correction via port A
            elsif run("SecErr-PortA") then
                -- Inject single-bit flip (bit 0)
                writeWithFlip(20, 16#AB#, "01", A_Clk, A_Addr, A_WrData, A_WrEna, A_WrEccBitFlip);
                -- Read back: data corrected, SecErr flagged
                checkEcc(20, 16#AB#, '1', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "Sec A-A flip0");
                -- Cross-port read
                checkEcc(20, 16#AB#, '1', '0', B_Clk, B_Addr, B_RdData, B_RdSecErr, B_RdDedErr, "Sec A-B flip0");
                -- Inject single-bit flip (bit 1)
                writeWithFlip(21, 16#CD#, "10", A_Clk, A_Addr, A_WrData, A_WrEna, A_WrEccBitFlip);
                checkEcc(21, 16#CD#, '1', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "Sec A-A flip1");

            -- Single bit error injection via port B
            elsif run("SecErr-PortB") then
                writeWithFlip(25, 16#EF#, "01", B_Clk, B_Addr, B_WrData, B_WrEna, B_WrEccBitFlip);
                checkEcc(25, 16#EF#, '1', '0', B_Clk, B_Addr, B_RdData, B_RdSecErr, B_RdDedErr, "Sec B-B");
                checkEcc(25, 16#EF#, '1', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "Sec B-A");

            -- Overwrite corrects error
            elsif run("SecErr-Overwrite") then
                writeWithFlip(30, 16#AB#, "01", A_Clk, A_Addr, A_WrData, A_WrEna, A_WrEccBitFlip);
                checkEcc(30, 16#AB#, '1', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "Sec before overwrite");
                -- Overwrite with clean data
                write(30, 16#AB#, A_Clk, A_Addr, A_WrData, A_WrEna);
                checkEcc(30, 16#AB#, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "Sec after overwrite");

            -- Double bit error detection
            elsif run("DedErr") then
                -- Inject double-bit flip
                writeWithFlip(35, 16#EF#, "11", A_Clk, A_Addr, A_WrData, A_WrEna, A_WrEccBitFlip);
                -- Read back: DedErr flagged, data unreliable
                checkDedOnly(35, '0', '1', A_Clk, A_Addr, A_RdSecErr, A_RdDedErr, "Ded A");
                -- Cross-port
                checkDedOnly(35, '0', '1', B_Clk, B_Addr, B_RdSecErr, B_RdDedErr, "Ded B");
                -- Overwrite clears error
                write(35, 16#EF#, A_Clk, A_Addr, A_WrData, A_WrEna);
                checkEcc(35, 16#EF#, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "Ded cleared");

            -- Multiple addresses: errors don't cross-contaminate
            elsif run("MultiAddr") then
                write(40, 16#01#, A_Clk, A_Addr, A_WrData, A_WrEna);
                write(41, 16#02#, A_Clk, A_Addr, A_WrData, A_WrEna);
                write(42, 16#03#, A_Clk, A_Addr, A_WrData, A_WrEna);
                -- Inject single error at address 41 only
                writeWithFlip(41, 16#02#, "01", A_Clk, A_Addr, A_WrData, A_WrEna, A_WrEccBitFlip);
                checkEcc(40, 16#01#, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "Multi addr40 clean");
                checkEcc(41, 16#02#, '1', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "Multi addr41 sec");
                checkEcc(42, 16#03#, '0', '0', A_Clk, A_Addr, A_RdData, A_RdSecErr, A_RdDedErr, "Multi addr42 clean");

            end if;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

end architecture;

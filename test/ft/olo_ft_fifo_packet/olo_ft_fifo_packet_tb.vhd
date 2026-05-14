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
    context vunit_lib.com_context;
    context vunit_lib.vc_context;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;
    use olo.olo_ft_pkg_ecc.all;

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
    constant ClkPeriod_c     : time     := 10 ns;
    constant Depth_c         : natural  := 64;
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);

    -----------------------------------------------------------------------------------------------
    -- Verification components.
    --   Master drives the user-facing AXI-S input including TLAST (= In_Last).
    --   Slave samples (Out_Data, Out_Last, EccSec, EccDed); tuser = Sec & Ded.
    --   Stall configs on both sides keep back-pressure exercised on every case.
    -----------------------------------------------------------------------------------------------
    constant AxisMaster_c : axi_stream_master_t := new_axi_stream_master (
        data_length  => Width_g,
        stall_config => new_stall_config(0.2, 0, 3)
    );
    constant AxisSlave_c  : axi_stream_slave_t  := new_axi_stream_slave (
        data_length  => Width_g,
        user_length  => 2,
        stall_config => new_stall_config(0.2, 0, 3)
    );

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk               : std_logic                                       := '0';
    signal Rst               : std_logic                                       := '1';
    signal In_Valid          : std_logic;
    signal In_Ready          : std_logic;
    signal In_Data           : std_logic_vector(Width_g - 1 downto 0);
    signal In_Last           : std_logic;
    signal In_Drop           : std_logic                                       := '0';
    signal In_IsDropped      : std_logic;
    signal In_ErrInj_BitFlip : std_logic_vector(CodewordWidth_c - 1 downto 0)  := (others => '0');
    signal In_ErrInj_Valid   : std_logic                                       := '0';
    signal Out_Valid         : std_logic;
    signal Out_Ready         : std_logic;
    signal Out_Data          : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Size          : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);
    signal Out_Last          : std_logic;
    signal Out_Next          : std_logic                                       := '0';
    signal Out_Repeat        : std_logic                                       := '0';
    signal Out_EccSec        : std_logic;
    signal Out_EccDed        : std_logic;
    signal Out_TUser         : std_logic_vector(1 downto 0);
    signal PacketLevel       : std_logic_vector(log2ceil(17 + 1) - 1 downto 0);
    signal FreeWords         : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);

    -----------------------------------------------------------------------------------------------
    -- Helpers
    -----------------------------------------------------------------------------------------------
    -- Push a single beat. Drives TLAST = '1' on the end-of-packet beat. When FlipBits has any
    -- bit set, the codec's injection latch is loaded via a one-cycle ErrInj_Valid pulse before
    -- the push, so exactly the next handshake applies the pattern (and the latch self-clears).
    procedure pushBeat (
        signal   net          : inout network_t;
        signal   clk_sig      : in    std_logic;
        signal   injBitFlip   : out   std_logic_vector;
        signal   injValid     : out   std_logic;
        constant Data_v       : in    std_logic_vector;
        constant FlipBits     : in    std_logic_vector;
        constant Last_b       : in    boolean) is
        variable Inject_v : boolean   := false;
        variable Last_v   : std_logic := '0';
    begin
        for i in FlipBits'range loop
            if FlipBits(i) = '1' then
                Inject_v := true;
            end if;
        end loop;

        if Last_b then
            Last_v := '1';
        end if;

        if Inject_v then
            wait_until_idle(net, as_sync(AxisMaster_c));
            wait until rising_edge(clk_sig);

            injBitFlip <= FlipBits;
            injValid   <= '1';
            wait until rising_edge(clk_sig);
            injValid   <= '0';

            push_axi_stream(net, AxisMaster_c, Data_v, tlast => Last_v);

            wait_until_idle(net, as_sync(AxisMaster_c));
            wait until rising_edge(clk_sig);
            injBitFlip <= (others => '0');
        else
            push_axi_stream(net, AxisMaster_c, Data_v, tlast => Last_v);
        end if;
    end procedure;

    -- Build the (Data, tlast, tuser) the slave will see for a (Data, FlipBits, Last) tuple and
    -- queue the corresponding check_axi_stream expectation.
    procedure expectBeat (
        signal   net      : inout network_t;
        constant Data_v   : in    std_logic_vector;
        constant FlipBits : in    std_logic_vector;
        constant Last_b   : in    boolean;
        constant Msg_c    : in    string) is
        variable Codeword_v : std_logic_vector(CodewordWidth_c - 1 downto 0);
        variable SynPar_v   : std_logic_vector(eccParityBits(Width_g) downto 0);
        variable ExpData_v  : std_logic_vector(Width_g - 1 downto 0);
        variable ExpTUser_v : std_logic_vector(1 downto 0);
        variable ExpLast_v  : std_logic := '0';
    begin
        Codeword_v  := eccEncode(Data_v) xor FlipBits;
        SynPar_v    := eccSyndromeAndParity(Codeword_v, Width_g);
        ExpData_v   := eccCorrectData(Codeword_v, SynPar_v, Width_g);
        ExpTUser_v  := eccSecError(SynPar_v) & eccDedError(SynPar_v);
        if Last_b then
            ExpLast_v := '1';
        end if;

        check_axi_stream(net, AxisSlave_c, ExpData_v, tlast => ExpLast_v, tuser => ExpTUser_v,
            msg => Msg_c, blocking => false);
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 5 ms);

    p_control : process is
        variable Flip_v : std_logic_vector(CodewordWidth_c - 1 downto 0);
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            In_ErrInj_BitFlip <= (others => '0');
            In_ErrInj_Valid   <= '0';
            In_Drop           <= '0';
            wait until rising_edge(Clk);
            Rst <= '1';
            wait for 200 ns;
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            ---------------------------------------------------------------------------------------
            if run("Basic") then
                -- Three-word packet, no errors. TLAST asserted on the third beat.
                Flip_v := (others => '0');
                pushBeat(net, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(10, Width_g), Flip_v, false);
                pushBeat(net, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(20, Width_g), Flip_v, false);
                pushBeat(net, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(30, Width_g), Flip_v, true);
                expectBeat(net, toUslv(10, Width_g), Flip_v, false, "Basic[0]");
                expectBeat(net, toUslv(20, Width_g), Flip_v, false, "Basic[1]");
                expectBeat(net, toUslv(30, Width_g), Flip_v, true,  "Basic[2] last");

            ---------------------------------------------------------------------------------------
            elsif run("EccSec") then
                -- Two-word packet, single-bit flip on the first word.
                pushBeat(net, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#AB#, Width_g),
                         setBits(0, CodewordWidth_c), false);
                pushBeat(net, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#CD#, Width_g),
                         (Flip_v'range => '0'), true);
                expectBeat(net, toUslv(16#AB#, Width_g), setBits(0, CodewordWidth_c), false, "Sec[0]");
                expectBeat(net, toUslv(16#CD#, Width_g), (Flip_v'range => '0'),       true,  "Sec[1] last");

            ---------------------------------------------------------------------------------------
            elsif run("EccDed") then
                -- Single-word packet with double-bit flip.
                Flip_v := setBits((0, 1), CodewordWidth_c);
                pushBeat(net, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#EF#, Width_g),
                         Flip_v, true);
                expectBeat(net, toUslv(16#EF#, Width_g), Flip_v, true, "Ded[0] last");

            ---------------------------------------------------------------------------------------
            elsif run("SecAllBits") then
                -- Every codeword bit position, one-word packets.
                for bitIdx in 0 to CodewordWidth_c - 1 loop
                    Flip_v := setBits(bitIdx, CodewordWidth_c);
                    pushBeat(net, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#A5#, Width_g),
                             Flip_v, true);
                    expectBeat(net, toUslv(16#A5#, Width_g), Flip_v, true,
                        "SecAllBits flip " & integer'image(bitIdx));
                    wait_until_idle(net, as_sync(AxisSlave_c));
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("DedSampledPairs") then

                for pair in 0 to 4 loop

                    case pair is
                        when 0      => Flip_v := setBits((0, 1),                              CodewordWidth_c);
                        when 1      => Flip_v := setBits((0, CodewordWidth_c - 1),            CodewordWidth_c);
                        when 2      => Flip_v := setBits((1, 2),                              CodewordWidth_c);
                        when 3      => Flip_v := setBits((2, 5),                              CodewordWidth_c);
                        when others => Flip_v := setBits((CodewordWidth_c / 2,
                                                          CodewordWidth_c / 2 + 1), CodewordWidth_c);
                    end case;

                    pushBeat(net, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#5A#, Width_g),
                             Flip_v, true);
                    expectBeat(net, toUslv(16#5A#, Width_g), Flip_v, true,
                        "DedPair " & integer'image(pair));
                    wait_until_idle(net, as_sync(AxisSlave_c));
                end loop;

            end if;

            wait_until_idle(net, as_sync(AxisMaster_c));
            wait_until_idle(net, as_sync(AxisSlave_c));
            wait for 1 us;

        end loop;

        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    Out_TUser <= Out_EccSec & Out_EccDed;

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
            Clk               => Clk,
            Rst               => Rst,
            In_Valid          => In_Valid,
            In_Ready          => In_Ready,
            In_Data           => In_Data,
            In_Last           => In_Last,
            In_Drop           => In_Drop,
            In_IsDropped      => In_IsDropped,
            In_ErrInj_BitFlip => In_ErrInj_BitFlip,
            In_ErrInj_Valid   => In_ErrInj_Valid,
            Out_Valid         => Out_Valid,
            Out_Ready         => Out_Ready,
            Out_Data          => Out_Data,
            Out_Size          => Out_Size,
            Out_Last          => Out_Last,
            Out_Next          => Out_Next,
            Out_Repeat        => Out_Repeat,
            Out_EccSec        => Out_EccSec,
            Out_EccDed        => Out_EccDed,
            PacketLevel       => PacketLevel,
            FreeWords         => FreeWords
        );

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    vc_master : entity vunit_lib.axi_stream_master
        generic map (
            Master => AxisMaster_c
        )
        port map (
            AClk   => Clk,
            TValid => In_Valid,
            TReady => In_Ready,
            TData  => In_Data,
            TLast  => In_Last
        );

    vc_slave : entity vunit_lib.axi_stream_slave
        generic map (
            Slave => AxisSlave_c
        )
        port map (
            AClk   => Clk,
            TValid => Out_Valid,
            TReady => Out_Ready,
            TData  => Out_Data,
            TLast  => Out_Last,
            TUser  => Out_TUser
        );

end architecture;

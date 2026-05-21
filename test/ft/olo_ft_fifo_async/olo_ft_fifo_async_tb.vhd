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
entity olo_ft_fifo_async_tb is
    generic (
        runner_cfg     : string;
        Width_g        : positive range 5 to 128 := 32;
        Optimization_g : string                  := "SPEED";
        EccPipeline_g  : natural range 0 to 2    := 0
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
    -- Verification components
    --   Master operates on In_Clk; slave on Out_Clk. Both carry a non-zero stall probability so
    --   the codec's AXI-S handshake is exercised under stalls in every test case.
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
    signal In_Clk            : std_logic                                       := '0';
    signal In_Rst            : std_logic                                       := '1';
    signal In_RstOut         : std_logic;
    signal In_Data           : std_logic_vector(Width_g - 1 downto 0);
    signal In_Valid          : std_logic;
    signal In_Ready          : std_logic;
    signal In_ErrInj_BitFlip : std_logic_vector(CodewordWidth_c - 1 downto 0)  := (others => '0');
    signal In_ErrInj_Valid   : std_logic                                       := '0';
    signal In_Level          : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);
    signal Out_Clk           : std_logic                                       := '0';
    signal Out_Rst           : std_logic                                       := '0';
    signal Out_RstOut        : std_logic;
    signal Out_Data          : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Valid         : std_logic;
    signal Out_Ready         : std_logic;
    signal Out_EccSec        : std_logic;
    signal Out_EccDed        : std_logic;
    signal Out_TUser         : std_logic_vector(1 downto 0);
    signal Out_Level         : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);

    -----------------------------------------------------------------------------------------------
    -- Helpers
    -----------------------------------------------------------------------------------------------
    procedure pushBeat (
        signal   net          : inout network_t;
        signal   clk_sig      : in    std_logic;
        signal   injBitFlip   : out   std_logic_vector;
        signal   injValid     : out   std_logic;
        constant Data_v       : in    std_logic_vector;
        constant FlipBits     : in    std_logic_vector) is
        variable Inject_v : boolean := false;
    begin
        for i in FlipBits'range loop
            if FlipBits(i) = '1' then
                Inject_v := true;
            end if;
        end loop;

        if Inject_v then
            wait_until_idle(net, as_sync(AxisMaster_c));
            wait until rising_edge(clk_sig);
            injBitFlip <= FlipBits;
            injValid   <= '1';
            wait until rising_edge(clk_sig);
            injValid   <= '0';

            push_axi_stream(net, AxisMaster_c, Data_v);
            wait_until_idle(net, as_sync(AxisMaster_c));
            wait until rising_edge(clk_sig);
            injBitFlip <= (injBitFlip'range => '0');
        else
            push_axi_stream(net, AxisMaster_c, Data_v);
        end if;
    end procedure;

    procedure expectBeat (
        signal   net      : inout network_t;
        constant Data_v   : in    std_logic_vector;
        constant FlipBits : in    std_logic_vector;
        constant Msg_c    : in    string) is
        variable Codeword_v : std_logic_vector(CodewordWidth_c - 1 downto 0);
        variable SynPar_v   : std_logic_vector(eccParityBits(Width_g) downto 0);
        variable ExpData_v  : std_logic_vector(Width_g - 1 downto 0);
        variable ExpTUser_v : std_logic_vector(1 downto 0);
    begin
        Codeword_v  := eccEncode(Data_v) xor FlipBits;
        SynPar_v    := eccSyndromeAndParity(Codeword_v, Width_g);
        ExpData_v   := eccCorrectData(Codeword_v, SynPar_v, Width_g);
        ExpTUser_v  := eccSecError(SynPar_v) & eccDedError(SynPar_v);

        check_axi_stream(net, AxisSlave_c, ExpData_v, tuser => ExpTUser_v,
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

            In_ErrInj_BitFlip <= (others => '0');
            In_ErrInj_Valid   <= '0';
            wait until rising_edge(In_Clk);
            In_Rst  <= '1';
            Out_Rst <= '1';
            wait for 1 us;
            wait until rising_edge(In_Clk);
            In_Rst <= '0';
            wait until rising_edge(Out_Clk);
            Out_Rst <= '0';
            wait for 1 us;
            wait until rising_edge(In_Clk);

            ---------------------------------------------------------------------------------------
            if run("Basic") then
                Flip_v := (others => '0');
                pushBeat(net, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(10, Width_g), Flip_v);
                pushBeat(net, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(20, Width_g), Flip_v);
                pushBeat(net, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(30, Width_g), Flip_v);
                expectBeat(net, toUslv(10, Width_g), Flip_v, "Basic[0]");
                expectBeat(net, toUslv(20, Width_g), Flip_v, "Basic[1]");
                expectBeat(net, toUslv(30, Width_g), Flip_v, "Basic[2]");

            ---------------------------------------------------------------------------------------
            elsif run("EccSec") then
                Flip_v := setBits(0, CodewordWidth_c);
                pushBeat(net, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#AB#, Width_g), Flip_v);
                expectBeat(net, toUslv(16#AB#, Width_g), Flip_v, "EccSec corrected");

            ---------------------------------------------------------------------------------------
            elsif run("EccDed") then
                Flip_v := setBits((0, 1), CodewordWidth_c);
                pushBeat(net, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#EF#, Width_g), Flip_v);
                expectBeat(net, toUslv(16#EF#, Width_g), Flip_v, "EccDed detected");

            ---------------------------------------------------------------------------------------
            elsif run("BackToBack") then
                -- 64 beats (2x depth) across the clock-domain crossing under stalls
                Flip_v := (others => '0');
                for i in 0 to 63 loop
                    push_axi_stream(net, AxisMaster_c, toUslv(i + 1, Width_g));
                end loop;
                for i in 0 to 63 loop
                    check_axi_stream(net, AxisSlave_c, toUslv(i + 1, Width_g), tuser => "00",
                        msg => "BackToBack " & integer'image(i), blocking => false);
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("SecAllBits") then

                for bitIdx in 0 to CodewordWidth_c - 1 loop
                    Flip_v := setBits(bitIdx, CodewordWidth_c);
                    pushBeat(net, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid,
                        toUslv(16#A5#, Width_g), Flip_v);
                    expectBeat(net, toUslv(16#A5#, Width_g), Flip_v,
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

                    pushBeat(net, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid,
                        toUslv(16#5A#, Width_g), Flip_v);
                    expectBeat(net, toUslv(16#5A#, Width_g), Flip_v,
                        "DedPair " & integer'image(pair));
                    wait_until_idle(net, as_sync(AxisSlave_c));
                end loop;

            end if;

            wait_until_idle(net, as_sync(AxisMaster_c));
            wait_until_idle(net, as_sync(AxisSlave_c));
            wait for 2 us;

        end loop;

        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clocks
    -----------------------------------------------------------------------------------------------
    In_Clk  <= not In_Clk  after 0.5 * InClkPeriod_c;
    Out_Clk <= not Out_Clk after 0.5 * OutClkPeriod_c;

    Out_TUser <= Out_EccSec & Out_EccDed;

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
            In_Clk            => In_Clk,
            In_Rst            => In_Rst,
            In_RstOut         => In_RstOut,
            In_Data           => In_Data,
            In_Valid          => In_Valid,
            In_Ready          => In_Ready,
            In_Level          => In_Level,
            Out_Clk           => Out_Clk,
            Out_Rst           => Out_Rst,
            Out_RstOut        => Out_RstOut,
            Out_Data          => Out_Data,
            Out_Valid         => Out_Valid,
            Out_Ready         => Out_Ready,
            Out_EccSec        => Out_EccSec,
            Out_EccDed        => Out_EccDed,
            Out_Level         => Out_Level,
            In_ErrInj_BitFlip => In_ErrInj_BitFlip,
            In_ErrInj_Valid   => In_ErrInj_Valid
        );

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    vc_master : entity vunit_lib.axi_stream_master
        generic map (
            Master => AxisMaster_c
        )
        port map (
            AClk   => In_Clk,
            TValid => In_Valid,
            TReady => In_Ready,
            TData  => In_Data
        );

    vc_slave : entity vunit_lib.axi_stream_slave
        generic map (
            Slave => AxisSlave_c
        )
        port map (
            AClk   => Out_Clk,
            TValid => Out_Valid,
            TReady => Out_Ready,
            TData  => Out_Data,
            TUser  => Out_TUser
        );

end architecture;

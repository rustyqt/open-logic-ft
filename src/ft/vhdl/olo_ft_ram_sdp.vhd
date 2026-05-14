---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected simple dual port RAM using SECDED (Single Error Correction,
-- Double Error Detection) Hamming code. Wraps olo_base_ram_sdp with a wider
-- internal word to store parity bits alongside data. The ECC is transparent
-- to the user: data is encoded on write and decoded/corrected on read.
--
-- When `Scrub_g = true`, an internal opportunistic memory scrubber walks the
-- address space autonomously. It uses cycles in which the user is not driving
-- the read or write port; user accesses are never stalled. If the user writes
-- to the address currently being scrubbed at any point between the scrubber's
-- read and writeback, the scrubber aborts its writeback so user data wins.
-- The scrubber only writes back on a corrected SEC (ON_ERROR policy); DED
-- reads are reported but not written back because the corrected codeword is
-- unreliable. Scrubbing requires `IsAsync_g = false` (a synchronous scrubber
-- FSM cannot reason about access patterns across two independent clocks).
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_ram_sdp.md
--
-- Note: The link points to the documentation of the latest release. If you
--       use an older version, the documentation might not match the code.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.olo_base_pkg_math.all;
    use work.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_ram_sdp is
    generic (
        Depth_g        : positive;
        Width_g        : positive;
        IsAsync_g      : boolean              := false;
        RamRdLatency_g : positive             := 1;
        RamStyle_g     : string               := "auto";
        RamBehavior_g  : string               := "RBW";
        EccPipeline_g  : natural range 0 to 2 := 0;
        Scrub_g        : boolean              := false
    );
    port (
        -- Clock and Reset
        Clk            : in    std_logic;
        Rst            : in    std_logic                                                := '0';
        Rd_Clk         : in    std_logic                                                := '0';
        Rd_Rst         : in    std_logic                                                := '0';
        -- Write Port
        Wr_Addr        : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Wr_Ena         : in    std_logic                                                := '1';
        Wr_Data        : in    std_logic_vector(Width_g - 1 downto 0);
        -- Read Port
        Rd_Addr        : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Rd_Ena         : in    std_logic                                                := '1';
        Rd_Data        : out   std_logic_vector(Width_g - 1 downto 0);
        Rd_Valid       : out   std_logic;
        Rd_EccSec      : out   std_logic;
        Rd_EccDed      : out   std_logic;
        -- Error Injection
        ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        ErrInj_Valid   : in    std_logic                                                := '0';
        -- Scrubber Status (tied to '0' when Scrub_g = false)
        Scrub_Active   : out   std_logic;
        Scrub_EccSec   : out   std_logic;
        Scrub_EccDed   : out   std_logic;
        Scrub_PassDone : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ram_sdp is

    constant CodewordWidth_c    : positive := eccCodewordWidth(Width_g);
    constant AddrWidth_c        : positive := log2ceil(Depth_g);
    constant TotalReadLatency_c : positive := RamRdLatency_g + EccPipeline_g;

    -- Codec / RAM datapath
    signal Wr_Codeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal Rd_Codeword : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- Read-clock muxing: in async mode use the user-supplied Rd_Clk / Rd_Rst, otherwise share
    -- the write clock + reset. (Scrub_g implies IsAsync_g = false, so the scrubber always runs
    -- on Clk / Rst regardless of which branch is taken.)
    signal RdClk : std_logic;
    signal RdRst : std_logic;

    -- Scrubber-driven request signals. Default to '0' so the Scrub_g = false case degenerates
    -- the muxes below to user-only behaviour without any extra generate-if.
    signal Scrub_Rd_Ena_i   : std_logic                                  := '0';
    signal Scrub_Rd_Addr_i  : std_logic_vector(AddrWidth_c - 1 downto 0) := (others => '0');
    signal Scrub_Wr_Ena_i   : std_logic                                  := '0';
    signal Scrub_Wr_Addr_i  : std_logic_vector(AddrWidth_c - 1 downto 0) := (others => '0');
    signal Scrub_Wr_Data_i  : std_logic_vector(Width_g - 1 downto 0)     := (others => '0');
    signal Scrub_Active_i   : std_logic                                  := '0';
    signal Scrub_EccSec_i   : std_logic                                  := '0';
    signal Scrub_EccDed_i   : std_logic                                  := '0';
    signal Scrub_PassDone_i : std_logic                                  := '0';

    -- Decoder outputs are tapped so the scrubber can observe the result of its own reads on the
    -- same cycle the user-facing Rd_Data is presented.
    signal Dec_Rd_Data   : std_logic_vector(Width_g - 1 downto 0);
    signal Dec_Rd_EccSec : std_logic;
    signal Dec_Rd_EccDed : std_logic;

    -- Muxed inputs to the encoder. Scrubber writes feed the encoder with their captured
    -- (already decoded) value so the codeword written back has fresh parity. Error injection is
    -- gated to the user side: a scrubber writeback never injects a flip.
    signal Enc_In_Data    : std_logic_vector(Width_g - 1 downto 0);
    signal Enc_In_Valid   : std_logic;
    signal Enc_In_FlipBits : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal Enc_In_FlipVld : std_logic;

    -- Muxed RAM port signals
    signal Ram_Wr_Addr : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal Ram_Wr_Ena  : std_logic;
    signal Ram_Rd_Addr : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal Ram_Rd_Ena  : std_logic;

    -- (delayed Ram_Rd_Ena) shift register on the read clock, depth = RamRdLatency_g, feeds
    -- decode.In_Valid. The EccPipeline_g portion of the read-valid path is owned by the decode
    -- entity natively.
    signal RdEnaPipe : std_logic_vector(1 to RamRdLatency_g) := (others => '0');

    -- User-only Rd_Valid pipeline. Tracks `Rd_Ena AND NOT Scrub_Rd_Ena_i` through the full
    -- `TotalReadLatency_c` so scrubber-owned read cycles do not pulse the user-facing Rd_Valid.
    -- Identical behaviour to the original `decode.Out_Valid -> Rd_Valid` path when
    -- Scrub_g = false (Scrub_Rd_Ena_i stays at '0' so the input equals Rd_Ena).
    signal UserRdValidPipe : std_logic_vector(1 to TotalReadLatency_c) := (others => '0');

begin

    -- Elaboration guard: opportunistic scrubbing is fundamentally synchronous; it observes user
    -- read/write activity on a single clock to pick idle cycles. Async clocks would require
    -- independent FSMs per clock domain plus a hazard exchange across the boundary.
    assert not (Scrub_g and IsAsync_g)
        report "olo_ft_ram_sdp: Scrub_g = true requires IsAsync_g = false"
        severity failure;

    -- Read clock / reset selection
    g_async : if IsAsync_g generate
        RdClk <= Rd_Clk;
        RdRst <= Rd_Rst;
    end generate;

    g_sync : if not IsAsync_g generate
        RdClk <= Clk;
        RdRst <= Rst;
    end generate;

    -- Optional opportunistic scrubber
    g_scrubber : if Scrub_g generate

        i_scrubber : entity work.olo_ft_ram_scrubber
            generic map (
                Depth_g            => Depth_g,
                Width_g            => Width_g,
                TotalReadLatency_g => TotalReadLatency_c
            )
            port map (
                Clk            => Clk,
                Rst            => Rst,
                User_Wr_Ena    => Wr_Ena,
                User_Wr_Addr   => Wr_Addr,
                User_Rd_Ena    => Rd_Ena,
                Ram_Rd_Data    => Dec_Rd_Data,
                Ram_Rd_EccSec  => Dec_Rd_EccSec,
                Ram_Rd_EccDed  => Dec_Rd_EccDed,
                Scrub_Rd_Ena   => Scrub_Rd_Ena_i,
                Scrub_Rd_Addr  => Scrub_Rd_Addr_i,
                Scrub_Wr_Ena   => Scrub_Wr_Ena_i,
                Scrub_Wr_Addr  => Scrub_Wr_Addr_i,
                Scrub_Wr_Data  => Scrub_Wr_Data_i,
                Scrub_Active   => Scrub_Active_i,
                Scrub_EccSec   => Scrub_EccSec_i,
                Scrub_EccDed   => Scrub_EccDed_i,
                Scrub_PassDone => Scrub_PassDone_i
            );

    end generate;

    -- Write-path mux: user wins (scrubber's FSM only asserts Scrub_Wr_Ena_i when Wr_Ena = '0',
    -- so the cases are mutually exclusive). When the scrubber drives the write, its captured
    -- decoded value is re-encoded with fresh parity by the codec; injection is suppressed.
    Enc_In_Data    <= Wr_Data        when Wr_Ena = '1' else Scrub_Wr_Data_i;
    Enc_In_Valid   <= Wr_Ena or Scrub_Wr_Ena_i;
    Enc_In_FlipBits <= ErrInj_BitFlip when Wr_Ena = '1' else (others => '0');
    Enc_In_FlipVld <= ErrInj_Valid   when Wr_Ena = '1' else '0';

    Ram_Wr_Addr <= Wr_Addr when Wr_Ena = '1' else Scrub_Wr_Addr_i;
    Ram_Wr_Ena  <= Wr_Ena or Scrub_Wr_Ena_i;

    -- Read-path mux: same priority rule. Scrubber only asserts Scrub_Rd_Ena_i when Rd_Ena = '0'.
    Ram_Rd_Addr <= Rd_Addr when Rd_Ena = '1' else Scrub_Rd_Addr_i;
    Ram_Rd_Ena  <= Rd_Ena or Scrub_Rd_Ena_i;

    -- Encode write data (codec owns the injection latch). UseReady_g=false because the RAM
    -- never backpressures the encoder.
    i_enc : entity work.olo_ft_ecc_encode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0,
            UseReady_g => false
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            In_Valid       => Enc_In_Valid,
            In_Ready       => open,
            In_Data        => Enc_In_Data,
            Out_Valid      => open,
            Out_Ready      => '1',
            Out_Codeword   => Wr_Codeword,
            ErrInj_BitFlip => Enc_In_FlipBits,
            ErrInj_Valid   => Enc_In_FlipVld
        );

    -- Internal RAM with codeword-wide word
    i_ram : entity work.olo_base_ram_sdp
        generic map (
            Depth_g       => Depth_g,
            Width_g       => CodewordWidth_c,
            IsAsync_g     => IsAsync_g,
            RdLatency_g   => RamRdLatency_g,
            RamStyle_g    => RamStyle_g,
            RamBehavior_g => RamBehavior_g
        )
        port map (
            Clk     => Clk,
            Wr_Addr => Ram_Wr_Addr,
            Wr_Ena  => Ram_Wr_Ena,
            Wr_Data => Wr_Codeword,
            Rd_Clk  => Rd_Clk,
            Rd_Addr => Ram_Rd_Addr,
            Rd_Ena  => Ram_Rd_Ena,
            Rd_Data => Rd_Codeword
        );

    -- Delay (muxed) Ram_Rd_Ena by RamRdLatency_g cycles to align with the codeword arriving at
    -- the RAM read port; feed that into the decode entity's In_Valid. The decoder absorbs the
    -- EccPipeline_g portion of the read latency natively.
    p_rd_ena_pipe : process (RdClk) is
    begin
        if rising_edge(RdClk) then
            if RdRst = '1' then
                RdEnaPipe <= (others => '0');
            else
                RdEnaPipe(1) <= Ram_Rd_Ena;

                for i in 2 to RamRdLatency_g loop
                    RdEnaPipe(i) <= RdEnaPipe(i - 1);
                end loop;

            end if;
        end if;
    end process;

    -- User-only Rd_Valid pipeline (depth = TotalReadLatency_c). Scrubber-owned read cycles are
    -- gated out at the input so Rd_Valid only pulses for cycles the user actually issued a read.
    p_user_rd_valid : process (RdClk) is
    begin
        if rising_edge(RdClk) then
            if RdRst = '1' then
                UserRdValidPipe <= (others => '0');
            else
                UserRdValidPipe(1) <= Rd_Ena and not Scrub_Rd_Ena_i;

                for i in 2 to TotalReadLatency_c loop
                    UserRdValidPipe(i) <= UserRdValidPipe(i - 1);
                end loop;

            end if;
        end if;
    end process;

    -- Decode read data (with optional pipeline)
    i_dec : entity work.olo_ft_ecc_decode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => EccPipeline_g,
            UseReady_g => false
        )
        port map (
            Clk            => RdClk,
            Rst            => RdRst,
            In_Valid       => RdEnaPipe(RamRdLatency_g),
            In_Ready       => open,
            In_Codeword    => Rd_Codeword,
            Out_Valid      => open,
            Out_Ready      => '1',
            Out_Data       => Dec_Rd_Data,
            Out_EccSec     => Dec_Rd_EccSec,
            Out_EccDed     => Dec_Rd_EccDed,
            ErrInj_BitFlip => (others => '0'),
            ErrInj_Valid   => '0'
        );

    -- User-facing outputs
    Rd_Data        <= Dec_Rd_Data;
    Rd_EccSec      <= Dec_Rd_EccSec;
    Rd_EccDed      <= Dec_Rd_EccDed;
    Rd_Valid       <= UserRdValidPipe(TotalReadLatency_c);
    Scrub_Active   <= Scrub_Active_i;
    Scrub_EccSec   <= Scrub_EccSec_i;
    Scrub_EccDed   <= Scrub_EccDed_i;
    Scrub_PassDone <= Scrub_PassDone_i;

end architecture;

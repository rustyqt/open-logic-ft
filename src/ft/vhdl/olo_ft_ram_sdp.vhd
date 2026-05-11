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
        IsAsync_g      : boolean  := false;
        RamRdLatency_g : positive := 1;
        RamStyle_g     : string   := "auto";
        RamBehavior_g  : string   := "RBW";
        EccPipeline_g  : natural  := 0
    );
    port (
        Clk            : in    std_logic;
        Wr_Addr        : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Wr_Ena         : in    std_logic                               := '1';
        Wr_Data        : in    std_logic_vector(Width_g - 1 downto 0);
        ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        ErrInj_Valid   : in    std_logic                               := '0';
        Rd_Clk         : in    std_logic                               := '0';
        Rd_Addr        : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Rd_Ena         : in    std_logic                               := '1';
        Rd_Data        : out   std_logic_vector(Width_g - 1 downto 0);
        Rd_Valid       : out   std_logic;
        Rd_EccSec      : out   std_logic;
        Rd_EccDed      : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ram_sdp is

    constant CodewordWidth_c    : positive := eccCodewordWidth(Width_g);
    constant TotalReadLatency_c : positive := RamRdLatency_g + EccPipeline_g;

    signal Wr_Codeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal Rd_Codeword : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- Error-injection latch (write clock domain)
    signal ErrInj_Pending : std_logic_vector(CodewordWidth_c - 1 downto 0) := (others => '0');
    signal ErrInj_Active  : std_logic_vector(CodewordWidth_c - 1 downto 0);

    signal RdValidPipe : std_logic_vector(1 to TotalReadLatency_c) := (others => '0');

    signal RdClk : std_logic;

begin

    -- Latch for ErrInj_BitFlip: applied on the next Wr_Ena='1' cycle, cleared afterwards.
    ErrInj_Active <= ErrInj_BitFlip when ErrInj_Valid = '1' else ErrInj_Pending;

    p_pending : process (Clk) is
    begin
        if rising_edge(Clk) then
            if Wr_Ena = '1' then
                ErrInj_Pending <= (others => '0');
            elsif ErrInj_Valid = '1' then
                ErrInj_Pending <= ErrInj_BitFlip;
            end if;
        end if;
    end process;

    -- Read clock selection
    g_rd_clk_async : if IsAsync_g generate
        RdClk <= Rd_Clk;
    end generate;
    g_rd_clk_sync : if not IsAsync_g generate
        RdClk <= Clk;
    end generate;

    -- Encode write data (combinational + injection)
    i_enc : entity work.olo_ft_ecc_encode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0
        )
        port map (
            Clk          => Clk,
            In_Data      => Wr_Data,
            In_BitFlip   => ErrInj_Active,
            Out_Codeword => Wr_Codeword
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
            Wr_Addr => Wr_Addr,
            Wr_Ena  => Wr_Ena,
            Wr_Data => Wr_Codeword,
            Rd_Clk  => Rd_Clk,
            Rd_Addr => Rd_Addr,
            Rd_Ena  => Rd_Ena,
            Rd_Data => Rd_Codeword
        );

    -- Decode read data (with optional pipeline, on read clock)
    i_dec : entity work.olo_ft_ecc_decode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => EccPipeline_g
        )
        port map (
            Clk         => RdClk,
            In_Codeword => Rd_Codeword,
            Out_Data    => Rd_Data,
            Out_EccSec  => Rd_EccSec,
            Out_EccDed  => Rd_EccDed
        );

    -- Read-valid pipeline: tracks Rd_Ena delayed to align with Rd_Data/Rd_EccSec/Rd_EccDed.
    p_rd_valid : process (RdClk) is
    begin
        if rising_edge(RdClk) then
            RdValidPipe(1) <= Rd_Ena;
            for i in 2 to TotalReadLatency_c loop
                RdValidPipe(i) <= RdValidPipe(i - 1);
            end loop;
        end if;
    end process;

    Rd_Valid <= RdValidPipe(TotalReadLatency_c);

end architecture;

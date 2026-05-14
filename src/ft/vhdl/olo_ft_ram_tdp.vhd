---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected true dual port RAM using SECDED (Single Error Correction,
-- Double Error Detection) Hamming code. Wraps olo_base_ram_tdp with a wider
-- internal word to store parity bits alongside data. The ECC is transparent
-- to the user: data is encoded on write and decoded/corrected on read.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_ram_tdp.md
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
entity olo_ft_ram_tdp is
    generic (
        Depth_g        : positive;
        Width_g        : positive;
        RamRdLatency_g : positive             := 1;
        RamStyle_g     : string               := "auto";
        RamBehavior_g  : string               := "RBW";
        EccPipeline_g  : natural range 0 to 2 := 0
    );
    port (
        -- Port A
        A_Clk            : in    std_logic;
        A_Rst            : in    std_logic                                                := '0';
        A_Addr           : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        A_WrEna          : in    std_logic                                                := '0';
        A_WrData         : in    std_logic_vector(Width_g - 1 downto 0)                   := (others => '0');
        A_RdData         : out   std_logic_vector(Width_g - 1 downto 0);
        A_RdValid        : out   std_logic;
        A_RdEccSec       : out   std_logic;
        A_RdEccDed       : out   std_logic;
        A_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        A_ErrInj_Valid   : in    std_logic                                                := '0';
        -- Port B
        B_Clk            : in    std_logic;
        B_Rst            : in    std_logic                                                := '0';
        B_Addr           : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        B_WrEna          : in    std_logic                                                := '0';
        B_WrData         : in    std_logic_vector(Width_g - 1 downto 0)                   := (others => '0');
        B_RdData         : out   std_logic_vector(Width_g - 1 downto 0);
        B_RdValid        : out   std_logic;
        B_RdEccSec       : out   std_logic;
        B_RdEccDed       : out   std_logic;
        B_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        B_ErrInj_Valid   : in    std_logic                                                := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ram_tdp is

    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);

    signal A_WrCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal A_RdCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal B_WrCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal B_RdCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- (not WrEna) shift register on each port, depth = RamRdLatency_g, feeds the corresponding
    -- decode entity's In_Valid. Decode owns the EccPipeline_g portion via its Out_Valid.
    signal A_RdEnaPipe : std_logic_vector(1 to RamRdLatency_g) := (others => '0');
    signal B_RdEnaPipe : std_logic_vector(1 to RamRdLatency_g) := (others => '0');

begin

    -----------------------------------------------------------------------------------------------
    -- Port A
    -----------------------------------------------------------------------------------------------
    i_enc_a : entity work.olo_ft_ecc_encode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0,
            UseReady_g => false
        )
        port map (
            Clk            => A_Clk,
            Rst            => A_Rst,
            In_Valid       => A_WrEna,
            In_Ready       => open,
            In_Data        => A_WrData,
            Out_Valid      => open,
            Out_Ready      => '1',
            Out_Codeword   => A_WrCodeword,
            ErrInj_BitFlip => A_ErrInj_BitFlip,
            ErrInj_Valid   => A_ErrInj_Valid
        );

    p_rd_ena_a : process (A_Clk) is
    begin
        if rising_edge(A_Clk) then
            if A_Rst = '1' then
                A_RdEnaPipe <= (others => '0');
            else
                A_RdEnaPipe(1) <= not A_WrEna;

                for i in 2 to RamRdLatency_g loop
                    A_RdEnaPipe(i) <= A_RdEnaPipe(i - 1);
                end loop;

            end if;
        end if;
    end process;

    i_dec_a : entity work.olo_ft_ecc_decode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => EccPipeline_g,
            UseReady_g => false
        )
        port map (
            Clk            => A_Clk,
            Rst            => A_Rst,
            In_Valid       => A_RdEnaPipe(RamRdLatency_g),
            In_Ready       => open,
            In_Codeword    => A_RdCodeword,
            Out_Valid      => A_RdValid,
            Out_Ready      => '1',
            Out_Data       => A_RdData,
            Out_EccSec     => A_RdEccSec,
            Out_EccDed     => A_RdEccDed,
            ErrInj_BitFlip => (others => '0'),
            ErrInj_Valid   => '0'
        );

    -----------------------------------------------------------------------------------------------
    -- Port B
    -----------------------------------------------------------------------------------------------
    i_enc_b : entity work.olo_ft_ecc_encode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0,
            UseReady_g => false
        )
        port map (
            Clk            => B_Clk,
            Rst            => B_Rst,
            In_Valid       => B_WrEna,
            In_Ready       => open,
            In_Data        => B_WrData,
            Out_Valid      => open,
            Out_Ready      => '1',
            Out_Codeword   => B_WrCodeword,
            ErrInj_BitFlip => B_ErrInj_BitFlip,
            ErrInj_Valid   => B_ErrInj_Valid
        );

    p_rd_ena_b : process (B_Clk) is
    begin
        if rising_edge(B_Clk) then
            if B_Rst = '1' then
                B_RdEnaPipe <= (others => '0');
            else
                B_RdEnaPipe(1) <= not B_WrEna;

                for i in 2 to RamRdLatency_g loop
                    B_RdEnaPipe(i) <= B_RdEnaPipe(i - 1);
                end loop;

            end if;
        end if;
    end process;

    i_dec_b : entity work.olo_ft_ecc_decode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => EccPipeline_g,
            UseReady_g => false
        )
        port map (
            Clk            => B_Clk,
            Rst            => B_Rst,
            In_Valid       => B_RdEnaPipe(RamRdLatency_g),
            In_Ready       => open,
            In_Codeword    => B_RdCodeword,
            Out_Valid      => B_RdValid,
            Out_Ready      => '1',
            Out_Data       => B_RdData,
            Out_EccSec     => B_RdEccSec,
            Out_EccDed     => B_RdEccDed,
            ErrInj_BitFlip => (others => '0'),
            ErrInj_Valid   => '0'
        );

    -----------------------------------------------------------------------------------------------
    -- Internal RAM with codeword-wide word
    -----------------------------------------------------------------------------------------------
    i_ram : entity work.olo_base_ram_tdp
        generic map (
            Depth_g       => Depth_g,
            Width_g       => CodewordWidth_c,
            RdLatency_g   => RamRdLatency_g,
            RamStyle_g    => RamStyle_g,
            RamBehavior_g => RamBehavior_g
        )
        port map (
            A_Clk    => A_Clk,
            A_Addr   => A_Addr,
            A_WrEna  => A_WrEna,
            A_WrData => A_WrCodeword,
            A_RdData => A_RdCodeword,
            B_Clk    => B_Clk,
            B_Addr   => B_Addr,
            B_WrEna  => B_WrEna,
            B_WrData => B_WrCodeword,
            B_RdData => B_RdCodeword
        );

end architecture;

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
        RamRdLatency_g : positive := 1;
        RamStyle_g     : string   := "auto";
        RamBehavior_g  : string   := "RBW";
        EccPipeline_g  : natural  := 0
    );
    port (
        A_Clk          : in    std_logic;
        A_Addr         : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        A_WrEna        : in    std_logic                               := '0';
        A_WrData         : in    std_logic_vector(Width_g - 1 downto 0)  := (others => '0');
        A_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        A_ErrInj_Valid   : in    std_logic                               := '0';
        A_RdData         : out   std_logic_vector(Width_g - 1 downto 0);
        A_RdValid        : out   std_logic;
        A_RdEccSec       : out   std_logic;
        A_RdEccDed       : out   std_logic;
        B_Clk            : in    std_logic;
        B_Addr           : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        B_WrEna          : in    std_logic                               := '0';
        B_WrData         : in    std_logic_vector(Width_g - 1 downto 0)  := (others => '0');
        B_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        B_ErrInj_Valid   : in    std_logic                               := '0';
        B_RdData         : out   std_logic_vector(Width_g - 1 downto 0);
        B_RdValid        : out   std_logic;
        B_RdEccSec       : out   std_logic;
        B_RdEccDed       : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ram_tdp is

    constant CodewordWidth_c    : positive := eccCodewordWidth(Width_g);
    constant TotalReadLatency_c : positive := RamRdLatency_g + EccPipeline_g;

    signal A_WrCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal A_RdCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal B_WrCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal B_RdCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- Per-port error-injection latches
    signal A_ErrInj_Pending : std_logic_vector(CodewordWidth_c - 1 downto 0) := (others => '0');
    signal A_ErrInj_Active  : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal B_ErrInj_Pending : std_logic_vector(CodewordWidth_c - 1 downto 0) := (others => '0');
    signal B_ErrInj_Active  : std_logic_vector(CodewordWidth_c - 1 downto 0);

    signal A_RdValidPipe : std_logic_vector(1 to TotalReadLatency_c) := (others => '0');
    signal B_RdValidPipe : std_logic_vector(1 to TotalReadLatency_c) := (others => '0');

begin

    -- Per-port error-injection latches
    A_ErrInj_Active <= A_ErrInj_BitFlip when A_ErrInj_Valid = '1' else A_ErrInj_Pending;
    B_ErrInj_Active <= B_ErrInj_BitFlip when B_ErrInj_Valid = '1' else B_ErrInj_Pending;

    p_pending_a : process (A_Clk) is
    begin
        if rising_edge(A_Clk) then
            if A_WrEna = '1' then
                A_ErrInj_Pending <= (others => '0');
            elsif A_ErrInj_Valid = '1' then
                A_ErrInj_Pending <= A_ErrInj_BitFlip;
            end if;
        end if;
    end process;

    p_pending_b : process (B_Clk) is
    begin
        if rising_edge(B_Clk) then
            if B_WrEna = '1' then
                B_ErrInj_Pending <= (others => '0');
            elsif B_ErrInj_Valid = '1' then
                B_ErrInj_Pending <= B_ErrInj_BitFlip;
            end if;
        end if;
    end process;

    -- Encoders
    i_enc_a : entity work.olo_ft_ecc_encode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0
        )
        port map (
            Clk          => A_Clk,
            In_Data      => A_WrData,
            In_BitFlip   => A_ErrInj_Active,
            Out_Codeword => A_WrCodeword
        );

    i_enc_b : entity work.olo_ft_ecc_encode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0
        )
        port map (
            Clk          => B_Clk,
            In_Data      => B_WrData,
            In_BitFlip   => B_ErrInj_Active,
            Out_Codeword => B_WrCodeword
        );

    -- Internal RAM with codeword-wide word
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

    -- Decoders
    i_dec_a : entity work.olo_ft_ecc_decode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => EccPipeline_g
        )
        port map (
            Clk         => A_Clk,
            In_Codeword => A_RdCodeword,
            Out_Data    => A_RdData,
            Out_EccSec  => A_RdEccSec,
            Out_EccDed  => A_RdEccDed
        );

    i_dec_b : entity work.olo_ft_ecc_decode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => EccPipeline_g
        )
        port map (
            Clk         => B_Clk,
            In_Codeword => B_RdCodeword,
            Out_Data    => B_RdData,
            Out_EccSec  => B_RdEccSec,
            Out_EccDed  => B_RdEccDed
        );

    -- Read-valid pipelines (one per port; clocked by their own port clock)
    p_rd_valid_a : process (A_Clk) is
    begin
        if rising_edge(A_Clk) then
            A_RdValidPipe(1) <= not A_WrEna;
            for i in 2 to TotalReadLatency_c loop
                A_RdValidPipe(i) <= A_RdValidPipe(i - 1);
            end loop;
        end if;
    end process;

    A_RdValid <= A_RdValidPipe(TotalReadLatency_c);

    p_rd_valid_b : process (B_Clk) is
    begin
        if rising_edge(B_Clk) then
            B_RdValidPipe(1) <= not B_WrEna;
            for i in 2 to TotalReadLatency_c loop
                B_RdValidPipe(i) <= B_RdValidPipe(i - 1);
            end loop;
        end if;
    end process;

    B_RdValid <= B_RdValidPipe(TotalReadLatency_c);

end architecture;

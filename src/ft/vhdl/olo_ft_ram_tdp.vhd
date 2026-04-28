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
    use work.olo_base_pkg_attribute.all;
    use work.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_ram_tdp is
    generic (
        Depth_g       : positive;
        Width_g       : positive;
        RdLatency_g   : positive := 1;
        RamStyle_g    : string   := "auto";
        RamBehavior_g : string   := "RBW";
        EccPipeline_g : natural  := 0
    );
    port (
        A_Clk          : in    std_logic;
        A_Addr         : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        A_WrEna        : in    std_logic                               := '0';
        A_WrData       : in    std_logic_vector(Width_g - 1 downto 0)  := (others => '0');
        A_WrEccBitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        A_RdData       : out   std_logic_vector(Width_g - 1 downto 0);
        A_RdEccSec     : out   std_logic;
        A_RdEccDed     : out   std_logic;
        B_Clk          : in    std_logic;
        B_Addr         : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        B_WrEna        : in    std_logic                               := '0';
        B_WrData       : in    std_logic_vector(Width_g - 1 downto 0)  := (others => '0');
        B_WrEccBitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        B_RdData       : out   std_logic_vector(Width_g - 1 downto 0);
        B_RdEccSec     : out   std_logic;
        B_RdEccDed     : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ram_tdp is

    -- ECC constants
    constant ParityBits_c    : positive := eccParityBits(Width_g);
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);

    -- Port A signals
    signal A_WrEncoded  : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal A_WrInjected : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal A_RdEncoded  : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal A_SynPar     : std_logic_vector(ParityBits_c downto 0);
    signal A_DataCorr   : std_logic_vector(Width_g - 1 downto 0);
    signal A_EccSecI    : std_logic;
    signal A_EccDedI    : std_logic;

    -- Port B signals
    signal B_WrEncoded  : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal B_WrInjected : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal B_RdEncoded  : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal B_SynPar     : std_logic_vector(ParityBits_c downto 0);
    signal B_DataCorr   : std_logic_vector(Width_g - 1 downto 0);
    signal B_EccSecI    : std_logic;
    signal B_EccDedI    : std_logic;

begin

    -- Encode write data
    A_WrEncoded <= eccEncode(A_WrData);
    B_WrEncoded <= eccEncode(B_WrData);

    -- Error injection (XOR full bit-flip pattern into the encoded codeword for testing / BIST)
    A_WrInjected <= A_WrEncoded xor A_WrEccBitFlip;
    B_WrInjected <= B_WrEncoded xor B_WrEccBitFlip;

    -- Internal RAM with wider codeword width
    i_ram : entity work.olo_base_ram_tdp
        generic map (
            Depth_g       => Depth_g,
            Width_g       => CodewordWidth_c,
            RdLatency_g   => RdLatency_g,
            RamStyle_g    => RamStyle_g,
            RamBehavior_g => RamBehavior_g
        )
        port map (
            A_Clk    => A_Clk,
            A_Addr   => A_Addr,
            A_WrEna  => A_WrEna,
            A_WrData => A_WrInjected,
            A_RdData => A_RdEncoded,
            B_Clk    => B_Clk,
            B_Addr   => B_Addr,
            B_WrEna  => B_WrEna,
            B_WrData => B_WrInjected,
            B_RdData => B_RdEncoded
        );

    -- Decode read data - compute syndrome/parity once, reuse for data and flags (combinational)
    A_SynPar  <= eccSyndromeAndParity(A_RdEncoded, Width_g);
    A_DataCorr <= eccCorrectData(A_RdEncoded, A_SynPar, Width_g);
    A_EccSecI <= eccSecError(A_SynPar);
    A_EccDedI <= eccDedError(A_SynPar);

    B_SynPar  <= eccSyndromeAndParity(B_RdEncoded, Width_g);
    B_DataCorr <= eccCorrectData(B_RdEncoded, B_SynPar, Width_g);
    B_EccSecI <= eccSecError(B_SynPar);
    B_EccDedI <= eccDedError(B_SynPar);

    -- No ECC pipeline: direct output
    g_no_ecc_pipe : if EccPipeline_g = 0 generate
        A_RdData   <= A_DataCorr;
        A_RdEccSec <= A_EccSecI;
        A_RdEccDed <= A_EccDedI;
        B_RdData   <= B_DataCorr;
        B_RdEccSec <= B_EccSecI;
        B_RdEccDed <= B_EccDedI;
    end generate;

    -- ECC pipeline: register stages after decode
    g_ecc_pipe : if EccPipeline_g > 0 generate
        type Data_t is array (natural range <>) of std_logic_vector(Width_g - 1 downto 0);
        signal A_DataPipe   : Data_t(1 to EccPipeline_g);
        signal A_EccSecPipe : std_logic_vector(1 to EccPipeline_g);
        signal A_EccDedPipe : std_logic_vector(1 to EccPipeline_g);
        signal B_DataPipe   : Data_t(1 to EccPipeline_g);
        signal B_EccSecPipe : std_logic_vector(1 to EccPipeline_g);
        signal B_EccDedPipe : std_logic_vector(1 to EccPipeline_g);
        attribute shreg_extract of A_DataPipe   : signal is ShregExtract_SuppressExtraction_c;
        attribute shreg_extract of A_EccSecPipe : signal is ShregExtract_SuppressExtraction_c;
        attribute shreg_extract of A_EccDedPipe : signal is ShregExtract_SuppressExtraction_c;
        attribute shreg_extract of B_DataPipe   : signal is ShregExtract_SuppressExtraction_c;
        attribute shreg_extract of B_EccSecPipe : signal is ShregExtract_SuppressExtraction_c;
        attribute shreg_extract of B_EccDedPipe : signal is ShregExtract_SuppressExtraction_c;
    begin
        p_ecc_pipe_a : process (A_Clk) is
        begin
            if rising_edge(A_Clk) then
                A_DataPipe(1)   <= A_DataCorr;
                A_EccSecPipe(1) <= A_EccSecI;
                A_EccDedPipe(1) <= A_EccDedI;
                A_DataPipe(2 to EccPipeline_g)   <= A_DataPipe(1 to EccPipeline_g - 1);
                A_EccSecPipe(2 to EccPipeline_g) <= A_EccSecPipe(1 to EccPipeline_g - 1);
                A_EccDedPipe(2 to EccPipeline_g) <= A_EccDedPipe(1 to EccPipeline_g - 1);
            end if;
        end process;
        A_RdData   <= A_DataPipe(EccPipeline_g);
        A_RdEccSec <= A_EccSecPipe(EccPipeline_g);
        A_RdEccDed <= A_EccDedPipe(EccPipeline_g);

        p_ecc_pipe_b : process (B_Clk) is
        begin
            if rising_edge(B_Clk) then
                B_DataPipe(1)   <= B_DataCorr;
                B_EccSecPipe(1) <= B_EccSecI;
                B_EccDedPipe(1) <= B_EccDedI;
                B_DataPipe(2 to EccPipeline_g)   <= B_DataPipe(1 to EccPipeline_g - 1);
                B_EccSecPipe(2 to EccPipeline_g) <= B_EccSecPipe(1 to EccPipeline_g - 1);
                B_EccDedPipe(2 to EccPipeline_g) <= B_EccDedPipe(1 to EccPipeline_g - 1);
            end if;
        end process;
        B_RdData   <= B_DataPipe(EccPipeline_g);
        B_RdEccSec <= B_EccSecPipe(EccPipeline_g);
        B_RdEccDed <= B_EccDedPipe(EccPipeline_g);
    end generate;

end architecture;

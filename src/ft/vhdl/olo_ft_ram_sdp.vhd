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
    use work.olo_base_pkg_attribute.all;
    use work.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_ram_sdp is
    generic (
        Depth_g       : positive;
        Width_g       : positive;
        IsAsync_g     : boolean  := false;
        RdLatency_g   : positive := 1;
        RamStyle_g    : string   := "auto";
        RamBehavior_g : string   := "RBW";
        EccPipeline_g : natural  := 0
    );
    port (
        Clk            : in    std_logic;
        Wr_Addr        : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Wr_Ena         : in    std_logic                               := '1';
        Wr_Data        : in    std_logic_vector(Width_g - 1 downto 0);
        Wr_EccBitFlip  : in    std_logic_vector(1 downto 0)            := "00";
        Rd_Clk         : in    std_logic                               := '0';
        Rd_Addr        : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Rd_Ena         : in    std_logic                               := '1';
        Rd_Data        : out   std_logic_vector(Width_g - 1 downto 0);
        Rd_SecErr      : out   std_logic;
        Rd_DedErr      : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ram_sdp is

    -- ECC constants
    constant ParityBits_c    : positive := eccParityBits(Width_g);
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);

    -- Write-side signals
    signal Wr_Encoded  : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal Wr_Injected : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- Read-side signals
    signal Rd_Encoded  : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal Rd_SynPar   : std_logic_vector(ParityBits_c downto 0);
    signal Rd_DataCorr : std_logic_vector(Width_g - 1 downto 0);
    signal Rd_SecErrI  : std_logic;
    signal Rd_DedErrI  : std_logic;

    -- Read clock selection
    signal RdClk : std_logic;

begin

    -- Encode write data
    Wr_Encoded <= eccEncode(Wr_Data);

    -- Error injection (flip codeword bits for testing / BIST)
    Wr_Injected(CodewordWidth_c - 1 downto 2) <= Wr_Encoded(CodewordWidth_c - 1 downto 2);
    Wr_Injected(1)                             <= Wr_Encoded(1) xor Wr_EccBitFlip(1);
    Wr_Injected(0)                             <= Wr_Encoded(0) xor Wr_EccBitFlip(0);

    -- Internal RAM with wider codeword width
    i_ram : entity work.olo_base_ram_sdp
        generic map (
            Depth_g       => Depth_g,
            Width_g       => CodewordWidth_c,
            IsAsync_g     => IsAsync_g,
            RdLatency_g   => RdLatency_g,
            RamStyle_g    => RamStyle_g,
            RamBehavior_g => RamBehavior_g
        )
        port map (
            Clk     => Clk,
            Wr_Addr => Wr_Addr,
            Wr_Ena  => Wr_Ena,
            Wr_Data => Wr_Injected,
            Rd_Clk  => Rd_Clk,
            Rd_Addr => Rd_Addr,
            Rd_Ena  => Rd_Ena,
            Rd_Data => Rd_Encoded
        );

    -- Read clock selection
    g_rd_clk_async : if IsAsync_g generate
        RdClk <= Rd_Clk;
    end generate;
    g_rd_clk_sync : if not IsAsync_g generate
        RdClk <= Clk;
    end generate;

    -- Decode read data (combinational)
    Rd_SynPar   <= eccSyndromeAndParity(Rd_Encoded, Width_g);
    Rd_DataCorr <= eccCorrectData(Rd_Encoded, Rd_SynPar, Width_g);
    Rd_SecErrI  <= eccSecError(Rd_SynPar);
    Rd_DedErrI  <= eccDedError(Rd_SynPar);

    -- No ECC pipeline: direct output
    g_no_ecc_pipe : if EccPipeline_g = 0 generate
        Rd_Data   <= Rd_DataCorr;
        Rd_SecErr <= Rd_SecErrI;
        Rd_DedErr <= Rd_DedErrI;
    end generate;

    -- ECC pipeline: register stages after decode
    g_ecc_pipe : if EccPipeline_g > 0 generate
        type Data_t is array (natural range <>) of std_logic_vector(Width_g - 1 downto 0);
        signal DataPipe   : Data_t(1 to EccPipeline_g);
        signal SecErrPipe : std_logic_vector(1 to EccPipeline_g);
        signal DedErrPipe : std_logic_vector(1 to EccPipeline_g);
        attribute shreg_extract of DataPipe   : signal is ShregExtract_SuppressExtraction_c;
        attribute shreg_extract of SecErrPipe : signal is ShregExtract_SuppressExtraction_c;
        attribute shreg_extract of DedErrPipe : signal is ShregExtract_SuppressExtraction_c;
    begin
        p_ecc_pipe : process (RdClk) is
        begin
            if rising_edge(RdClk) then
                DataPipe(1)   <= Rd_DataCorr;
                SecErrPipe(1) <= Rd_SecErrI;
                DedErrPipe(1) <= Rd_DedErrI;
                DataPipe(2 to EccPipeline_g)   <= DataPipe(1 to EccPipeline_g - 1);
                SecErrPipe(2 to EccPipeline_g) <= SecErrPipe(1 to EccPipeline_g - 1);
                DedErrPipe(2 to EccPipeline_g) <= DedErrPipe(1 to EccPipeline_g - 1);
            end if;
        end process;
        Rd_Data   <= DataPipe(EccPipeline_g);
        Rd_SecErr <= SecErrPipe(EccPipeline_g);
        Rd_DedErr <= DedErrPipe(EccPipeline_g);
    end generate;

end architecture;

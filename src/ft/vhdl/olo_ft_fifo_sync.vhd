---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected synchronous FIFO using SECDED (Single Error Correction,
-- Double Error Detection) Hamming code. Wraps olo_base_fifo_sync with a wider
-- internal word to store parity bits alongside data. The ECC is transparent
-- to the user: data is encoded on write and decoded/corrected on read.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_fifo_sync.md
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
entity olo_ft_fifo_sync is
    generic (
        Width_g         : positive;
        Depth_g         : positive;
        AlmFullOn_g     : boolean   := false;
        AlmFullLevel_g  : natural   := 0;
        AlmEmptyOn_g    : boolean   := false;
        AlmEmptyLevel_g : natural   := 0;
        RamStyle_g      : string    := "auto";
        RamBehavior_g   : string    := "RBW";
        ReadyRstState_g : std_logic := '1';
        EccPipeline_g   : natural   := 0
    );
    port (
        -- Control Ports
        Clk           : in    std_logic;
        Rst           : in    std_logic;
        -- Input Data
        In_Data       : in    std_logic_vector(Width_g - 1 downto 0);
        In_Valid      : in    std_logic                                        := '1';
        In_Ready      : out   std_logic;
        In_Level      : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0);
        In_EccBitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        -- Output Data
        Out_Data      : out   std_logic_vector(Width_g - 1 downto 0);
        Out_Valid     : out   std_logic;
        Out_Ready     : in    std_logic                                        := '1';
        Out_Level     : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0);
        Out_EccSec    : out   std_logic;
        Out_EccDed    : out   std_logic;
        -- Status
        Full          : out   std_logic;
        AlmFull       : out   std_logic;
        Empty         : out   std_logic;
        AlmEmpty      : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_fifo_sync is

    -- ECC constants
    constant ParityBits_c    : positive := eccParityBits(Width_g);
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);
    constant PlWidth_c       : positive := Width_g + 2;

    -- Encode signals
    signal In_Encoded  : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal In_Injected : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- Base FIFO output signals
    signal Fifo_OutData  : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal Fifo_OutValid : std_logic;
    signal Fifo_OutReady : std_logic;

    -- Decoded signals (combinational)
    signal Dec_SynPar : std_logic_vector(ParityBits_c downto 0);
    signal Dec_Data   : std_logic_vector(Width_g - 1 downto 0);
    signal Dec_EccSec : std_logic;
    signal Dec_EccDed : std_logic;

    -- Pipeline bus (bundled: EccSec & EccDed & Data)
    signal Pl_InData  : std_logic_vector(PlWidth_c - 1 downto 0);
    signal Pl_OutData : std_logic_vector(PlWidth_c - 1 downto 0);

begin

    -- Encode write data
    In_Encoded <= eccEncode(In_Data);

    -- Error injection (XOR full bit-flip pattern into the encoded codeword for testing / BIST)
    In_Injected <= In_Encoded xor In_EccBitFlip;

    -- Base FIFO with wider codeword width
    i_fifo : entity work.olo_base_fifo_sync
        generic map (
            Width_g         => CodewordWidth_c,
            Depth_g         => Depth_g,
            AlmFullOn_g     => AlmFullOn_g,
            AlmFullLevel_g  => AlmFullLevel_g,
            AlmEmptyOn_g    => AlmEmptyOn_g,
            AlmEmptyLevel_g => AlmEmptyLevel_g,
            RamStyle_g      => RamStyle_g,
            RamBehavior_g   => RamBehavior_g,
            ReadyRstState_g => ReadyRstState_g
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Data   => In_Injected,
            In_Valid  => In_Valid,
            In_Ready  => In_Ready,
            In_Level  => In_Level,
            Out_Data  => Fifo_OutData,
            Out_Valid => Fifo_OutValid,
            Out_Ready => Fifo_OutReady,
            Out_Level => Out_Level,
            Full      => Full,
            AlmFull   => AlmFull,
            Empty     => Empty,
            AlmEmpty  => AlmEmpty
        );

    -- ECC decode (combinational)
    Dec_SynPar <= eccSyndromeAndParity(Fifo_OutData, Width_g);
    Dec_Data   <= eccCorrectData(Fifo_OutData, Dec_SynPar, Width_g);
    Dec_EccSec <= eccSecError(Dec_SynPar);
    Dec_EccDed <= eccDedError(Dec_SynPar);

    -- Bundle decoded data and error flags for pipeline
    Pl_InData <= Dec_EccSec & Dec_EccDed & Dec_Data;

    -- Pipeline stage with Valid/Ready handshaking (0 stages = passthrough)
    i_pl : entity work.olo_base_pl_stage
        generic map (
            Width_g  => PlWidth_c,
            Stages_g => EccPipeline_g
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Valid  => Fifo_OutValid,
            In_Ready  => Fifo_OutReady,
            In_Data   => Pl_InData,
            Out_Valid => Out_Valid,
            Out_Ready => Out_Ready,
            Out_Data  => Pl_OutData
        );

    -- Unbundle output
    Out_Data   <= Pl_OutData(Width_g - 1 downto 0);
    Out_EccDed <= Pl_OutData(Width_g);
    Out_EccSec <= Pl_OutData(Width_g + 1);

end architecture;

---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected asynchronous FIFO using SECDED (Single Error Correction,
-- Double Error Detection) Hamming code. Wraps olo_base_fifo_async with a wider
-- internal word to store parity bits alongside data. The ECC is transparent
-- to the user: data is encoded on write and decoded/corrected on read.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_fifo_async.md
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
entity olo_ft_fifo_async is
    generic (
        Width_g         : positive;
        Depth_g         : positive;
        AlmFullOn_g     : boolean               := false;
        AlmFullLevel_g  : natural               := 0;
        AlmEmptyOn_g    : boolean               := false;
        AlmEmptyLevel_g : natural               := 0;
        RamStyle_g      : string                := "auto";
        RamBehavior_g   : string                := "RBW";
        ReadyRstState_g : std_logic             := '1';
        Optimization_g  : string                := "SPEED";
        SyncStages_g    : positive range 2 to 4 := 2;
        EccPipeline_g   : natural               := 0
    );
    port (
        -- Input interface
        In_Clk          : in    std_logic;
        In_Rst          : in    std_logic;
        In_RstOut       : out   std_logic;
        In_Data         : in    std_logic_vector(Width_g - 1 downto 0);
        In_Valid        : in    std_logic                               := '1';
        In_Ready        : out   std_logic;
        In_EccBitFlip   : in    std_logic_vector(1 downto 0)            := "00";
        -- Input Status
        In_Full         : out   std_logic;
        In_Empty        : out   std_logic;
        In_AlmFull      : out   std_logic;
        In_AlmEmpty     : out   std_logic;
        In_Level        : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0);
        -- Output Interface
        Out_Clk         : in    std_logic;
        Out_Rst         : in    std_logic;
        Out_RstOut      : out   std_logic;
        Out_Data        : out   std_logic_vector(Width_g - 1 downto 0);
        Out_Valid       : out   std_logic;
        Out_Ready       : in    std_logic                               := '1';
        Out_SecErr      : out   std_logic;
        Out_DedErr      : out   std_logic;
        -- Output Status
        Out_Full        : out   std_logic;
        Out_Empty       : out   std_logic;
        Out_AlmFull     : out   std_logic;
        Out_AlmEmpty    : out   std_logic;
        Out_Level       : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_fifo_async is

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
    signal Fifo_OutRst   : std_logic;

    -- Decoded signals (combinational)
    signal Dec_SynPar : std_logic_vector(ParityBits_c downto 0);
    signal Dec_Data   : std_logic_vector(Width_g - 1 downto 0);
    signal Dec_SecErr : std_logic;
    signal Dec_DedErr : std_logic;

    -- Pipeline bus (bundled: SecErr & DedErr & Data)
    signal Pl_InData  : std_logic_vector(PlWidth_c - 1 downto 0);
    signal Pl_OutData : std_logic_vector(PlWidth_c - 1 downto 0);

begin

    -- Encode write data
    In_Encoded <= eccEncode(In_Data);

    -- Error injection (flip codeword bits for testing / BIST)
    In_Injected(CodewordWidth_c - 1 downto 2) <= In_Encoded(CodewordWidth_c - 1 downto 2);
    In_Injected(1)                             <= In_Encoded(1) xor In_EccBitFlip(1);
    In_Injected(0)                             <= In_Encoded(0) xor In_EccBitFlip(0);

    -- Base FIFO with wider codeword width, using TMR-hardened CDC primitives
    i_fifo : entity work.olo_base_fifo_async
        generic map (
            Width_g         => CodewordWidth_c,
            Depth_g         => Depth_g,
            AlmFullOn_g     => AlmFullOn_g,
            AlmFullLevel_g  => AlmFullLevel_g,
            AlmEmptyOn_g    => AlmEmptyOn_g,
            AlmEmptyLevel_g => AlmEmptyLevel_g,
            RamStyle_g      => RamStyle_g,
            RamBehavior_g   => RamBehavior_g,
            ReadyRstState_g => ReadyRstState_g,
            Optimization_g  => Optimization_g,
            SyncStages_g    => SyncStages_g,
            FaultTolerant_g => true
        )
        port map (
            In_Clk      => In_Clk,
            In_Rst      => In_Rst,
            In_RstOut   => In_RstOut,
            In_Data     => In_Injected,
            In_Valid    => In_Valid,
            In_Ready    => In_Ready,
            In_Full     => In_Full,
            In_Empty    => In_Empty,
            In_AlmFull  => In_AlmFull,
            In_AlmEmpty => In_AlmEmpty,
            In_Level    => In_Level,
            Out_Clk     => Out_Clk,
            Out_Rst     => Out_Rst,
            Out_RstOut  => Fifo_OutRst,
            Out_Data    => Fifo_OutData,
            Out_Valid   => Fifo_OutValid,
            Out_Ready   => Fifo_OutReady,
            Out_Full    => Out_Full,
            Out_Empty   => Out_Empty,
            Out_AlmFull => Out_AlmFull,
            Out_AlmEmpty => Out_AlmEmpty,
            Out_Level   => Out_Level
        );

    -- Forward output reset
    Out_RstOut <= Fifo_OutRst;

    -- ECC decode (combinational)
    Dec_SynPar <= eccSyndromeAndParity(Fifo_OutData, Width_g);
    Dec_Data   <= eccCorrectData(Fifo_OutData, Dec_SynPar, Width_g);
    Dec_SecErr <= eccSecError(Dec_SynPar);
    Dec_DedErr <= eccDedError(Dec_SynPar);

    -- Bundle decoded data and error flags for pipeline
    Pl_InData <= Dec_SecErr & Dec_DedErr & Dec_Data;

    -- Pipeline stage with Valid/Ready handshaking (0 stages = passthrough)
    i_pl : entity work.olo_base_pl_stage
        generic map (
            Width_g  => PlWidth_c,
            Stages_g => EccPipeline_g
        )
        port map (
            Clk       => Out_Clk,
            Rst       => Fifo_OutRst,
            In_Valid  => Fifo_OutValid,
            In_Ready  => Fifo_OutReady,
            In_Data   => Pl_InData,
            Out_Valid => Out_Valid,
            Out_Ready => Out_Ready,
            Out_Data  => Pl_OutData
        );

    -- Unbundle output
    Out_Data   <= Pl_OutData(Width_g - 1 downto 0);
    Out_DedErr <= Pl_OutData(Width_g);
    Out_SecErr <= Pl_OutData(Width_g + 1);

end architecture;

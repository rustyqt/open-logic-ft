---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected synchronous packet FIFO using SECDED (Single Error Correction,
-- Double Error Detection) Hamming code. Wraps olo_base_fifo_packet with a wider
-- internal word to store parity bits alongside data. The ECC is transparent
-- to the user: data is encoded on write and decoded/corrected on read.
--
-- Note: In DROP_ONLY mode, the In_Last flag is stored alongside encoded data
-- in the RAM but is NOT covered by the ECC parity. In FULL mode, In_Last is
-- stored in a separate internal FIFO (also not ECC-protected).
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_fifo_packet.md
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
entity olo_ft_fifo_packet is
    generic (
        Width_g            : positive;
        Depth_g            : positive;
        FeatureSet_g       : string                            := "FULL";
        RamStyle_g         : string                            := "auto";
        RamBehavior_g      : string                            := "RBW";
        SmallRamStyle_g    : string                            := "auto";
        SmallRamBehavior_g : string                            := "same";
        MaxPackets_g       : positive range 2 to positive'high := 17;
        EccPipeline_g      : natural                           := 0
    );
    port (
        -- Control Ports
        Clk           : in    std_logic;
        Rst           : in    std_logic;
        -- Input Data
        In_Valid      : in    std_logic                                        := '1';
        In_Ready      : out   std_logic;
        In_Data       : in    std_logic_vector(Width_g - 1 downto 0);
        In_Last       : in    std_logic                                        := '1';
        In_Drop       : in    std_logic                                        := '0';
        In_IsDropped  : out   std_logic;
        In_EccBitFlip : in    std_logic_vector(1 downto 0)                     := "00";
        -- Output Data
        Out_Valid     : out   std_logic;
        Out_Ready     : in    std_logic                                        := '1';
        Out_Data      : out   std_logic_vector(Width_g - 1 downto 0);
        Out_Size      : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0);
        Out_Last      : out   std_logic;
        Out_Next      : in    std_logic                                        := '0';
        Out_Repeat    : in    std_logic                                        := '0';
        Out_SecErr    : out   std_logic;
        Out_DedErr    : out   std_logic;
        -- Status
        PacketLevel   : out   std_logic_vector(log2ceil(MaxPackets_g + 1) - 1 downto 0);
        FreeWords     : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_fifo_packet is

    -- ECC constants
    constant ParityBits_c    : positive := eccParityBits(Width_g);
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);
    constant SizeWidth_c     : positive := log2ceil(Depth_g + 1);
    constant PlWidth_c       : positive := Width_g + 2 + 1 + SizeWidth_c;

    -- Encode signals
    signal In_Encoded  : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal In_Injected : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- Base FIFO output signals
    signal Fifo_OutData  : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal Fifo_OutValid : std_logic;
    signal Fifo_OutReady : std_logic;
    signal Fifo_OutLast  : std_logic;
    signal Fifo_OutSize  : std_logic_vector(SizeWidth_c - 1 downto 0);

    -- Decoded signals (combinational)
    signal Dec_SynPar : std_logic_vector(ParityBits_c downto 0);
    signal Dec_Data   : std_logic_vector(Width_g - 1 downto 0);
    signal Dec_SecErr : std_logic;
    signal Dec_DedErr : std_logic;

    -- Pipeline bus (bundled: SecErr & DedErr & Last & Size & Data)
    signal Pl_InData  : std_logic_vector(PlWidth_c - 1 downto 0);
    signal Pl_OutData : std_logic_vector(PlWidth_c - 1 downto 0);

begin

    -- Encode write data
    In_Encoded <= eccEncode(In_Data);

    -- Error injection (flip codeword bits for testing / BIST)
    In_Injected(CodewordWidth_c - 1 downto 2) <= In_Encoded(CodewordWidth_c - 1 downto 2);
    In_Injected(1)                             <= In_Encoded(1) xor In_EccBitFlip(1);
    In_Injected(0)                             <= In_Encoded(0) xor In_EccBitFlip(0);

    -- Base FIFO with wider codeword width
    i_fifo : entity work.olo_base_fifo_packet
        generic map (
            Width_g            => CodewordWidth_c,
            Depth_g            => Depth_g,
            FeatureSet_g       => FeatureSet_g,
            RamStyle_g         => RamStyle_g,
            RamBehavior_g      => RamBehavior_g,
            SmallRamStyle_g    => SmallRamStyle_g,
            SmallRamBehavior_g => SmallRamBehavior_g,
            MaxPackets_g       => MaxPackets_g
        )
        port map (
            Clk         => Clk,
            Rst         => Rst,
            In_Valid    => In_Valid,
            In_Ready    => In_Ready,
            In_Data     => In_Injected,
            In_Last     => In_Last,
            In_Drop     => In_Drop,
            In_IsDropped => In_IsDropped,
            Out_Valid   => Fifo_OutValid,
            Out_Ready   => Fifo_OutReady,
            Out_Data    => Fifo_OutData,
            Out_Size    => Fifo_OutSize,
            Out_Last    => Fifo_OutLast,
            Out_Next    => Out_Next,
            Out_Repeat  => Out_Repeat,
            PacketLevel => PacketLevel,
            FreeWords   => FreeWords
        );

    -- ECC decode (combinational)
    Dec_SynPar <= eccSyndromeAndParity(Fifo_OutData, Width_g);
    Dec_Data   <= eccCorrectData(Fifo_OutData, Dec_SynPar, Width_g);
    Dec_SecErr <= eccSecError(Dec_SynPar);
    Dec_DedErr <= eccDedError(Dec_SynPar);

    -- Bundle decoded data, error flags, Last and Size for pipeline
    Pl_InData <= Dec_SecErr & Dec_DedErr & Fifo_OutLast & Fifo_OutSize & Dec_Data;

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
    Out_Size   <= Pl_OutData(Width_g + SizeWidth_c - 1 downto Width_g);
    Out_Last   <= Pl_OutData(Width_g + SizeWidth_c);
    Out_DedErr <= Pl_OutData(Width_g + SizeWidth_c + 1);
    Out_SecErr <= Pl_OutData(Width_g + SizeWidth_c + 2);

end architecture;

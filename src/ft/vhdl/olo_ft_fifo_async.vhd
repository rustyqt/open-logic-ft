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
        EccPipeline_g   : natural range 0 to 2  := 0
    );
    port (
        -- Input interface
        In_Clk            : in    std_logic;
        In_Rst            : in    std_logic;
        In_RstOut         : out   std_logic;
        In_Data           : in    std_logic_vector(Width_g - 1 downto 0);
        In_Valid          : in    std_logic                                                := '1';
        In_Ready          : out   std_logic;
        In_Full           : out   std_logic;
        In_Empty          : out   std_logic;
        In_AlmFull        : out   std_logic;
        In_AlmEmpty       : out   std_logic;
        In_Level          : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0);
        -- Output Interface
        Out_Clk           : in    std_logic;
        Out_Rst           : in    std_logic;
        Out_RstOut        : out   std_logic;
        Out_Data          : out   std_logic_vector(Width_g - 1 downto 0);
        Out_Valid         : out   std_logic;
        Out_Ready         : in    std_logic                                                := '1';
        Out_EccSec        : out   std_logic;
        Out_EccDed        : out   std_logic;
        Out_Full          : out   std_logic;
        Out_Empty         : out   std_logic;
        Out_AlmFull       : out   std_logic;
        Out_AlmEmpty      : out   std_logic;
        Out_Level         : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0);
        -- Error injection (independent of the data handshake, on the input clock domain)
        In_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        In_ErrInj_Valid   : in    std_logic                                                := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_fifo_async is

    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);

    -- Encoder ⇄ FIFO (input clock domain)
    signal EncOut_Codeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal EncOut_Valid    : std_logic;
    signal EncOut_Ready    : std_logic;

    -- FIFO ⇄ decoder (output clock domain)
    signal FifoOut_Codeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal FifoOut_Valid    : std_logic;
    signal FifoOut_Ready    : std_logic;
    signal Fifo_OutRst      : std_logic;

begin

    -- Forward output reset to user
    Out_RstOut <= Fifo_OutRst;

    -- Encoder (input clock domain). Codec owns the injection latch.
    i_enc : entity work.olo_ft_ecc_encode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0,
            UseReady_g => true
        )
        port map (
            Clk            => In_Clk,
            Rst            => In_Rst,
            In_Valid       => In_Valid,
            In_Ready       => In_Ready,
            In_Data        => In_Data,
            Out_Valid      => EncOut_Valid,
            Out_Ready      => EncOut_Ready,
            Out_Codeword   => EncOut_Codeword,
            ErrInj_BitFlip => In_ErrInj_BitFlip,
            ErrInj_Valid   => In_ErrInj_Valid
        );

    -- Base async FIFO with codeword-wide word
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
            In_Clk       => In_Clk,
            In_Rst       => In_Rst,
            In_RstOut    => In_RstOut,
            In_Data      => EncOut_Codeword,
            In_Valid     => EncOut_Valid,
            In_Ready     => EncOut_Ready,
            In_Full      => In_Full,
            In_Empty     => In_Empty,
            In_AlmFull   => In_AlmFull,
            In_AlmEmpty  => In_AlmEmpty,
            In_Level     => In_Level,
            Out_Clk      => Out_Clk,
            Out_Rst      => Out_Rst,
            Out_RstOut   => Fifo_OutRst,
            Out_Data     => FifoOut_Codeword,
            Out_Valid    => FifoOut_Valid,
            Out_Ready    => FifoOut_Ready,
            Out_Full     => Out_Full,
            Out_Empty    => Out_Empty,
            Out_AlmFull  => Out_AlmFull,
            Out_AlmEmpty => Out_AlmEmpty,
            Out_Level    => Out_Level
        );

    -- Decoder (output clock domain). Own pipeline stages via EccPipeline_g and AXI-S handshake
    -- propagate FIFO Out_Valid/Out_Ready to the user.
    i_dec : entity work.olo_ft_ecc_decode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => EccPipeline_g,
            UseReady_g => true
        )
        port map (
            Clk            => Out_Clk,
            Rst            => Fifo_OutRst,
            In_Valid       => FifoOut_Valid,
            In_Ready       => FifoOut_Ready,
            In_Codeword    => FifoOut_Codeword,
            Out_Valid      => Out_Valid,
            Out_Ready      => Out_Ready,
            Out_Data       => Out_Data,
            Out_EccSec     => Out_EccSec,
            Out_EccDed     => Out_EccDed,
            ErrInj_BitFlip => (others => '0'),
            ErrInj_Valid   => '0'
        );

end architecture;

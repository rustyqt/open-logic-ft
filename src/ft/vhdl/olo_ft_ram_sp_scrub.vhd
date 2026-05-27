---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected single-port RAM with an opportunistic memory scrubber. Wraps
-- `olo_ft_ram_sp` and `olo_ft_ram_scrubber`. The user-facing interface is
-- identical to `olo_ft_ram_sp` plus four scrubber-status outputs.
--
-- The scrubber walks the address space autonomously and writes corrected data
-- back when a single-bit error is detected. Because the underlying RAM is
-- single-port, the scrubber only issues a read or a writeback on cycles where
-- the user is doing neither (`WrEna='0' and RdEna='0'`); user accesses are
-- never stalled. If the user writes to the address currently being scrubbed
-- at any point between the scrubber's read and writeback, the writeback is
-- aborted and user data is authoritative.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_ram_sp_scrub.md
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
entity olo_ft_ram_sp_scrub is
    generic (
        Depth_g        : positive;
        Width_g        : positive;
        RamRdLatency_g : positive             := 1;
        RamStyle_g     : string               := "auto";
        RamBehavior_g  : string               := "RBW";
        EccPipeline_g  : natural range 0 to 2 := 0
    );
    port (
        -- Clock and Reset
        Clk             : in    std_logic;
        Rst             : in    std_logic                                                := '0';
        -- FT RAM Port
        Addr            : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        WrEna           : in    std_logic                                                := '1';
        WrData          : in    std_logic_vector(Width_g - 1 downto 0);
        RdEna           : in    std_logic                                                := '1';
        RdData          : out   std_logic_vector(Width_g - 1 downto 0);
        RdValid         : out   std_logic;
        RdEccSec        : out   std_logic;
        RdEccDed        : out   std_logic;
        -- Error Injection
        ErrInj_BitFlip  : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        ErrInj_Valid    : in    std_logic                                                := '0';
        -- Scrubber Control. '0' suspends the scrubber FSM combinationally; the address counter
        -- is preserved so scrubbing resumes from the same address on '1'. Use this to pin the
        -- scrubber down during ECC error-injection tests.
        Scrub_Enable    : in    std_logic                                                := '1';
        -- Scrubber Status. Scrub_Rd_EccSec / Scrub_Rd_EccDed are valid only when
        -- Scrub_Rd_Valid='1' (cycle the scrubber's own read returns from the codec).
        Scrub_Rd_Valid  : out   std_logic;
        Scrub_Rd_EccSec : out   std_logic;
        Scrub_Rd_EccDed : out   std_logic;
        Scrub_PassDone  : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ram_sp_scrub is

    constant AddrWidth_c : positive := log2ceil(Depth_g);

    -- Scrubber-driven request signals. Scrub_Rd_Ena and Scrub_Wr_Ena are mutually exclusive,
    -- so a single Scrub_Addr feeds the inner RAM's address regardless of read vs. write.
    signal Scrub_Rd_Ena       : std_logic;
    signal Scrub_Wr_Ena       : std_logic;
    signal Scrub_Addr         : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal Scrub_Wr_Data      : std_logic_vector(Width_g - 1 downto 0);
    -- Internal alias of the scrubber's Scrub_Rd_Valid output. Used both for masking the
    -- user-facing RdValid and for driving the wrapper's Scrub_Rd_Valid port. Avoids
    -- relying on VHDL-2008 read-from-out-port (poor synthesis-tool adoption).
    signal Scrub_Rd_Valid_Int : std_logic;

    -- Combined "port is busy this cycle". Single-port RAM: user wins for both reads and
    -- writes; scrubber only acts on truly idle cycles.
    signal User_PortBusy : std_logic;

    -- Combined inhibit signal for the scrubber: high when either the user is using the
    -- port (transient contention) or the wrapper's external Scrub_Enable is deasserted
    -- (deliberate pause). The scrubber treats both cases the same way.
    signal Scrub_Inhibit : std_logic;

    -- Muxed inputs to the inner olo_ft_ram_sp. User priority is mutually
    -- exclusive with scrubber requests because the scrubber asserts its own
    -- *_Ena only when User_PortBusy = '0'.
    signal Ram_Addr   : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal Ram_WrEna  : std_logic;
    signal Ram_WrData : std_logic_vector(Width_g - 1 downto 0);
    signal Ram_RdEna  : std_logic;

    -- Decoded read outputs tapped from olo_ft_ram_sp; forwarded to user and
    -- observed by the scrubber on the same cycle. Ram_RdValid pulses for any
    -- read (user or scrubber); the wrapper masks out the scrubber-owned cycles
    -- using Scrub_Rd_Valid (no wrapper-side shift register needed).
    signal Dec_RdData   : std_logic_vector(Width_g - 1 downto 0);
    signal Dec_RdEccSec : std_logic;
    signal Dec_RdEccDed : std_logic;
    signal Ram_RdValid  : std_logic;

begin

    User_PortBusy <= WrEna or RdEna;
    Scrub_Inhibit <= User_PortBusy or not Scrub_Enable;

    -- Bus mux: user always wins. Scrub_*_Ena are guaranteed '0' while User_PortBusy='1'
    -- (via Scrub_Inhibit). ErrInj_BitFlip / ErrInj_Valid pass straight through to the
    -- codec's latch -- see the "Error Injection" note in the doc for the interaction with
    -- scrubber writebacks.
    Ram_Addr   <= Addr   when User_PortBusy = '1' else Scrub_Addr;
    Ram_WrEna  <= WrEna  or  Scrub_Wr_Ena;
    Ram_WrData <= WrData when WrEna = '1'         else Scrub_Wr_Data;
    Ram_RdEna  <= RdEna  or  Scrub_Rd_Ena;

    -- Inner ECC-protected RAM (encoder + olo_base_ram_sp + decoder).
    i_ram_sp : entity work.olo_ft_ram_sp
        generic map (
            Depth_g        => Depth_g,
            Width_g        => Width_g,
            RamRdLatency_g => RamRdLatency_g,
            RamStyle_g     => RamStyle_g,
            RamBehavior_g  => RamBehavior_g,
            EccPipeline_g  => EccPipeline_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Addr           => Ram_Addr,
            WrEna          => Ram_WrEna,
            WrData         => Ram_WrData,
            RdEna          => Ram_RdEna,
            RdData         => Dec_RdData,
            RdValid        => Ram_RdValid,
            RdEccSec       => Dec_RdEccSec,
            RdEccDed       => Dec_RdEccDed,
            ErrInj_BitFlip => ErrInj_BitFlip,
            ErrInj_Valid   => ErrInj_Valid
        );

    -- Opportunistic scrubber. The scrubber's status outputs drive the wrapper's status ports
    -- directly. Request signals feed the muxes above.
    i_scrubber : entity work.olo_ft_ram_scrubber
        generic map (
            Depth_g            => Depth_g,
            Width_g            => Width_g,
            TotalReadLatency_g => RamRdLatency_g + EccPipeline_g
        )
        port map (
            Clk             => Clk,
            Rst             => Rst,
            Scrub_Inhibit   => Scrub_Inhibit,
            Ram_Rd_Data     => Dec_RdData,
            Ram_Rd_EccSec   => Dec_RdEccSec,
            Ram_Rd_EccDed   => Dec_RdEccDed,
            Scrub_Rd_Ena    => Scrub_Rd_Ena,
            Scrub_Wr_Ena    => Scrub_Wr_Ena,
            Scrub_Addr      => Scrub_Addr,
            Scrub_Wr_Data   => Scrub_Wr_Data,
            Scrub_Rd_Valid  => Scrub_Rd_Valid_Int,
            Scrub_Rd_EccSec => Scrub_Rd_EccSec,
            Scrub_Rd_EccDed => Scrub_Rd_EccDed,
            Scrub_PassDone  => Scrub_PassDone
        );

    -- Forward decoder outputs; mask Ram_RdValid for cycles the scrubber owned the read. The
    -- shift register that would have aligned a "user vs scrubber" tag through the read pipeline
    -- is implemented for free by the scrubber FSM's WaitCnt -- see olo_ft_ram_scrubber.
    RdData         <= Dec_RdData;
    RdEccSec       <= Dec_RdEccSec;
    RdEccDed       <= Dec_RdEccDed;
    RdValid        <= Ram_RdValid and not Scrub_Rd_Valid_Int;
    Scrub_Rd_Valid <= Scrub_Rd_Valid_Int;

end architecture;

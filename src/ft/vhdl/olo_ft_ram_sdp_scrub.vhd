---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected simple dual-port RAM with an opportunistic memory scrubber.
-- Wraps `olo_ft_ram_sdp` and `olo_ft_ram_scrubber`. The user-facing interface
-- mirrors `olo_ft_ram_sdp` (write port + read port) plus the scrubber control
-- and status ports.
--
-- The scrubber walks the address space autonomously and writes corrected data
-- back when a single-bit error is detected. It is fundamentally synchronous --
-- there is no `IsAsync_g` generic and no `Rd_Clk` / `Rd_Rst` port; the
-- scrubber observes user accesses on a single clock to pick idle cycles. The
-- write and read ports operate independently (dual port), so the scrubber
-- issues its read only when `Rd_Ena = '0'` and its writeback only when
-- `Wr_Ena = '0'`; user accesses are never stalled.
--
-- If the user writes to the address currently being scrubbed at any point
-- between the scrubber's read and writeback, the writeback is aborted and
-- user data is authoritative.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_ram_sdp_scrub.md
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
entity olo_ft_ram_sdp_scrub is
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
        -- Write Port
        Wr_Addr         : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Wr_Ena          : in    std_logic                                                := '1';
        Wr_Data         : in    std_logic_vector(Width_g - 1 downto 0);
        -- Read Port
        Rd_Addr         : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Rd_Ena          : in    std_logic                                                := '1';
        Rd_Data         : out   std_logic_vector(Width_g - 1 downto 0);
        Rd_Valid        : out   std_logic;
        Rd_EccSec       : out   std_logic;
        Rd_EccDed       : out   std_logic;
        -- Error Injection
        ErrInj_BitFlip  : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        ErrInj_Valid    : in    std_logic                                                := '0';
        -- Scrubber Control
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
architecture rtl of olo_ft_ram_sdp_scrub is

    constant AddrWidth_c : positive := log2ceil(Depth_g);

    -- Scrubber-driven request signals. Scrub_Rd_Ena and Scrub_Wr_Ena are mutually exclusive,
    -- so a single Scrub_Addr feeds both the write-port and read-port muxes below.
    signal Scrub_Rd_Ena       : std_logic;
    signal Scrub_Wr_Ena       : std_logic;
    signal Scrub_Addr         : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal Scrub_Wr_Data      : std_logic_vector(Width_g - 1 downto 0);
    -- Internal alias of the scrubber's Scrub_Rd_Valid output. Used both for masking the
    -- user-facing Rd_Valid and for driving the wrapper's Scrub_Rd_Valid port. Avoids
    -- relying on VHDL-2008 read-from-out-port (poor synthesis-tool adoption).
    signal Scrub_Rd_Valid_Int : std_logic;

    -- Muxed inputs to the inner olo_ft_ram_sdp. Write and read ports are independent (dual port);
    -- the scrubber asserts its own Wr/Rd_Ena only when both user *_Ena = '0' (the scrubber sees
    -- a single combined User_PortBusy signal, see below).
    signal Ram_Wr_Addr : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal Ram_Wr_Ena  : std_logic;
    signal Ram_Wr_Data : std_logic_vector(Width_g - 1 downto 0);
    signal Ram_Rd_Addr : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal Ram_Rd_Ena  : std_logic;

    -- Combined inhibit signal for the scrubber: high when either the user is using one of
    -- the ports (any read or write) or the wrapper's external Scrub_Enable is deasserted.
    -- The scrubber treats both cases the same way (gate new bus issuance, abort any
    -- in-flight operation to Idle).
    signal Scrub_Inhibit : std_logic;

    -- Decoded read outputs tapped from olo_ft_ram_sdp; forwarded to user and observed by the
    -- scrubber. Ram_Rd_Valid pulses for any read (user or scrubber); the wrapper masks out
    -- scrubber-owned cycles using Scrub_Rd_Valid.
    signal Dec_Rd_Data   : std_logic_vector(Width_g - 1 downto 0);
    signal Dec_Rd_EccSec : std_logic;
    signal Dec_Rd_EccDed : std_logic;
    signal Ram_Rd_Valid  : std_logic;

begin

    -- Write-path mux: user wins (Scrub_Inhibit gates Scrub_Wr_Ena while Wr_Ena='1'). When
    -- the scrubber drives the write, Ram_Rd_Data is passed combinationally through the
    -- scrubber to Scrub_Wr_Data; the inner codec re-encodes it on the way back into RAM.
    Ram_Wr_Addr <= Wr_Addr when Wr_Ena = '1' else Scrub_Addr;
    Ram_Wr_Ena  <= Wr_Ena  or  Scrub_Wr_Ena;
    Ram_Wr_Data <= Wr_Data when Wr_Ena = '1' else Scrub_Wr_Data;

    -- Read-path mux: same priority rule.
    Ram_Rd_Addr <= Rd_Addr when Rd_Ena = '1' else Scrub_Addr;
    Ram_Rd_Ena  <= Rd_Ena  or  Scrub_Rd_Ena;

    -- Inner ECC-protected SDP RAM (encoder + olo_base_ram_sdp + decoder). Sync-only here
    -- (IsAsync_g => false), since the scrubber requires single-clock operation.
    i_ram_sdp : entity work.olo_ft_ram_sdp
        generic map (
            Depth_g        => Depth_g,
            Width_g        => Width_g,
            IsAsync_g      => false,
            RamRdLatency_g => RamRdLatency_g,
            RamStyle_g     => RamStyle_g,
            RamBehavior_g  => RamBehavior_g,
            EccPipeline_g  => EccPipeline_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Rd_Clk         => '0',
            Rd_Rst         => '0',
            Wr_Addr        => Ram_Wr_Addr,
            Wr_Ena         => Ram_Wr_Ena,
            Wr_Data        => Ram_Wr_Data,
            Rd_Addr        => Ram_Rd_Addr,
            Rd_Ena         => Ram_Rd_Ena,
            Rd_Data        => Dec_Rd_Data,
            Rd_Valid       => Ram_Rd_Valid,
            Rd_EccSec      => Dec_Rd_EccSec,
            Rd_EccDed      => Dec_Rd_EccDed,
            ErrInj_BitFlip => ErrInj_BitFlip,
            ErrInj_Valid   => ErrInj_Valid
        );

    Scrub_Inhibit <= Wr_Ena or Rd_Ena or not Scrub_Enable;

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
            Ram_Rd_Data     => Dec_Rd_Data,
            Ram_Rd_EccSec   => Dec_Rd_EccSec,
            Ram_Rd_EccDed   => Dec_Rd_EccDed,
            Scrub_Rd_Ena    => Scrub_Rd_Ena,
            Scrub_Wr_Ena    => Scrub_Wr_Ena,
            Scrub_Addr      => Scrub_Addr,
            Scrub_Wr_Data   => Scrub_Wr_Data,
            Scrub_Rd_Valid  => Scrub_Rd_Valid_Int,
            Scrub_Rd_EccSec => Scrub_Rd_EccSec,
            Scrub_Rd_EccDed => Scrub_Rd_EccDed,
            Scrub_PassDone  => Scrub_PassDone
        );

    -- Forward decoder outputs; mask Ram_Rd_Valid for cycles the scrubber owned the read.
    Rd_Data        <= Dec_Rd_Data;
    Rd_EccSec      <= Dec_Rd_EccSec;
    Rd_EccDed      <= Dec_Rd_EccDed;
    Rd_Valid       <= Ram_Rd_Valid and not Scrub_Rd_Valid_Int;
    Scrub_Rd_Valid <= Scrub_Rd_Valid_Int;

end architecture;

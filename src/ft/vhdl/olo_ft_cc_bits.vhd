---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- TMR-hardened multi-bit clock domain crossing for level signals. Implements the long-pulse
-- TMR synchronizer from Li, Nelson, Wirthlin, "Synchronization Techniques for Crossing Multiple
-- Clock Domains in FPGA-Based TMR Circuits", IEEE TNS 2010 (Fig. 12): three independent
-- N-stage synchronizer chains with a per-bit majority voter at the output. Provides
-- single-SEU immunity for level-signal CDC in radiation-hardened designs.
--
-- Topology, per bit:
--
--   In_Data[i] --+--> RegIn_A --> Reg0_A --> RegN_A(0..) --.
--                |                                          \
--                +--> RegIn_B --> Reg0_B --> RegN_B(0..) ----+--> Voter --> Out_Data[i]
--                |                                          /
--                +--> RegIn_C --> Reg0_C --> RegN_C(0..) --'
--
-- All sender-side registers (RegIn_*) are clocked by In_Clk. All receiver-side registers
-- (Reg0_*, RegN_*) are clocked by Out_Clk. Each chain is independently triplicated to survive
-- a single SEU. The voter produces the 2-of-3 majority on each output bit.
--
-- This component is the fault-tolerant counterpart of olo_base_cc_bits with the same interface.
-- It is suitable for arbitrary multi-bit level signals (including Gray-coded pointers and
-- generic control signals). For pulse signals, consider olo_ft_cc_pulse instead.
--
-- Architecture notes:
-- - Manual TMR (triplicated chains + per-bit majority voter) combined with
--   syn_radhardlevel = "none" at the architecture level prevents double-triplication by
--   vendor TMR tools (e.g. Synplify for Microchip Libero).
-- - Standard CDC attributes (async_reg, dont_merge, preserve, etc.) are applied to each
--   triplicated register.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_cc_bits.md
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
    use work.olo_base_pkg_attribute.all;
    use work.olo_ft_pkg_attribute.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------

entity olo_ft_cc_bits is
    generic (
        Width_g      : positive              := 1;
        SyncStages_g : positive range 2 to 4 := 2
    );
    port (
        -- Input clock domain
        In_Clk   : in    std_logic;
        In_Rst   : in    std_logic := '0';
        In_Data  : in    std_logic_vector(Width_g - 1 downto 0);
        -- Output clock domain
        Out_Clk  : in    std_logic;
        Out_Rst  : in    std_logic := '0';
        Out_Data : out   std_logic_vector(Width_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------

architecture struct of olo_ft_cc_bits is

    -----------------------------------------------------------------------------------------------
    -- Types
    -----------------------------------------------------------------------------------------------
    type SyncStages_t is array (0 to SyncStages_g - 2) of std_logic_vector(Width_g - 1 downto 0);

    -- One entry per TMR copy (0 = A, 1 = B, 2 = C)
    type Tmr_t       is array (0 to 2) of std_logic_vector(Width_g - 1 downto 0);
    type TmrStages_t is array (0 to 2) of SyncStages_t;

    -----------------------------------------------------------------------------------------------
    -- Signals
    -----------------------------------------------------------------------------------------------
    -- Triplicated synchronizer registers
    signal RegIn : Tmr_t       := (others => (others => '0'));
    signal Reg0  : Tmr_t       := (others => (others => '0'));
    signal RegN  : TmrStages_t := (others => (others => (others => '0')));

    -- Per-copy synchronizer output (= last sync stage of each chain)
    signal RcvSig : Tmr_t;

    -- Input clock signal (required for automatic constraining in Vivado)
    signal In_Clk_Sig : std_logic;

    -----------------------------------------------------------------------------------------------
    -- Architecture-level attribute: disable vendor-provided TMR insertion.
    -- Manual TMR is already in place below. Without this attribute, tools like Synplify for
    -- Microchip Libero would triplicate the already-triplicated registers.
    -----------------------------------------------------------------------------------------------
    attribute syn_radhardlevel of struct : architecture is SynRadhardlevel_None_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes - shiftregister extraction (prevent SRL inference)
    -----------------------------------------------------------------------------------------------
    attribute shreg_extract of Reg0  : signal is ShregExtract_SuppressExtraction_c;
    attribute shreg_extract of RegN  : signal is ShregExtract_SuppressExtraction_c;
    attribute shreg_extract of RegIn : signal is ShregExtract_SuppressExtraction_c;

    attribute syn_srlstyle of Reg0  : signal is SynSrlstyle_FlipFlops_c;
    attribute syn_srlstyle of RegN  : signal is SynSrlstyle_FlipFlops_c;
    attribute syn_srlstyle of RegIn : signal is SynSrlstyle_FlipFlops_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes - preserve registers (prevent merging of TMR copies)
    -----------------------------------------------------------------------------------------------
    attribute dont_merge of Reg0  : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of RegN  : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of RegIn : signal is DontMerge_SuppressChanges_c;

    attribute preserve of Reg0  : signal is Preserve_SuppressChanges_c;
    attribute preserve of RegN  : signal is Preserve_SuppressChanges_c;
    attribute preserve of RegIn : signal is Preserve_SuppressChanges_c;

    attribute syn_preserve of Reg0  : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of RegN  : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of RegIn : signal is SynPreserve_SuppressChanges_c;

    attribute syn_keep of Reg0  : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of RegN  : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of RegIn : signal is SynKeep_SuppressChanges_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes - async registers (metastability handling on first two sync FFs)
    -----------------------------------------------------------------------------------------------
    attribute async_reg of Reg0  : signal is AsyncReg_TreatAsync_c;
    attribute async_reg of RegN  : signal is AsyncReg_TreatAsync_c;
    attribute async_reg of RegIn : signal is AsyncReg_TreatAsync_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes automatic constraining (AMD only)
    -----------------------------------------------------------------------------------------------
    attribute dont_touch of In_Clk_Sig : signal is DontTouch_SuppressChanges_c;
    attribute keep of In_Clk_Sig       : signal is Keep_SuppressChanges_c;

begin

    In_Clk_Sig <= In_Clk;

    -----------------------------------------------------------------------------------------------
    -- Input registers (triplicated) in the sender's domain
    -----------------------------------------------------------------------------------------------
    p_inff : process (In_Clk) is
    begin
        if rising_edge(In_Clk) then

            for i in 0 to 2 loop
                RegIn(i) <= In_Data;
            end loop;

            if In_Rst = '1' then
                RegIn <= (others => (others => '0'));
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Synchronizer chains (triplicated) in the receiver's domain
    -----------------------------------------------------------------------------------------------
    p_outff : process (Out_Clk) is
    begin
        if rising_edge(Out_Clk) then

            for i in 0 to 2 loop
                -- First two stages
                Reg0(i)    <= RegIn(i);
                RegN(i)(0) <= Reg0(i);

                -- Remaining stages (loop only active when SyncStages_g > 2)
                for s in 1 to SyncStages_g - 2 loop
                    RegN(i)(s) <= RegN(i)(s - 1);
                end loop;

            end loop;

            -- Reset
            if Out_Rst = '1' then
                Reg0 <= (others => (others => '0'));
                RegN <= (others => (others => (others => '0')));
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Per-copy synchronizer output (= last sync stage in each chain)
    -----------------------------------------------------------------------------------------------
    RcvSig(0) <= RegN(0)(SyncStages_g - 2);
    RcvSig(1) <= RegN(1)(SyncStages_g - 2);
    RcvSig(2) <= RegN(2)(SyncStages_g - 2);

    -----------------------------------------------------------------------------------------------
    -- Per-bit majority voter: Out[i] = (A*B) + (B*C) + (A*C)
    -----------------------------------------------------------------------------------------------
    Out_Data <= (RcvSig(0) and RcvSig(1)) or
                (RcvSig(1) and RcvSig(2)) or
                (RcvSig(0) and RcvSig(2));

end architecture;

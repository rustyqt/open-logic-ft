---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- TMR-hardened single-pulse clock domain crossing. Implements the modified short-pulse
-- synchronizer from Li, Nelson, Wirthlin, "Synchronization Techniques for Crossing Multiple
-- Clock Domains in FPGA-Based TMR Circuits", IEEE TNS 2010 (Fig. 14), triplicated per Fig. 11
-- of the same paper with a per-bit majority voter at the output. This provides provable
-- single-SEU immunity for pulse-based clock domain crossing in radiation-hardened designs.
--
-- Pulse semantics follow olo_base_cc_pulse: each bit of In_Pulse is a pulse that must return to
-- zero before the feedback round-trip completes (i.e., suitable for short pulses, not sustained
-- levels). Each input pulse produces one corresponding output pulse in the receiver's domain.
--
-- Topology per TMR copy, per bit (Li Fig. 14):
--
--   In_Pulse[i] --> [S   Q]-- LatchOut --> [D FF1 Q]-- Ff1Out --.
--                   [R    ]<---------------------------.        |
--                      ^                               |       .---. Ff2In
--                      |                               +------>|AND|-----> [D FF2 Q]--> [D FF3 Q]--> RcvSig[X][i]
--                      |                               | ^     '---'                              |
--                      |                               | o(inv)                                   |
--                      +-------------------------------'-------------------------------- feedback-'
--
-- The SR latch (level-sensitive, intentional latch) converts the pulse into a stable level. The
-- level crosses the clock domain through FF1 and FF2, with FF3 (+ optional FF4 for
-- SyncStages_g=4) stretching the received pulse so the downstream voter sees sufficient overlap
-- across all three TMR copies even under worst-case sampling uncertainty. The feedback from the
-- last FF resets the SR latch and simultaneously gates the AND gate, producing a clean single
-- pulse at the receiver.
--
-- Timing constraints (user responsibility, matching Li paper Section V.B):
-- - Input pulse must return to zero before the feedback arrives back at the SR latch.
--   Approximately: T_pulse_in < SyncStages_g * T_out + 2 * T_in. For typical pulse
--   inputs (single sender-clock cycle), this is satisfied when the sender clock is not
--   drastically faster than the receiver clock.
-- - Minimum spacing between consecutive pulses on the same bit is the full feedback round-trip
--   time (approximately 2 * SyncStages_g + 2 receiver clock cycles).
-- - Output pulse width: SyncStages_g - 1 receiver clock cycles.
--
-- Architecture notes:
-- - Manual TMR (triplicated synchronizer + per-bit majority voter) combined with
--   syn_radhardlevel = "none" at the architecture level prevents double-triplication by
--   vendor TMR tools (e.g. Synplify for Microchip Libero).
-- - Intentional latch inference is used for the SR latch (matches the paper exactly).
--   Synthesis warnings about latches are expected and can be ignored for this entity.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_cc_pulse.md
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

entity olo_ft_cc_pulse is
    generic (
        NumPulses_g  : positive              := 1;
        SyncStages_g : positive range 3 to 4 := 3
    );
    port (
        -- Input clock domain
        In_Clk     : in    std_logic;
        In_RstIn   : in    std_logic := '0';
        In_RstOut  : out   std_logic;
        In_Pulse   : in    std_logic_vector(NumPulses_g - 1 downto 0);
        -- Output clock domain
        Out_Clk    : in    std_logic;
        Out_RstIn  : in    std_logic := '0';
        Out_RstOut : out   std_logic;
        Out_Pulse  : out   std_logic_vector(NumPulses_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------

architecture struct of olo_ft_cc_pulse is

    -----------------------------------------------------------------------------------------------
    -- Types
    -----------------------------------------------------------------------------------------------
    -- One entry per TMR copy (0 = A, 1 = B, 2 = C)
    type Tmr_t is array (0 to 2) of std_logic_vector(NumPulses_g - 1 downto 0);

    -----------------------------------------------------------------------------------------------
    -- Signals
    -----------------------------------------------------------------------------------------------
    -- Resets (crossed via olo_base_cc_reset)
    signal RstInI  : std_logic;
    signal RstOutI : std_logic;

    -- Sender's domain: intentional SR latches (one per TMR copy, per bit)
    signal LatchOut : Tmr_t := (others => (others => '0'));

    -- Receiver's domain synchronizer chains
    signal Ff1Out : Tmr_t := (others => (others => '0'));
    signal Ff2In  : Tmr_t; -- combinational: Ff1Out AND NOT Feedback
    signal Ff2Out : Tmr_t := (others => (others => '0'));
    signal Ff3Out : Tmr_t := (others => (others => '0'));
    signal Ff4Out : Tmr_t := (others => (others => '0')); -- used only when SyncStages_g = 4

    -- Per-copy receiver-domain output (= last FF in chain)
    signal RcvSig : Tmr_t;

    -- Feedback path: from RcvSig back to SR latch reset and AND gate
    signal Feedback : Tmr_t;

    -- Input clock signal (required for automatic constraining in Vivado)
    signal In_Clk_Sig : std_logic;

    -----------------------------------------------------------------------------------------------
    -- Architecture-level attribute: disable vendor-provided TMR insertion
    -- A custom TMR implementation (triplication + majority voter) is already in place below.
    -- Without this attribute, tools like Synplify for Microchip Libero would triplicate the
    -- already-triplicated registers, wasting resources and potentially causing incorrect
    -- voting behavior.
    -----------------------------------------------------------------------------------------------
    attribute syn_radhardlevel of struct : architecture is SynRadhardlevel_None_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes - shiftregister extraction (prevent SRL inference)
    -----------------------------------------------------------------------------------------------
    attribute shreg_extract of LatchOut : signal is ShregExtract_SuppressExtraction_c;
    attribute shreg_extract of Ff1Out   : signal is ShregExtract_SuppressExtraction_c;
    attribute shreg_extract of Ff2Out   : signal is ShregExtract_SuppressExtraction_c;
    attribute shreg_extract of Ff3Out   : signal is ShregExtract_SuppressExtraction_c;
    attribute shreg_extract of Ff4Out   : signal is ShregExtract_SuppressExtraction_c;

    attribute syn_srlstyle of LatchOut : signal is SynSrlstyle_FlipFlops_c;
    attribute syn_srlstyle of Ff1Out   : signal is SynSrlstyle_FlipFlops_c;
    attribute syn_srlstyle of Ff2Out   : signal is SynSrlstyle_FlipFlops_c;
    attribute syn_srlstyle of Ff3Out   : signal is SynSrlstyle_FlipFlops_c;
    attribute syn_srlstyle of Ff4Out   : signal is SynSrlstyle_FlipFlops_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes - preserve registers (prevent merging of TMR copies)
    -----------------------------------------------------------------------------------------------
    attribute dont_merge of LatchOut : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of Ff1Out   : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of Ff2Out   : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of Ff3Out   : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of Ff4Out   : signal is DontMerge_SuppressChanges_c;

    attribute preserve of LatchOut : signal is Preserve_SuppressChanges_c;
    attribute preserve of Ff1Out   : signal is Preserve_SuppressChanges_c;
    attribute preserve of Ff2Out   : signal is Preserve_SuppressChanges_c;
    attribute preserve of Ff3Out   : signal is Preserve_SuppressChanges_c;
    attribute preserve of Ff4Out   : signal is Preserve_SuppressChanges_c;

    attribute syn_preserve of LatchOut : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of Ff1Out   : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of Ff2Out   : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of Ff3Out   : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of Ff4Out   : signal is SynPreserve_SuppressChanges_c;

    attribute syn_keep of LatchOut : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of Ff1Out   : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of Ff2Out   : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of Ff3Out   : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of Ff4Out   : signal is SynKeep_SuppressChanges_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes - async registers (metastability handling on first two receiver FFs)
    -----------------------------------------------------------------------------------------------
    attribute async_reg of Ff1Out : signal is AsyncReg_TreatAsync_c;
    attribute async_reg of Ff2Out : signal is AsyncReg_TreatAsync_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes automatic constraining (AMD only)
    -----------------------------------------------------------------------------------------------
    attribute dont_touch of In_Clk_Sig : signal is DontTouch_SuppressChanges_c;
    attribute keep of In_Clk_Sig       : signal is Keep_SuppressChanges_c;

begin

    In_Clk_Sig <= In_Clk;

    -----------------------------------------------------------------------------------------------
    -- Reset crossing between the two clock domains (TMR-hardened)
    -----------------------------------------------------------------------------------------------
    i_rst : entity work.olo_ft_cc_reset
        port map (
            A_Clk    => In_Clk,
            A_RstIn  => In_RstIn,
            A_RstOut => RstInI,
            B_Clk    => Out_Clk,
            B_RstIn  => Out_RstIn,
            B_RstOut => RstOutI
        );

    In_RstOut  <= RstInI;
    Out_RstOut <= RstOutI;

    -----------------------------------------------------------------------------------------------
    -- Feedback paths: last FF's output feeds back to the SR latch reset and the AND gate.
    -- The feedback signal also crosses the clock domain (receiver -> sender), but this is safe
    -- because the SR latch is level-sensitive (asynchronous).
    -----------------------------------------------------------------------------------------------
    g_rcv_3stage : if SyncStages_g = 3 generate
        RcvSig(0) <= Ff3Out(0);
        RcvSig(1) <= Ff3Out(1);
        RcvSig(2) <= Ff3Out(2);
    end generate;

    g_rcv_4stage : if SyncStages_g = 4 generate
        RcvSig(0) <= Ff4Out(0);
        RcvSig(1) <= Ff4Out(1);
        RcvSig(2) <= Ff4Out(2);
    end generate;

    Feedback(0) <= RcvSig(0);
    Feedback(1) <= RcvSig(1);
    Feedback(2) <= RcvSig(2);

    -----------------------------------------------------------------------------------------------
    -- Intentional SR latches in the sender's domain (one per TMR copy, per bit).
    -- Level-sensitive, Set has priority over Reset (matches Li Fig. 14).
    -----------------------------------------------------------------------------------------------
    g_latch : for i in 0 to 2 generate

        p_latch : process (all) is
        begin
            for b in 0 to NumPulses_g - 1 loop
                if RstInI = '1' then
                    LatchOut(i)(b) <= '0';
                elsif In_Pulse(b) = '1' then
                    LatchOut(i)(b) <= '1';
                elsif Feedback(i)(b) = '1' then
                    LatchOut(i)(b) <= '0';
                end if;
            end loop;
        end process;

    end generate;

    -----------------------------------------------------------------------------------------------
    -- AND gate with inverted feedback: gates off the propagation through FF2 as soon as the
    -- output pulse has been produced (self-clearing mechanism).
    -----------------------------------------------------------------------------------------------
    Ff2In(0) <= Ff1Out(0) and not Feedback(0);
    Ff2In(1) <= Ff1Out(1) and not Feedback(1);
    Ff2In(2) <= Ff1Out(2) and not Feedback(2);

    -----------------------------------------------------------------------------------------------
    -- Receiver's domain synchronizer chains: FF1 -> AND -> FF2 -> FF3 (-> FF4)
    -----------------------------------------------------------------------------------------------
    p_sync : process (Out_Clk) is
    begin
        if rising_edge(Out_Clk) then

            -- Propagate through each chain
            for i in 0 to 2 loop
                Ff1Out(i) <= LatchOut(i);
                Ff2Out(i) <= Ff2In(i);
                Ff3Out(i) <= Ff2Out(i);
                Ff4Out(i) <= Ff3Out(i);
            end loop;

            -- Reset
            if RstOutI = '1' then
                Ff1Out <= (others => (others => '0'));
                Ff2Out <= (others => (others => '0'));
                Ff3Out <= (others => (others => '0'));
                Ff4Out <= (others => (others => '0'));
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Per-bit majority voter: Out[i] = (A*B) + (B*C) + (A*C)
    -----------------------------------------------------------------------------------------------
    Out_Pulse <= (RcvSig(0) and RcvSig(1)) or
                 (RcvSig(1) and RcvSig(2)) or
                 (RcvSig(0) and RcvSig(2));

end architecture;

---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Package containing synthesis attribute definitions specific to fault-tolerant (ft) designs.
-- These attributes are typically vendor-specific and only relevant for radiation-hardened
-- implementations. General purpose synthesis attributes are kept in olo_base_pkg_attribute.
--
-- The package is meant for Open Logic internal use and hence not documented in detail.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

---------------------------------------------------------------------------------------------------
-- Package Header
---------------------------------------------------------------------------------------------------
package olo_ft_pkg_attribute is

    -- *** Disable/Control Vendor-Provided TMR Insertion ***
    --
    -- Tools:
    -- - Synplify (Microchip Libero)
    --
    -- Controls automatic TMR insertion by the synthesis tool.
    -- Apply "none" at architecture level when a custom TMR implementation is already in place
    -- to prevent the tool from triplicating already-triplicated registers.
    attribute syn_radhardlevel : string;
    constant SynRadhardlevel_None_c   : string := "none";
    constant SynRadhardlevel_Cc_c     : string := "cc";
    constant SynRadhardlevel_Tmr_c    : string := "tmr";
    constant SynRadhardlevel_TmrCc_c  : string := "tmr_cc";

end package;

---------------------------------------------------------------------------------------------------
-- Package Body
---------------------------------------------------------------------------------------------------
package body olo_ft_pkg_attribute is

end package body;

# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2025 by Oliver Bruendler
# All rights reserved.
# Authors: Oliver Bruendler
# ---------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------------------------------
from .utils import named_config

# ---------------------------------------------------------------------------------------------------
# Functionality
# ---------------------------------------------------------------------------------------------------

def add_configs(olo_tb):
    """
    Add all fault-tolerant testbench configurations to the VUnit Library
    :param olo_tb: Testbench library
    """

    ### olo_ft_ram_tdp ###
    tb = olo_tb.test_bench('olo_ft_ram_tdp_tb')
    for RamBehav in ['RBW', 'WBR']:
        named_config(tb, {'RamBehavior_g': RamBehav})
    for ReadLatency in [1, 2]:
        named_config(tb, {'RdLatency_g': ReadLatency})
    for Width in [8, 16, 32, 64]:
        named_config(tb, {'Width_g': Width})

    ### olo_ft_ram_sdp ###
    tb = olo_tb.test_bench('olo_ft_ram_sdp_tb')
    for RamBehav in ['RBW', 'WBR']:
        for Async in [True, False]:
            named_config(tb, {'RamBehavior_g': RamBehav, 'IsAsync_g': Async})
    for ReadLatency in [1, 2]:
        named_config(tb, {'RdLatency_g': ReadLatency})
    for Width in [8, 16, 32, 64]:
        named_config(tb, {'Width_g': Width})

    ### olo_ft_ram_sp ###
    tb = olo_tb.test_bench('olo_ft_ram_sp_tb')
    for RamBehav in ['RBW', 'WBR']:
        named_config(tb, {'RamBehavior_g': RamBehav})
    for ReadLatency in [1, 2]:
        named_config(tb, {'RdLatency_g': ReadLatency})
    for Width in [8, 16, 32, 64]:
        named_config(tb, {'Width_g': Width})

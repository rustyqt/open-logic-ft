# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Open Logic is a VHDL-2008 standard library for FPGA development providing reusable, vendor-independent, thoroughly tested hardware components. All production code is pure VHDL (no vendor primitives). Python is used for test infrastructure, co-simulation, and tooling.

## Common Commands

### Simulation (VUnit)

```bash
# Run all tests (GHDL, 16 parallel threads)
python3 sim/run.py -p 16

# Run tests matching a pattern (e.g., a specific testbench)
python3 sim/run.py -p 16 "*olo_base_fifo_sync*"

# Run with NVC simulator instead of GHDL
python3 sim/run.py --nvc -p 16

# Run with waveform output
python3 sim/run.py -p 16 --gtkwave-fmt=ghw "*olo_base_fifo_sync*"

# List all test cases without running
python3 sim/run.py --list
```

### Linting (VSG - VHDL Style Guide)

```bash
# Lint a single VHDL file (production code or testbench)
vsg -c ./lint/config/vsg_config.yml -f <file>

# Lint a single Verification Component file (test/tb/*.vhd)
vsg -c ./lint/config/vsg_config.yml ./lint/config/vsg_config_overlay_vc.yml -f <file>

# Lint all VHDL files
python3 lint/script/script.py

# Lint all with debug mode (stops on first error)
python3 lint/script/script.py --debug
```

### Synthesis Testing

```bash
# Dry-run (syntax check only, no tool needed)
cd tools/inference_test && python3 InferenceTest.py --yml=yaml/base.yml --dry-run
```

## Architecture

### Source Organization

Code is organized into four functional areas under `src/`:
- **base** - Core building blocks: clock domain crossings, FIFOs, RAMs, arbiters, width converters, delays, strobes, CRC, PRBS, etc.
- **axi** - AXI4/AXI4-Lite/AXI4-Stream protocol components
- **intf** - External interface drivers: UART, SPI master/slave, I2C master, debouncing, clock measurement
- **fix** - Fixed-point math with Python bit-true co-simulation models (in `src/fix/python/`)

All source VHDL is compiled into a single library named `olo`.

### Test Organization

- `test/<area>/` - VUnit testbenches, one directory per entity (e.g., `test/base/olo_base_fifo_sync/`)
- `test/tb/` - Shared Verification Components (VCs) following VUnit snail_case convention
- `sim/test_configs/` - Parameterized test configurations (generics combinations per testbench)
- `sim/run.py` - Main VUnit test runner entry point

### Key Dependencies

- `3rdParty/en_cl_fix/` - Enclustra fixed-point library (git submodule)
- VUnit (simulation framework), VSG v3.25.0 (linting), GHDL or NVC (simulators)

## VHDL Conventions

### Naming

- **Entities**: `olo_<area>_<function>` (e.g., `olo_base_cc_bits`)
- **Ports**: `<Interface>_<Signal>` (e.g., `Param_TData`, `Param_TValid`) - no `_i`/`_o` suffixes
- **Generics**: `_g` suffix (e.g., `Width_g`)
- **Constants**: `_c` suffix
- **Variables**: `_v` suffix
- **Types**: `_t` suffix
- **FSM types**: `<name>Fsm_t` with state values using `_s` suffix
- **Functions**: lowerCamelCase
- **VCs only** (in `test/tb/`): snail_case per VUnit convention

### Coding Rules

- Indentation: 4 spaces, no tabs, no trailing whitespace
- Resets: always synchronous, high-active, implemented as override at end of process (not if/else at beginning) to minimize reset fanout
- Only state registers get reset; pipeline registers do not
- AXI4-Stream handshaking (Valid/Ready) used wherever handshaking is needed
- All optional generics and ports must have sensible defaults
- All linting errors AND warnings must be resolved for PRs

### Contribution Notes

- Feature branches: `feature/<name>`, branched from `develop`
- PRs target `develop` branch
- Every entity must have a VUnit testbench and markdown documentation
- CLA signing required via cla-assistant.io
- GenAI usage must be disclosed in PR description; forbidden for NLnet-funded features

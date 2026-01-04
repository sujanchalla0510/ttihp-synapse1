![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Synapse-1: Hybrid Neuromorphic Controller

Digital controller for external 8×8 Knowm memristor crossbar — validating analog compute-in-memory on Tiny Tapeout.

## Overview

This project implements a hybrid neuromorphic architecture:
- **TT Chip**: Digital SPI controller with row drivers and programming sequencer
- **External**: Knowm 8×8 W+SDC memristor crossbar (64 analog synapses)
- **Interface PCB**: TIA array + comparators for current-to-digital conversion

The hybrid approach validates real memristor behavior at ~$410 total cost before committing to integrated ReRAM fabrication.

## Architecture

```
┌─────────────────────┐         ┌─────────────────────┐
│  TT Chip (SG13G2)   │         │  Knowm 8×8 Crossbar │
│                     │         │                     │
│  ┌───────────────┐  │ uio[7:0]│  R0─●─●─●─●─●─●─●─● │
│  │ SPI Slave     │  │ ──────► │  R1─●─●─●─●─●─●─●─● │
│  │ Row Drivers   │  │ Row     │  ...               │
│  │ Sequencer     │  │ Drive   │  R7─●─●─●─●─●─●─●─● │
│  └───────────────┘  │         │     │ │ │ │ │ │ │ │ │
│                     │ ui[7:4] │    C0 C1...     C7  │
│  col_sense[3:0] ◄───┼─────────│    (via TIA)       │
└─────────────────────┘         └─────────────────────┘
```

## Specifications

| Parameter | Value |
|-----------|-------|
| Process | IHP SG13G2 (130nm) |
| Tile Size | 1×1 |
| Clock | 50 MHz |
| Interface | SPI Mode 0 |
| External Memristor | Knowm 8×8 W+SDC |
| Synapses | 64 (8 rows × 8 columns) |

## Pinout

### Dedicated Inputs (ui_in)

| Pin | Name | Description |
|-----|------|-------------|
| ui[0] | SPI_CS_N | Chip select (active low) |
| ui[1] | SPI_SCK | SPI clock |
| ui[2] | SPI_MOSI | SPI data in |
| ui[3] | PROG_EN | Programming enable (safety) |
| ui[7:4] | COL_SENSE | Column sense from TIA (4 bits) |

### Dedicated Outputs (uo_out)

| Pin | Name | Description |
|-----|------|-------------|
| uo[0] | SPI_MISO | SPI data out |
| uo[1] | READY | Controller ready |
| uo[2] | ERROR | Error flag |
| uo[3] | PROG_DONE | Programming complete |

### Bidirectional (uio) - Configured as Outputs

| Pin | Name | Description |
|-----|------|-------------|
| uio[7:0] | ROW_DRIVE | Row drivers to memristor array |

## SPI Commands

| Command | Code | Description |
|---------|------|-------------|
| NOP | 0x00 | No operation |
| SET_ROW | 0x01 | Set row driver values |
| READ_COL | 0x02 | Read column sense |
| PROG_CELL | 0x03 | Program cell (SET/RESET) |
| READ_STATUS | 0x04 | Read status register |
| FORM | 0x05 | Form memristor channel |
| SET_TIMING | 0x06 | Set pulse timing |
| READ_CELL | 0x07 | Read single cell |

## Bill of Materials

| Item | Cost |
|------|------|
| Knowm 8×8 W+SDC Crossbar | ~$385 |
| TT DemoBoard | (included) |
| Interface PCB + components | ~$25 |
| **Total** | **~$410** |

## Design Files

| File | Description |
|------|-------------|
| `src/project.v` | TT wrapper + Controller RTL |
| `info.yaml` | TT project configuration |
| `docs/info.md` | Detailed documentation |
| `test/` | Testbench files |

## External Hardware Required

1. **TT DemoBoard** — RP2040 for host SPI control
2. **Knowm 8×8 W+SDC** — Memristor crossbar (~$385)
3. **Interface PCB** containing:
   - 8× TIA (LMV324 quad op-amp × 2)
   - Comparators for threshold detection
   - PMOD connector

## Quick Start

```python
# On RP2040 (MicroPython)
import machine

spi = machine.SPI(0, baudrate=1_000_000, polarity=0, phase=0)
cs = machine.Pin(17, machine.Pin.OUT)

# Set row 0 active
cs.value(0)
spi.write(bytes([0x01, 0x01]))  # CMD_SET_ROW, row_mask
cs.value(1)

# Read columns
cs.value(0)
spi.write(bytes([0x02]))        # CMD_READ_COL
result = spi.read(1)
cs.value(1)
print(f"Columns: {result[0]:08b}")
```

## References

- [CMAX Project](https://github.com/sujanreddy/cmax) — Main development repo
- [Knowm Memristors](https://knowm.com/)
- [Tiny Tapeout](https://tinytapeout.com/)

## License

Apache-2.0

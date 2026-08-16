# FPGA Deployment References

These pages record representative out-of-context results and supported starting
configurations. They are not substitutes for timing closure in the complete
design.

| Board | Family | Suggested starting point |
|---|---|---|
| [U250](U250.md) | UltraScale+ | 512 KiB, 8 ways, SDP, 250 MHz |
| [U55C](U55C.md) | UltraScale+ HBM | 512 KiB, 8 ways, SDP, 250 MHz |
| [V80](V80.md) | Versal Premium ES | 512 KiB, 8 ways, SDP, 200 MHz |

Reference geometry:

```text
POLICY=GRASP
WAYS=8
LINES=1024
LINE_W=16
BLOCK_W=32
DB_LATENCY=2
DATABANK_SDP=1
INCLUDE_VICTIM=0
```

`DB_LATENCY` is supported only at 1 or 2. Tune `CASCADE_DEPTH`,
`SDP_WRITE_INPUT_REG`, placement directives, and target period with the current
RTL and tool version.

The sole numerical reference table, including tool/date/commit provenance, is
[`syn/vivado/sweep_results.md`](../../syn/vivado/sweep_results.md).

## Reproduction

```bash
cd syn/vivado

# U250 default OOC synthesis
PART=xcu250-figd2104-2L-e ./run_synth.sh

# U250 post-route OOC check
PART=xcu250-figd2104-2L-e SIZE=512K PNR=1 ./u55c_synth.sh

# U55C post-route
PNR=1 ./u55c_synth.sh

# V80 post-route
PNR=1 ./v80_synth.sh
```

See:

- [../wiki/URAM_Mode.md](../wiki/URAM_Mode.md)
- [../../syn/vivado/README.md](../../syn/vivado/README.md)
- [../../syn/vivado/sweep_results.md](../../syn/vivado/sweep_results.md)

# ML-KEM Twiddle ROM Contract

## Purpose

`rtl/ntt/twiddle_rom_3329.sv` supplies the 128 roots used by the ML-KEM
number-theoretic transform schedule.

The table is generated, not handwritten. The authoritative source values are
the `zetas[128]` constants and bit-reversed tree in the official
CRYSTALS-Kyber reference implementation:

```text
https://github.com/pq-crystals/kyber/blob/main/ref/ntt.c
```

## Arithmetic representation

The official reference stores signed Montgomery-domain constants. Its
butterfly combines those constants with Montgomery multiplication.

The current RTL multiplier in this repository computes ordinary canonical
modular multiplication:

```text
a * b mod 3329
```

Therefore the ROM must not feed the official signed values directly into the
current butterfly. The generator converts every official value from
Montgomery representation into the canonical standard-domain value:

```text
zeta_standard = zeta_montgomery * R^-1 mod 3329
R = 2^16 mod 3329 = 2285
```

The generator independently verifies the equivalent root expression:

```text
zeta_standard[index] = 17^tree[index] mod 3329
```

Every emitted value is in the range `0..3328`.

## Address map

The ROM contains addresses `0..127`.

- Address `0` contains `1` and is retained to match the complete official
  table.
- Forward NTT scheduling consumes addresses `1, 2, ..., 127`.
- Inverse NTT scheduling consumes addresses `127, 126, ..., 1`.
- The address-order controller is intentionally deferred to M4.

## Interface

```systemverilog
input  logic        clk_i;
input  logic        rst_ni;
input  logic        valid_i;
input  logic [6:0]  addr_i;
output logic        valid_o;
output logic [15:0] zeta_o;
```

`rst_ni` is an active-low synchronous reset.

A request is accepted on a rising edge where `valid_i == 1`. The corresponding
`valid_o` is asserted one rising edge later. The ROM accepts one address per
cycle and preserves bubbles and order. There is no backpressure.

## Generated files

The generator owns these files:

```text
rtl/ntt/twiddle_rom_3329.sv
tb/vectors/twiddle_3329_standard.hex
```

Regenerate them with:

```bash
python3 software/reference/generate_twiddles_3329.py --write
```

Check that committed files are current with:

```bash
python3 software/reference/generate_twiddles_3329.py --check
```

The check fails if:

- the official constants disagree with the root/tree derivation;
- a value is not canonical;
- the generated RTL or vector file has been manually changed;
- either generated file is missing.

## Verification

`tb/unit/tb_twiddle_rom_3329.sv` checks:

- all 128 addresses;
- exact one-cycle valid latency;
- continuous one-address-per-cycle traffic;
- deterministic random traffic with bubbles;
- canonical output range;
- selected independent spot values.

The test is part of `scripts/sim/run_iverilog_unit_tests.sh` and GitHub
Actions.

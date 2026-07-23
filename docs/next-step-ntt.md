# Next step: pipelined NTT butterfly

The current butterfly is combinational and intended to establish arithmetic correctness. The next implementation step is a registered datapath with an explicit latency contract.

## Proposed interface

```systemverilog
module ntt_butterfly_pipe (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        valid_i,
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,
    input  logic [15:0] zeta_i,
    output logic        valid_o,
    output logic [15:0] a_o,
    output logic [15:0] b_o
);
```

## Development sequence

1. Register the input product.
2. Pipeline Barrett quotient estimation and correction.
3. Register modular add/sub outputs.
4. Verify valid-data alignment at every stage.
5. Compare outputs with the combinational butterfly.
6. Synthesize on the selected board and record latency, Fmax, LUT and DSP usage.

## Gate before implementation

The target FPGA family should be identified before committing to a DSP-specific multiplier architecture. The functional interface can be developed independently, while primitive instantiation and aggressive optimization remain board-specific.

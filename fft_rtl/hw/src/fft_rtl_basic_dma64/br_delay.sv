`timescale 1us/1ns
// =====================================================================
//  delay_line -- fixed-length delay line (feedback FIFO of an SDF stage)
//  ---------------------------------------------------------------------
//  dout is din delayed by DEPTH ACTIVE cycles (cycles where en = 1).
//  The line only advances when en is high, so it freezes together with
//  the rest of the pipeline whenever no data is presented.
// =====================================================================
module delay_line #(
    parameter int DEPTH = 8,     // delay in active cycles
    parameter int WIDTH = 32     // data width in bits
)(
    input  logic             clk,
    input  logic             rst_n, // unused for DEPTH>=2 (kept for a uniform port map)
    input  logic             en,    // clock-enable: the line advances only when high
    input  logic [WIDTH-1:0] din,
    output logic [WIDTH-1:0] dout
);
    generate
        if (DEPTH <= 0) begin : gen_bypass
            // Zero delay: straight wire.
            assign dout = din;

        end else if (DEPTH == 1) begin : gen_reg
            // Single-cycle delay: one register.
            logic [WIDTH-1:0] r;
            always_ff @(posedge clk) if (en) r <= din;
            assign dout = r;

        end else begin : gen_srl
            // One DEPTH-bit shift chain per data bit -> inferred as SRLs.
            (* shreg_extract = "yes" *)
            logic [DEPTH-1:0] chain [WIDTH];

            always_ff @(posedge clk) begin
                if (en) begin
                    for (int b = 0; b < WIDTH; b++)
                        chain[b] <= {chain[b][DEPTH-2:0], din[b]};
                end
            end

            // Fixed output tap: last stage of each chain.
            always_comb
                for (int b = 0; b < WIDTH; b++)
                    dout[b] = chain[b][DEPTH-1];
        end
    endgenerate
endmodule

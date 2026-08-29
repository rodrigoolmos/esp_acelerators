`timescale 1us/1ns

module last_stage #(
    parameter logic FLOAT_POINT = 1,
    parameter int DATA_NB_BITS = 64
)(
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            en,         // clock-enable
    input  logic [DATA_NB_BITS/2-1:0]       A_re, A_im,
    input  logic [DATA_NB_BITS/2-1:0]       B_re, B_im,
    output logic [DATA_NB_BITS/2-1:0]       X_re, X_im,   // A + B
    output logic [DATA_NB_BITS/2-1:0]       Y_re, Y_im    // A - B
);
    generate
        if (FLOAT_POINT) begin : float_simple
            // Dual add/sub: X=A+B and Y=A-B per component, shared front-end.
            fp_addsub_dual32 u_bf_real (.clk(clk), .rst_n(rst_n), .en(en),
                                        .a_i(A_re), .b_i(B_re), .sum_o(X_re), .diff_o(Y_re));
            fp_addsub_dual32 u_bf_imag (.clk(clk), .rst_n(rst_n), .en(en),
                                        .a_i(A_im), .b_i(B_im), .sum_o(X_im), .diff_o(Y_im));
        end else begin : fixed_simple
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    X_re <= 0; X_im <= 0;
                    Y_re <= 0; Y_im <= 0;
                end else if (en) begin
                    X_re <= A_re + B_re;
                    X_im <= A_im + B_im;
                    Y_re <= A_re - B_re;
                    Y_im <= A_im - B_im;
                end
            end
        end
    endgenerate
endmodule
`timescale 1us/1ns

// =====================================================================
//  complex_rotator -- complex multiply by a twiddle factor:  X = B * W
//  ---------------------------------------------------------------------
//  X_re = B_re*W_re - B_im*W_im
//  X_im = B_re*W_im + B_im*W_re
//
//  Latency: 2 cycles in both data formats (kept identical so the top-level
//  counter pipeline stays aligned regardless of FLOAT_POINT):
//    - FLOAT_POINT=1 : 4 fp multipliers (cycle 1) then 2 fp add/sub
//                      (cycle 2).
//    - FLOAT_POINT=0 : Q16.16 multiplies + rescale, registered through a
//                      2-stage pipeline.
//  The 'en' clock-enable gates every internal register so the rotator
//  freezes together with the rest of the pipeline.
// =====================================================================
module complex_rotator #(
    parameter logic FLOAT_POINT = 1,
    parameter int   DATA_NB_BITS = 64
)(
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               en,
    input  logic [DATA_NB_BITS/2 - 1:0]        B_re, B_im, // Input B of Butterfly
    input  logic [DATA_NB_BITS/2 - 1:0]        W_re, W_im, // Twiddle factor
    output logic [DATA_NB_BITS/2 - 1:0]        X_re, X_im  // Output X = B*W
);
    generate
        if (FLOAT_POINT) begin : g_float

            logic [DATA_NB_BITS/2 - 1:0] ac_s1, bd_s1, ad_s1, bc_s1;

            // Multiplications (cycle 1)
            fp_mul32_lite u_mul_ac (.clk(clk), .rst_n(rst_n), .en(en), .a_i(B_re), .b_i(W_re), .res_o(ac_s1)); // B_re*W_re
            fp_mul32_lite u_mul_bd (.clk(clk), .rst_n(rst_n), .en(en), .a_i(B_im), .b_i(W_im), .res_o(bd_s1)); // B_im*W_im
            fp_mul32_lite u_mul_ad (.clk(clk), .rst_n(rst_n), .en(en), .a_i(B_re), .b_i(W_im), .res_o(ad_s1)); // B_re*W_im
            fp_mul32_lite u_mul_bc (.clk(clk), .rst_n(rst_n), .en(en), .a_i(B_im), .b_i(W_re), .res_o(bc_s1)); // B_im*W_re

            // Add / subtract (cycle 2)
            // X_re = ac - bd
            fp_addsub32_lite z_sub_real (.clk(clk), .rst_n(rst_n), .en(en), .a_i(ac_s1), .b_i(bd_s1), .sub_i(1'b1), .res_o(X_re));
            // X_im = ad + bc
            fp_addsub32_lite z_add_imag (.clk(clk), .rst_n(rst_n), .en(en), .a_i(ad_s1), .b_i(bc_s1), .sub_i(1'b0), .res_o(X_im));

        end else begin : g_fixed

            logic signed [DATA_NB_BITS - 1:0]     mult_re_1, mult_re_2;
            logic signed [DATA_NB_BITS - 1:0]     mult_im_1, mult_im_2;
            logic signed [DATA_NB_BITS/2 - 1:0]   B_scaled_re, B_scaled_im; // combinational
            logic signed [DATA_NB_BITS/2 - 1:0]   s1_re, s1_im;             // pipeline stage 1

            assign mult_re_1 = $signed(B_re) * $signed(W_re);
            assign mult_re_2 = $signed(B_im) * $signed(W_im);
            assign mult_im_1 = $signed(B_re) * $signed(W_im);
            assign mult_im_2 = $signed(B_im) * $signed(W_re);

            // Q16.16: rescale after the multiplication (>>> 16)
            assign B_scaled_re = (DATA_NB_BITS/2)'($signed(mult_re_1 - mult_re_2) >>> 16);
            assign B_scaled_im = (DATA_NB_BITS/2)'($signed(mult_im_1 + mult_im_2) >>> 16);

            // ---- 2-cycle pipeline (rotator latency = 2, matching the float path) ----
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    s1_re <= '0; s1_im <= '0;   // cycle 1
                    X_re  <= '0; X_im  <= '0;   // cycle 2
                end else if (en) begin
                    s1_re <= B_scaled_re;       // cycle 1
                    s1_im <= B_scaled_im;
                    X_re  <= s1_re;             // cycle 2
                    X_im  <= s1_im;
                end
            end
        end
    endgenerate
endmodule

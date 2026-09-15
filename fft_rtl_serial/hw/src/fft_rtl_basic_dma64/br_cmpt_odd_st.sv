`timescale 1us/1ns

module compute_odd_stage #(
    parameter logic FLOAT_POINT = 1,
    parameter int DATA_NB_BITS = 64
)(
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            en,         // clock-enable (avance pipeline)
    input  logic                            apply_j,    // Equals to 1 when the trivial rotation is -j
    input  logic [DATA_NB_BITS/2-1:0]       A_re, A_im,
    input  logic [DATA_NB_BITS/2-1:0]       B_re, B_im,
    output logic [DATA_NB_BITS/2-1:0]       X_re, X_im, // Output X of Butterfly X = A + B
    output logic [DATA_NB_BITS/2-1:0]       Y_re, Y_im  // Output Y of stage/trivial rotator
);
    logic [DATA_NB_BITS/2-1:0] inter_Y_re, inter_Y_im;
    
    // Register to align apply_j with the 1-cycle latency of the butterfly
    logic apply_j_d1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            apply_j_d1 <= 1'b0;
        end else if (en) begin
            apply_j_d1 <= apply_j;
        end
    end

    generate
        if (FLOAT_POINT) begin : float_bf1
            // Dual add/sub: X=A+B (direct output) and inter_Y=A-B (before -j),
            // shared alignment front-end.
            fp_addsub_dual32 u_bf_real (.clk(clk), .rst_n(rst_n), .en(en),
                                        .a_i(A_re), .b_i(B_re), .sum_o(X_re), .diff_o(inter_Y_re));
            fp_addsub_dual32 u_bf_imag (.clk(clk), .rst_n(rst_n), .en(en),
                                        .a_i(A_im), .b_i(B_im), .sum_o(X_im), .diff_o(inter_Y_im));
        end else begin : fixed_bf1
            logic [DATA_NB_BITS/2-1:0] reg_X_re, reg_X_im;
            logic [DATA_NB_BITS/2-1:0] reg_Y_re, reg_Y_im;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    reg_X_re <= 0;
                    reg_X_im <= 0;
                    reg_Y_re <= 0; reg_Y_im <= 0;
                end else if (en) begin
                    reg_X_re <= A_re + B_re;
                    reg_X_im <= A_im + B_im;
                    reg_Y_re <= A_re - B_re;
                    reg_Y_im <= A_im - B_im;
                end
            end
            assign X_re = reg_X_re;
            assign X_im = reg_X_im;
            assign inter_Y_re = reg_Y_re;
            assign inter_Y_im = reg_Y_im;
        end
    endgenerate

    always_comb begin
        if (apply_j_d1) begin
            // (a + jb)*(-j) = b - ja
            Y_re = inter_Y_im;
            if (FLOAT_POINT) begin
                Y_im = {~inter_Y_re[DATA_NB_BITS/2-1], inter_Y_re[DATA_NB_BITS/2-2:0]};
            end else begin
                Y_im = -inter_Y_re;
            end
        end else begin
            Y_re = inter_Y_re;
            Y_im = inter_Y_im;
        end
    end
endmodule
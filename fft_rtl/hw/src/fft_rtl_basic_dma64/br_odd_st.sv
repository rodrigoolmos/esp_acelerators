`timescale 1us/1ns
// Odd SDF stage: radix-2 butterfly (BF2) followed by the trivial -j rotation
// (selected by apply_j). out_valid is generated at the top level, not here.
module odd_sdf_stage #(
    parameter logic FLOAT_POINT = 1,
    parameter int   DATA_NB_BITS = 64,
    parameter int   DELAY_DEPTH  = 8
)(
    input  logic                        clk, rst_n, en,
    input  logic                        control, apply_j,
    input  logic [DATA_NB_BITS/2-1:0]   stage_in_re,  stage_in_im,
    output logic [DATA_NB_BITS/2-1:0]   stage_out_re, stage_out_im
);
    logic [DATA_NB_BITS/2-1:0] feedback_in_re, feedback_in_im, feedback_out_re, feedback_out_im;

    // Feedback FIFO (depth DELAY_DEPTH-1: compensates the 1-cycle butterfly latency)
    delay_line #(.DEPTH(DELAY_DEPTH-1), .WIDTH(DATA_NB_BITS/2)) u_delay_re (.clk,.rst_n,.en(en),.din(feedback_in_re),.dout(feedback_out_re));
    delay_line #(.DEPTH(DELAY_DEPTH-1), .WIDTH(DATA_NB_BITS/2)) u_delay_im (.clk,.rst_n,.en(en),.din(feedback_in_im),.dout(feedback_out_im));

    logic [DATA_NB_BITS/2-1:0] bf_X_re, bf_X_im, bf_Y_re, bf_Y_im;
    compute_odd_stage #(.FLOAT_POINT(FLOAT_POINT), .DATA_NB_BITS(DATA_NB_BITS)) u_bf (
        .clk,.rst_n,.en(en),.apply_j(apply_j),
        .A_re(feedback_out_re), .A_im(feedback_out_im),
        .B_re(stage_in_re),     .B_im(stage_in_im),
        .X_re(bf_X_re), .X_im(bf_X_im), .Y_re(bf_Y_re), .Y_im(bf_Y_im));

    // Alignment registers for the bypass path (1-cycle latency)
    logic [DATA_NB_BITS/2-1:0] stage_in_re_d1, stage_in_im_d1, feedback_out_re_d1, feedback_out_im_d1;
    logic control_d1;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            stage_in_re_d1<='0; stage_in_im_d1<='0; feedback_out_re_d1<='0; feedback_out_im_d1<='0; control_d1<=1'b0;
        end else if (en) begin
            stage_in_re_d1<=stage_in_re; stage_in_im_d1<=stage_in_im;
            feedback_out_re_d1<=feedback_out_re; feedback_out_im_d1<=feedback_out_im; control_d1<=control;
        end

    always_comb
        if (control_d1) begin
            stage_out_re=bf_X_re; stage_out_im=bf_X_im;
            feedback_in_re=bf_Y_re; feedback_in_im=bf_Y_im;
        end else begin
            stage_out_re=feedback_out_re_d1; stage_out_im=feedback_out_im_d1;
            feedback_in_re=stage_in_re_d1;   feedback_in_im=stage_in_im_d1;
        end
endmodule

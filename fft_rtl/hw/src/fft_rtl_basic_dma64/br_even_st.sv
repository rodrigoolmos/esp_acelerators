`timescale 1us/1ns
// Even SDF stage: radix-2 butterfly (BF2) followed by a full complex rotator
// (twiddle multiplication). Forward latency = 1 (BF2) + 2 (rotator) = 3 cycles.
// The twiddle W comes from the ROM, addressed at the top level by (cnt + DELAY_DEPTH).
module even_sdf_stage #(
    parameter logic FLOAT_POINT = 1,
    parameter int   DATA_NB_BITS = 64,
    parameter int   DELAY_DEPTH  = 4
)(
    input  logic                        clk, rst_n, en, control,
    input  logic [DATA_NB_BITS/2-1:0]   W_re, W_im,
    input  logic [DATA_NB_BITS/2-1:0]   stage_in_re,  stage_in_im,
    output logic [DATA_NB_BITS/2-1:0]   stage_out_re, stage_out_im
);
    localparam int WD = DATA_NB_BITS/2;
    localparam int FB_DELAY = DELAY_DEPTH - 1;   // compensates the 1-cycle BF2 latency

    logic [WD-1:0] feedback_in_re, feedback_in_im, feedback_out_re, feedback_out_im;
    delay_line #(.DEPTH(FB_DELAY), .WIDTH(WD)) u_delay_re (.clk,.rst_n,.en(en),.din(feedback_in_re),.dout(feedback_out_re));
    delay_line #(.DEPTH(FB_DELAY), .WIDTH(WD)) u_delay_im (.clk,.rst_n,.en(en),.din(feedback_in_im),.dout(feedback_out_im));

    logic [WD-1:0] bf_X_re, bf_X_im, bf_Y_re, bf_Y_im;
    R2_add_sub #(.FLOAT_POINT(FLOAT_POINT), .DATA_NB_BITS(DATA_NB_BITS)) u_bf (
        .clk,.rst_n,.en(en),
        .A_re(feedback_out_re), .A_im(feedback_out_im),
        .B_re(stage_in_re),     .B_im(stage_in_im),
        .X_re(bf_X_re), .X_im(bf_X_im), .Y_re(bf_Y_re), .Y_im(bf_Y_im));

    // Alignment registers (bypass path + control), 1-cycle latency
    logic [WD-1:0] stage_in_re_d1, stage_in_im_d1, feedback_out_re_d1, feedback_out_im_d1, W_re_d1, W_im_d1;
    logic control_d1;
    always_ff @(posedge clk or negedge rst_n)
        if(!rst_n) begin
            stage_in_re_d1<='0; stage_in_im_d1<='0; feedback_out_re_d1<='0; feedback_out_im_d1<='0;
            W_re_d1<='0; W_im_d1<='0; control_d1<=1'b0;
        end else if(en) begin
            stage_in_re_d1<=stage_in_re; stage_in_im_d1<=stage_in_im;
            feedback_out_re_d1<=feedback_out_re; feedback_out_im_d1<=feedback_out_im;
            W_re_d1<=W_re; W_im_d1<=W_im; control_d1<=control;
        end

    // MUX: rotator input (sum on the butterfly cycle, difference replayed from FIFO)
    logic [WD-1:0] in_CR_re, in_CR_im;
    always_comb
        if (control_d1) begin
            in_CR_re=bf_X_re; in_CR_im=bf_X_im;
            feedback_in_re=bf_Y_re; feedback_in_im=bf_Y_im;
        end else begin
            in_CR_re=feedback_out_re_d1; in_CR_im=feedback_out_im_d1;
            feedback_in_re=stage_in_re_d1; feedback_in_im=stage_in_im_d1;
        end

    // Full complex rotator: X = in_CR * W (2-cycle latency)
    complex_rotator #(.FLOAT_POINT(FLOAT_POINT), .DATA_NB_BITS(DATA_NB_BITS)) u_CR (
        .clk,.rst_n,.en(en),
        .B_re(in_CR_re), .B_im(in_CR_im), .W_re(W_re_d1), .W_im(W_im_d1),
        .X_re(stage_out_re), .X_im(stage_out_im));
endmodule

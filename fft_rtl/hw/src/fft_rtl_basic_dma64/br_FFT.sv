`timescale 1us/1ns
// =====================================================================
//  FFT core -- radix-2^2 Single-delay Feedback (SDF), decimation in
//  frequency (DIF). Streaming, fully pipelined, one sample per active
//  cycle in steady state.
//  ---------------------------------------------------------------------
//  * Clock-enable ce = in_valid. The whole pipeline (data, counters and
//    feedback FIFOs) advances ONLY when a sample is presented. With no
//    input, everything freezes: no zero enters the pipeline and no
//    desynchronization can occur, so frames may be separated by arbitrary
//    gaps yet stay perfectly back-to-back across the active cycles.
//  * Real tokens vs drain tokens. A token is "real" if it belongs to a
//    FFT_SIZE-sample window opened by frame_start. Tokens presented
//    outside a window (in_valid=1 without frame_start after a complete
//    frame) are DRAIN tokens: they advance the pipeline (data = 0
//    recommended) but never assert out_valid.
//  * End-of-stream drain: after the last frame, present at least
//    OUT_LATENCY drain tokens to flush out the final results (the
//    ping-pong wrapper does this automatically).
//  * Input-to-output latency = (FFT_SIZE-1) + TOTAL_LATENCY active cycles.
//    Output samples come out in bit-reversed order (a DIF property); the
//    ping-pong wrapper restores natural order.
// =====================================================================
module FFT #(
    parameter logic FLOAT_POINT = 1,
    parameter int   FFT_SIZE    = 16,
    parameter int   DATA_NB_BITS = 64
)(
    input  logic                        clk, rst_n,
    input  logic                        in_valid,
    input  logic                        frame_start,
    input  logic [DATA_NB_BITS-1:0]     in_data,
    output logic                        out_valid,
    output logic                        out_frame_start,
    output logic [DATA_NB_BITS-1:0]     out_data,
    output logic                        out_last
);
    localparam int NB_STAGES = $clog2(FFT_SIZE);

    // ---- Forward (compute) latency per stage: odd/last=1, even=3 ----
    function automatic int calc_latency(int n);
        int lat = 0;
        for (int i = 0; i < n; i++)
            lat += (i != n-1 && i % 2 == 1) ? 3 : 1;
        return lat;
    endfunction
    localparam int TOTAL_LATENCY = calc_latency(NB_STAGES);
    // Total input-to-output latency (in active cycles)
    localparam int OUT_LATENCY   = (FFT_SIZE - 1) + TOTAL_LATENCY;

    // Clock-enable: the pipeline advances only when a sample is present
    wire ce = in_valid;

    // ---- Frame sample counter (advances only on an active cycle) ----
    logic [$clog2(FFT_SIZE)-1:0] frame_cnt, cur_cnt;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)           frame_cnt <= '0;
        else if (ce)          frame_cnt <= frame_start ? 'd1 : frame_cnt + 1'b1; // wraps mod FFT_SIZE
    assign cur_cnt = frame_start ? '0 : frame_cnt;

    // ---- Frame window: tells real tokens apart from drain tokens ----
    logic in_frame_act;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) in_frame_act <= 1'b0;
        else if (ce) begin
            if (frame_start)                 in_frame_act <= 1'b1;
            else if (cur_cnt == FFT_SIZE-1)  in_frame_act <= 1'b0;
        end
    wire real_token = in_valid && (frame_start || in_frame_act);

    // ---- SDF datapath (data only) ----
    wire [NB_STAGES:0][DATA_NB_BITS/2-1:0] w_re, w_im;
    assign w_re[0] = in_valid ? in_data[DATA_NB_BITS-1:DATA_NB_BITS/2] : '0;
    assign w_im[0] = in_valid ? in_data[DATA_NB_BITS/2-1:0]            : '0;

    generate
        logic [NB_STAGES:0][$clog2(FFT_SIZE)-1:0] cnt_pipe;
        assign cnt_pipe[0] = cur_cnt;

        for (genvar s = 0; s < NB_STAGES; s++) begin : gen_sdf_pipeline
            localparam int D        = FFT_SIZE / (2 << s);   // feedback FIFO depth of this stage
            localparam int BIT_CTRL = NB_STAGES - 1 - s;
            wire ctrl_sig = cnt_pipe[s][BIT_CTRL];

            if (s == NB_STAGES-1) begin : last_stage_inst
                last_sdf_stage #(.FLOAT_POINT(FLOAT_POINT), .DATA_NB_BITS(DATA_NB_BITS), .DELAY_DEPTH(D)) u_last (
                    .clk,.rst_n,.en(ce), .control(ctrl_sig),
                    .stage_in_re(w_re[s]),    .stage_in_im(w_im[s]),
                    .stage_out_re(w_re[s+1]), .stage_out_im(w_im[s+1]));
                always_ff @(posedge clk or negedge rst_n)
                    if(!rst_n) cnt_pipe[s+1] <= 0; else if(ce) cnt_pipe[s+1] <= cnt_pipe[s];

            end else if (s % 2 == 0) begin : odd_stage_inst
                wire apply_j = cnt_pipe[s][BIT_CTRL] && cnt_pipe[s][BIT_CTRL-1];
                odd_sdf_stage #(.FLOAT_POINT(FLOAT_POINT), .DATA_NB_BITS(DATA_NB_BITS), .DELAY_DEPTH(D)) u_odd (
                    .clk,.rst_n,.en(ce), .control(ctrl_sig), .apply_j(apply_j),
                    .stage_in_re(w_re[s]),    .stage_in_im(w_im[s]),
                    .stage_out_re(w_re[s+1]), .stage_out_im(w_im[s+1]));
                always_ff @(posedge clk or negedge rst_n)
                    if(!rst_n) cnt_pipe[s+1] <= 0; else if(ce) cnt_pipe[s+1] <= cnt_pipe[s];

            end else begin : even_stage_inst
                wire [DATA_NB_BITS/2-1:0] W_re, W_im;
                // Twiddle synchronization: the ROM is addressed at (cnt + DELAY_DEPTH)
                // so each output (sum / difference) reads the correct twiddle when it leaves the stage.
                localparam int AW = $clog2(FFT_SIZE);
                wire [AW-1:0] rom_addr = cnt_pipe[s] + AW'(D);
                twiddle_rom_sdf #(.STAGE(s), .FFT_SIZE(FFT_SIZE), .FLOAT_POINT(FLOAT_POINT), .WIDTH(DATA_NB_BITS/2)) u_rom (
                    .addr(rom_addr), .W_re(W_re), .W_im(W_im));

                even_sdf_stage #(.FLOAT_POINT(FLOAT_POINT), .DATA_NB_BITS(DATA_NB_BITS), .DELAY_DEPTH(D)) u_even (
                    .clk,.rst_n,.en(ce), .control(ctrl_sig), .W_re(W_re), .W_im(W_im),
                    .stage_in_re(w_re[s]),    .stage_in_im(w_im[s]),
                    .stage_out_re(w_re[s+1]), .stage_out_im(w_im[s+1]));

                // cnt_pipe delayed by 3 (even-stage latency)
                logic [$clog2(FFT_SIZE)-1:0] cnt_r1, cnt_r2, cnt_r3;
                always_ff @(posedge clk or negedge rst_n)
                    if(!rst_n) {cnt_r1,cnt_r2,cnt_r3} <= '0;
                    else if(ce) begin cnt_r1<=cnt_pipe[s]; cnt_r2<=cnt_r1; cnt_r3<=cnt_r2; end
                assign cnt_pipe[s+1] = cnt_r3;
            end
        end
    endgenerate

    // ---- Outputs ----
    assign out_data = {w_re[NB_STAGES], w_im[NB_STAGES]};

    // out_valid = real token delayed by OUT_LATENCY active cycles.
    // The shift register advances only on ce; the output bit is cleared on
    // frozen cycles so each result is presented for exactly ONE cycle
    // (no duplicate while the pipeline is stalled).
    logic [OUT_LATENCY-1:0] valid_sr;
    always_ff @(posedge clk or negedge rst_n)
        if(!rst_n)  valid_sr <= '0;
        else if(ce) valid_sr <= {valid_sr[OUT_LATENCY-2:0], real_token};
        else        valid_sr[OUT_LATENCY-1] <= 1'b0;   // frozen cycle: result already shown
    assign out_valid = valid_sr[OUT_LATENCY-1];

    // Output frame markers
    logic [$clog2(FFT_SIZE)-1:0] out_cnt;
    always_ff @(posedge clk or negedge rst_n)
        if(!rst_n)          out_cnt <= '0;
        else if(out_valid)  out_cnt <= out_cnt + 1'b1;   // wraps mod FFT_SIZE
    assign out_frame_start = out_valid && (out_cnt == '0);
    assign out_last        = out_valid && (out_cnt == FFT_SIZE-1);
endmodule

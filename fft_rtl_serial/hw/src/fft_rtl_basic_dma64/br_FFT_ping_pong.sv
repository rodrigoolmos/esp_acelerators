`timescale 1us/1ns

// =====================================================================
//  FFT_ping_pong -- streaming wrapper around the SDF FFT core.
//  ---------------------------------------------------------------------
//   * Aggregate incoming samples into frames of FFT_SIZE, using two input
//     buffers (ping/pong) so one frame can be filled while the previous
//     one is being processed.
//   * Inject frames into the core through a small FSM, back-to-back with
//     no idle cycles whenever data is available.
//   * Write the core results (produced in bit-reversed order) into two
//     output buffers at bit-reversed addresses, so they can be read back
//     in natural order.
//   * Detect end of stream deterministically from conf_info_burst_len
//     (number of frames), then drain the core pipeline (FLUSH_LEN tokens)
//     to flush out the final results.
//   * Apply output back-pressure (out_stall) so results are never
//     overwritten before the write-DMA has drained them.
// =====================================================================
module FFT_ping_pong #(
    parameter logic FLOAT_POINT = 1,
    parameter int FFT_SIZE     = 16,
    parameter int DATA_NB_BITS = 64
)(
    input  logic                                clk,
    input  logic                                rst_n,
    input  logic [31:0]                         conf_info_burst_len, // number of frames in the current burst

    input  logic                                in_valid,
    input  logic [DATA_NB_BITS-1:0]             in_data,
    output logic                                in_ready,

    output logic                                out_valid,
    output logic [DATA_NB_BITS-1:0]             out_data,
    input  logic                                out_ready
);

    // Ping/pong buffers.
    (* ram_style = "distributed" *) logic [DATA_NB_BITS-1:0] in_ping  [FFT_SIZE];
    (* ram_style = "distributed" *) logic [DATA_NB_BITS-1:0] in_pong  [FFT_SIZE];
    (* ram_style = "distributed" *) logic [DATA_NB_BITS-1:0] out_ping [FFT_SIZE];
    (* ram_style = "distributed" *) logic [DATA_NB_BITS-1:0] out_pong [FFT_SIZE];

    // -----------
    //  Pointers 
    // -----------
    logic [$clog2(FFT_SIZE)-1:0] in_ptr;      // where the DMA writes the next incoming sample
    logic [$clog2(FFT_SIZE)-1:0] send_cnt;    // which sample the send FSM is injecting into the core
    logic [$clog2(FFT_SIZE)-1:0] out_wr_ptr;  // where the core result is stored (bit-reversed on write)
    logic [$clog2(FFT_SIZE)-1:0] out_ptr;     // which result the write-DMA is reading back

    // -----------------------------------------------------------------
    //  Buffer selectors -- each says "ping (0) or pong (1)" .
    // -----------------------------------------------------------------
    logic in_sel;        // buffer currently being FILLED by the DMA
    logic proc_sel;      // buffer currently being INJECTED into the core
    logic fft_out_sel;   // buffer currently being WRITTEN with core results
    logic out_read_sel;  // buffer currently being READ BACK by the write-DMA

    // -------------
    //  Full flags 
    // -------------
    logic in_ping_full,  in_pong_full;   // input frame ready to be sent to the core
    logic out_ping_full, out_pong_full;  // output frame ready to be read by the write-DMA

    // Interface to the FFT core
    logic                    fft_in_valid, fft_frame_start;
    logic [DATA_NB_BITS-1:0] fft_in_data;
    logic                    fft_out_valid, fft_out_frame_start, fft_out_last;
    logic [DATA_NB_BITS-1:0] fft_out_data;

    // -------------------------
    //  Exact pipeline latency
    // -------------------------
    function automatic int calc_latency(int n);
        int lat = 0;
        for (int i = 0; i < n; i++)
            lat += (i != n-1 && i % 2 == 1) ? 3 : 1;
        return lat;
    endfunction
    
    localparam int NB_STAGES     = $clog2(FFT_SIZE);
    localparam int TOTAL_LATENCY = calc_latency(NB_STAGES);
    localparam int FLUSH_LEN     = (FFT_SIZE - 1) + TOTAL_LATENCY; // exact core latency

    logic [$clog2(FLUSH_LEN+1)-1:0] flush_cnt;
    logic [31:0] burst_frame_cnt; // number of frames already injected into the core

    function automatic int rev_bits(int idx);
        int rev = 0;
        int temp = idx;
        for (int i = 0; i < $clog2(FFT_SIZE); i++) begin
            rev  = (rev << 1) | (temp & 1);
            temp = temp >> 1;
        end
        return rev;
    endfunction

    // =====================================================================
    //  Output back-pressure (out_stall)
    //  The core writes its results into an output buffer OUT_LATENCY cycles
    //  after the corresponding frame was injected. To make sure it never
    //  overwrites an output buffer that the write-DMA has not drained yet,
    //  the core is frozen just before it would start writing
    //  into a full buffer, and resumes as soon as that buffer is 
    //  freed.
    // =====================================================================

    // fft_out_sel selects the buffer the core is CURRENTLY writing into.
    // Its complement is therefore the buffer of the NEXT frame:
    //   fft_out_sel == 0 -> core writes ping, next frame goes to pong
    //   fft_out_sel == 1 -> core writes pong, next frame goes to ping
    logic nxt_out_full;
    assign nxt_out_full = fft_out_sel ? out_ping_full : out_pong_full; // buffer of the NEXT output frame
    logic cur_out_full;
    assign cur_out_full = fft_out_sel ? out_pong_full : out_ping_full; // buffer of the CURRENT output frame

    // out_stall raises back-pressure BEFORE any data can be lost. Two
    // distinct situations, and both are needed:
    //  (a) out_wr_ptr == FFT_SIZE-1 && fft_out_valid && nxt_out_full
    //      The core is writing the LAST word of the current frame. On the
    //      next cycle it will switch to the other buffer -- but that one is
    //      still full (not yet drained by the write-DMA). We must freeze now,
    //      one cycle ahead, because by the time the switch happens it would
    //      already be too late: the first word of the next frame would
    //      overwrite data.
    //  (b) out_wr_ptr == '0 && cur_out_full
    //      We are at a frame boundary (pointer just wrapped) and the buffer
    //      we are about to write into is still full. This covers the case
    //      where the core resumes after a pause: condition (a) fired on a
    //      cycle that has already gone, so a steady-state term is required
    //      to KEEP the stall asserted until the buffer is actually freed.
    //
    // Together: (a) catches the transition, (b) holds the stall. Without
    // (a) the freeze would arrive one cycle late; without (b) it would last
    // a single cycle and release too early.
    logic out_stall;
    assign out_stall = (out_wr_ptr == FFT_SIZE-1 && fft_out_valid && nxt_out_full)
                    || (out_wr_ptr == '0 && cur_out_full);

    // Effective valid into the core: tokens (data, frame_start, drain) are
    // held while stalled and resume unchanged afterwards.
    logic fft_in_valid_eff;
    assign fft_in_valid_eff = fft_in_valid && !out_stall;

    FFT #(
        .FLOAT_POINT(FLOAT_POINT), .FFT_SIZE(FFT_SIZE), .DATA_NB_BITS(DATA_NB_BITS)
    ) FFT_inst (
        .clk(clk), .rst_n(rst_n),
        .in_valid(fft_in_valid_eff),
        .frame_start(fft_frame_start),
        .in_data(fft_in_data),
        .out_valid(fft_out_valid),
        .out_frame_start(fft_out_frame_start),
        .out_data(fft_out_data),
        .out_last(fft_out_last)
    );

    // 1) INPUT SAMPLE WRITE (from the DMA, continuous)
    logic send_done_ping, send_done_pong;

    always_comb begin
        in_ready = (in_sel == 1'b0) ? !in_ping_full : !in_pong_full;
    end

    logic fill_last_ping;
    assign fill_last_ping = in_valid && in_ready && (in_sel == 1'b0) && (in_ptr == FFT_SIZE-1);
    logic fill_last_pong;
    assign fill_last_pong = in_valid && in_ready && (in_sel == 1'b1) && (in_ptr == FFT_SIZE-1);
    logic ready_ping;
    assign ready_ping = (in_ping_full || fill_last_ping) && !out_ping_full;
    logic ready_pong;
    assign ready_pong = (in_pong_full || fill_last_pong) && !out_pong_full;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_ptr       <= '0;
            in_sel       <= 1'b0;
            in_ping_full <= 1'b0;
            in_pong_full <= 1'b0;
        end else begin
            if (send_done_ping)      in_ping_full <= 1'b0;
            else if (fill_last_ping) in_ping_full <= 1'b1;

            if (send_done_pong)      in_pong_full <= 1'b0;
            else if (fill_last_pong) in_pong_full <= 1'b1;

            if (in_valid && in_ready) begin
                if (in_ptr == FFT_SIZE-1) begin
                    in_ptr <= '0;
                    in_sel <= ~in_sel;
                end else begin
                    in_ptr <= in_ptr + 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (in_valid && in_ready) begin
            if (in_sel == 1'b0) in_ping[in_ptr] <= in_data;
            else                in_pong[in_ptr] <= in_data;
        end
    end

    // 2) SEND FSM (injects frames into the core)
    typedef enum logic [1:0] { S_IDLE, S_SEND, S_FLUSH } send_state_e;
    send_state_e send_st;

    logic [3:0] frames_started, frames_done;
    logic pending;
    assign pending = (frames_started != frames_done);

    // Next input buffer to send (strict ping/pong alternation). This keeps
    // frames injected into the core in the exact order they were received
    logic next_send_sel;

    assign fft_in_data = (send_st == S_SEND)
                       ? (proc_sel ? in_pong[send_cnt] : in_ping[send_cnt])
                       : '0;


    always_comb begin
        send_done_ping = (send_st == S_SEND && send_cnt == FFT_SIZE-1 && proc_sel == 1'b0);
        send_done_pong = (send_st == S_SEND && send_cnt == FFT_SIZE-1 && proc_sel == 1'b1);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            send_st         <= S_IDLE;
            send_cnt        <= '0;
            proc_sel        <= 1'b0;
            fft_in_valid    <= 1'b0;
            fft_frame_start <= 1'b0;
            flush_cnt       <= '0;
            frames_started  <= '0;
            burst_frame_cnt <= '0;
            next_send_sel   <= 1'b0;
        end else if (out_stall) begin
            // STALL: freeze the ENTIRE send state
        end else begin
            fft_frame_start <= 1'b0;

            if (fft_frame_start) begin
                burst_frame_cnt <= burst_frame_cnt + 1'b1;
            end

            case (send_st)
                S_IDLE: begin
                    fft_in_valid <= 1'b0;
                    // If every frame has been sent but results are still in flight, start the drain
                    if (burst_frame_cnt == conf_info_burst_len && conf_info_burst_len > 0 && pending) begin
                        send_st      <= S_FLUSH;
                        flush_cnt    <= FLUSH_LEN[$bits(flush_cnt)-1:0];
                        fft_in_valid <= 1'b1;
                    end else if (next_send_sel == 1'b0 && ready_ping
                                 && (burst_frame_cnt < conf_info_burst_len)) begin
                        send_st         <= S_SEND;
                        proc_sel        <= 1'b0; send_cnt <= '0;
                        fft_in_valid    <= 1'b1; fft_frame_start <= 1'b1;
                        frames_started  <= frames_started + 1'b1;
                        next_send_sel   <= 1'b1;
                    end else if (next_send_sel == 1'b1 && ready_pong
                                 && (burst_frame_cnt < conf_info_burst_len)) begin
                        send_st         <= S_SEND;
                        proc_sel        <= 1'b1; send_cnt <= '0;
                        fft_in_valid    <= 1'b1; fft_frame_start <= 1'b1;
                        frames_started  <= frames_started + 1'b1;
                        next_send_sel   <= 1'b0;
                    end
                end

                S_SEND: begin
                    fft_in_valid <= 1'b1;
                    if (send_cnt == FFT_SIZE-1) begin
                        // Check whether we just finished the last frame of the burst
                        if (burst_frame_cnt == conf_info_burst_len) begin
                            send_st      <= S_FLUSH;
                            flush_cnt    <= FLUSH_LEN[$bits(flush_cnt)-1:0];
                            fft_in_valid <= 1'b1; // start injecting drain tokens (data = 0) immediately
                        end else if (proc_sel == 1'b0 && ready_pong) begin
                            proc_sel        <= 1'b1; send_cnt <= '0; fft_frame_start <= 1'b1;
                            frames_started  <= frames_started + 1'b1;
                            next_send_sel   <= 1'b0;   // after pong, next is ping
                        end else if (proc_sel == 1'b1 && ready_ping) begin
                            proc_sel        <= 1'b0; send_cnt <= '0; fft_frame_start <= 1'b1;
                            frames_started  <= frames_started + 1'b1;
                            next_send_sel   <= 1'b1;   // after ping, next is pong
                        end else begin
                            send_st      <= S_IDLE; 
                            fft_in_valid <= 1'b0;
                        end
                    end else begin
                        send_cnt <= send_cnt + 1'b1;
                    end
                end

                // S_FLUSH -- DRAIN THE PIPELINE.
                // The core only advances when it receives a token
                // (ce = in_valid). After the last real sample, OUT_LATENCY
                // results are still travelling inside the pipeline and would
                // stay stuck there forever, because no more data is coming.
                // So we keep pulsing fft_in_valid with dummy data (zeros)
                // exactly FLUSH_LEN times, which mechanically pushes the last
                // real results out. FLUSH_LEN equals the core latency, so not
                // one token more than necessary is injected.
                S_FLUSH: begin
                    fft_in_valid <= 1'b1;
                    if (flush_cnt != 0) begin
                        flush_cnt <= flush_cnt - 1'b1;
                    end else begin
                        send_st         <= S_IDLE;
                        fft_in_valid    <= 1'b0;
                        burst_frame_cnt <= '0; // ready for the next burst
                    end
                end
            endcase
        end
    end

    // 3) WRITE FFT RESULTS INTO THE OUTPUT BUFFERS (with bit-reversal)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_wr_ptr    <= '0;
            fft_out_sel   <= 1'b0;
            out_ping_full <= 1'b0;
            out_pong_full <= 1'b0;
            frames_done   <= '0;
        end else begin
            if (out_valid && out_ready && out_ptr == FFT_SIZE-1) begin
                if (out_read_sel == 1'b0) out_ping_full <= 1'b0;
                else                      out_pong_full <= 1'b0;
            end

            if (fft_out_valid) begin
                if (out_wr_ptr == FFT_SIZE-1) frames_done <= frames_done + 1'b1;
                if (out_wr_ptr == FFT_SIZE-1) begin
                    out_wr_ptr <= '0;
                    if (fft_out_sel == 1'b0) out_ping_full <= 1'b1;
                    else                     out_pong_full <= 1'b1;
                    fft_out_sel <= ~fft_out_sel;
                end else begin
                    out_wr_ptr <= out_wr_ptr + 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (fft_out_valid) begin
            if (fft_out_sel == 1'b0) out_ping[rev_bits(out_wr_ptr)] <= fft_out_data;
            else                     out_pong[rev_bits(out_wr_ptr)] <= fft_out_data;
        end
    end

    // 4) OUTPUT BUFFER READ (by the DMA), natural order
    //
    // out_valid is simply the full flag of the buffer being read
    always_comb begin
        if (out_read_sel == 1'b0) begin
            out_valid = out_ping_full;
            out_data  = out_ping_full ? out_ping[out_ptr] : '0;
        end else begin
            out_valid = out_pong_full;
            out_data  = out_pong_full ? out_pong[out_ptr] : '0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_ptr      <= '0;
            out_read_sel <= 1'b0;
        end else begin
            if (out_valid && out_ready) begin
                if (out_ptr == FFT_SIZE-1) begin
                    out_ptr      <= '0;
                    out_read_sel <= ~out_read_sel;
                end else begin
                    out_ptr <= out_ptr + 1'b1;
                end
            end
        end
    end

endmodule
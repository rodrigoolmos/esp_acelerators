`timescale 1us/1ns

// =====================================================================
//  fft_rtl_basic_dma64 -- top level bridging the ESP DMA interface to the
//  FFT_ping_pong accelerator.
//   * READ FSM  : issues one DMA read request for the whole burst
//                 (conf_info_burst_len * FFT_SIZE beats) and streams the
//                 samples into the accelerator.
//   * WRITE FSM : issues one DMA write request per output frame and
//                 streams the results back to memory.
//   * acc_done  : asserted once all frames have been written back.
//
//  Windowing (pre-processing): a window_stage is inserted between the DMA
//  read channel and the wrapper. Configured by conf_info_window:
//     bit 0 = enable (apply the window), bit 1 = load coefficients.
//
//  Two independent request types (selected at conf_done by conf_info_window):
//   * LOAD request  (load=1): a read transaction of FFT_SIZE beats brings
//     the window coefficients into the RAM. No FFT is computed and nothing
//     is written back. acc_done is asserted once the last coefficient is
//     stored (window_stage.load_done), then the top returns to idle.
//   * COMPUTE request (load=0): a read transaction of burst_len*FFT_SIZE
//     beats brings the samples, which are windowed (using the coefficients
//     already stored) and transformed. Results are written back per frame.
//  Because the window persists in the RAM, a single LOAD request can be
//  followed by many COMPUTE requests reusing the same window.
// =====================================================================
module fft_rtl_basic_dma64 #(
    parameter logic FLOAT_POINT = 1'b1,
    parameter int FFT_SIZE = 4096,
    parameter int DATA_NB_BITS = 64
) (
    input  logic        clk,
    input  logic        rst,

    input  logic [31:0] conf_info_burst_len,
    input  logic [31:0] conf_info_index,    // base memory index for the read transaction
    input  logic [31:0] conf_info_out_index,// base memory index for the write transaction
    input  logic [31:0] conf_info_window,   // bit0=enable, bit1=load, rest reserved
    input  logic [31:0] conf_info_ifft,     // bit0=1 -> inverse FFT, rest reserved
    input  logic        conf_done,
    output logic        acc_done,

    // DMA read control
    input  logic        dma_read_ctrl_ready,
    output logic        dma_read_ctrl_valid,
    output logic [31:0] dma_read_ctrl_data_index,
    output logic [31:0] dma_read_ctrl_data_length,
    output logic [2:0]  dma_read_ctrl_data_size,
    output logic [5:0]  dma_read_ctrl_data_user,

    // DMA read channel
    output logic        dma_read_chnl_ready,
    input  logic        dma_read_chnl_valid,
    input  logic [63:0] dma_read_chnl_data,

    // DMA write control
    input  logic        dma_write_ctrl_ready,
    output logic        dma_write_ctrl_valid,
    output logic [31:0] dma_write_ctrl_data_index,
    output logic [31:0] dma_write_ctrl_data_length,
    output logic [2:0]  dma_write_ctrl_data_size,
    output logic [5:0]  dma_write_ctrl_data_user,

    // DMA write channel
    input  logic        dma_write_chnl_ready,
    output logic        dma_write_chnl_valid,
    output logic [63:0] dma_write_chnl_data
);

    logic pp_out_valid;
    logic [31:0] FFTs_read, FFTs_written;

    // acc_done is asserted by either the compute path (WRITE FSM) or the
    // window-load path (READ FSM). Merge the two one-cycle pulses.
    logic acc_done_compute;

    // Windowing configuration, sampled once when a transaction starts.
    logic win_enable_r, win_load_r;
    logic ifft_mode_r;              // 1 = inverse FFT for the current request
    logic win_start_pulse;          // 1-cycle pulse when a read transaction begins
    logic window_loaded;            // sticky flag from the window stage (for visibility)
    logic win_load_done;            // 1-cycle pulse: last coefficient stored

    // ---- Windowing stage: DMA read channel -> window_stage -> wrapper ----
    logic                    win_down_valid, win_down_ready;
    logic [DATA_NB_BITS-1:0] win_down_data;

    window_stage #(
        .FLOAT_POINT(FLOAT_POINT),
        .FFT_SIZE(FFT_SIZE),
        .DATA_NB_BITS(DATA_NB_BITS)
    ) window_inst (
        .clk(clk),
        .rst_n(rst),
        .win_enable(win_enable_r),
        .win_load(win_load_r),
        .start_pulse(win_start_pulse),
        .window_loaded(window_loaded),
        .load_done(win_load_done),
        // upstream = DMA read channel
        .up_valid(dma_read_chnl_valid),
        .up_data(dma_read_chnl_data),
        .up_ready(dma_read_chnl_ready),
        // downstream = wrapper input
        .down_valid(win_down_valid),
        .down_data(win_down_data),
        .down_ready(win_down_ready)
    );

    // -----------------------------------------------------------------
    //  INVERSE FFT (iFFT) -- swap / FFT / swap / scale
    //
    //  The inverse transform is obtained WITHOUT touching the FFT core,
    //  using the identity:
    //      iFFT(X) = (1/N) * swap( FFT( swap(X) ) )
    //  where swap(a + jb) = b + ja (exchange of the real and imaginary
    //  halves). This works because swap(z) = j*conj(z): applying it on
    //  both sides makes the two j factors cancel, which reproduces the
    //  classic conjugate identity iFFT(X) = (1/N)*conj(FFT(conj(X))).
    //
    //  Advantage over conjugating the twiddles: the core, its twiddle ROM
    //  and the trivial -j rotations of the radix-2^2 odd stages all stay
    //  strictly unchanged -- and so do OUT_LATENCY / FLUSH_LEN, since a
    //  swap is pure rewiring and the scaling is combinational.
    //
    //  The swap is placed AFTER the window stage: window coefficients are
    //  real, so windowing and the re/im exchange commute -- window_stage
    //  needs no modification.
    // -----------------------------------------------------------------
    localparam int HALF = DATA_NB_BITS/2;

    logic [DATA_NB_BITS-1:0] core_in_data;   // wrapper input, after input swap
    logic [DATA_NB_BITS-1:0] pp_out_data;    // raw wrapper output
    logic [DATA_NB_BITS-1:0] pp_out_swapped; // after output swap
    logic [DATA_NB_BITS-1:0] pp_out_scaled;  // after 1/N scaling

    // Input swap: exchange the real and imaginary halves in iFFT mode.
    assign core_in_data = ifft_mode_r
                        ? {win_down_data[HALF-1:0], win_down_data[DATA_NB_BITS-1:HALF]}
                        : win_down_data;

    // FFT accelerator instance (conf_info_burst_len enables the deterministic drain)
    FFT_ping_pong #(
        .FLOAT_POINT(FLOAT_POINT),
        .FFT_SIZE(FFT_SIZE),
        .DATA_NB_BITS(DATA_NB_BITS)
    ) ping_pong_inst (
        .clk(clk),
        .rst_n(rst),
        .conf_info_burst_len(conf_info_burst_len),
        .in_valid(win_down_valid),
        .in_data(core_in_data),
        .in_ready(win_down_ready),
        .out_valid(pp_out_valid),
        .out_data(pp_out_data),
        .out_ready(dma_write_chnl_ready)
    );

    // Output swap, then division by FFT_SIZE. Both are combinational and
    // sit on the DMA write path, outside the core pipeline: they cost no
    // clock cycle and do not disturb the accelerator's latency.
    assign pp_out_swapped = {pp_out_data[HALF-1:0], pp_out_data[DATA_NB_BITS-1:HALF]};

    scale_by_n #(
        .FLOAT_POINT(FLOAT_POINT),
        .FFT_SIZE(FFT_SIZE),
        .DATA_NB_BITS(DATA_NB_BITS)
    ) scale_inst (
        .din(pp_out_swapped),
        .dout(pp_out_scaled)
    );

    // Forward mode: raw core output. Inverse mode: swapped and scaled.
    assign dma_write_chnl_data  = ifft_mode_r ? pp_out_scaled : pp_out_data;
    assign dma_write_chnl_valid = pp_out_valid;

    // ---------------------------------------------------
    //  DMA READ FSM
    //   * LOAD request  (conf_info_window[1]=1): read FFT_SIZE coefficient beats,
    //     wait until window_stage.load_done, then pulse acc_done_load.
    //   * COMPUTE request (conf_info_window[1]=0): read burst_len*FFT_SIZE sample
    //     beats; the normal compute path handles the rest.
    // ---------------------------------------------------
    typedef enum logic [2:0] { IDLE_R, REQ_R, WAIT_R, LOAD_WAIT_R } state_read_e;
    state_read_e read_st;

    // acc_done contribution from a LOAD request (a compute request uses the
    // WRITE FSM contribution instead). One-cycle pulse.
    logic acc_done_load;
    logic [31:0] read_index_r;   // sampled base index for the read transaction
    logic [31:0] out_index_r;    // sampled base index for the write transaction
    logic conf_done_r;           // delayed conf_done, for rising-edge detection

    // Rising edge of conf_done: true only on the first cycle conf_done is high.
    wire conf_done_rise = conf_done && !conf_done_r;

    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            read_st                  <= IDLE_R;
            dma_read_ctrl_valid      <= 0;
            dma_read_ctrl_data_index  <= 0;
            dma_read_ctrl_data_length <= 0;
            dma_read_ctrl_data_size   <= 0;
            dma_read_ctrl_data_user   <= 0;
            FFTs_read                <= 0;
            win_enable_r             <= 0;
            win_load_r               <= 0;
            ifft_mode_r              <= 0;
            win_start_pulse          <= 0;
            acc_done_load            <= 0;
            read_index_r             <= 0;
            out_index_r              <= 0;
            conf_done_r              <= 0;
        end else begin
            win_start_pulse <= 1'b0;   // default: one-cycle pulse
            acc_done_load   <= 1'b0;   // default: one-cycle pulse
            conf_done_r     <= conf_done;   // track previous value for edge detection
            case (read_st)
                IDLE_R: begin
                    // Start on conf_done. Three cases:
                    //   * LOAD request    (conf_info_window[1]=1): go read coefficients.
                    //   * COMPUTE request (burst_len > 0)    : go read samples.
                    //   * EMPTY request   (burst_len == 0, no load): no data to
                    //     process. Acknowledge immediately with a one-cycle acc_done
                    //     pulse and stay idle -- no DMA read, no DMA write. This lets
                    //     software issue a "no more data" request without hanging.
                    if (conf_done && (conf_info_window[1] || conf_info_burst_len > 0)) begin
                        FFTs_read       <= 0;
                        win_enable_r    <= conf_info_window[0];
                        win_load_r      <= conf_info_window[1];
                        ifft_mode_r     <= conf_info_ifft[0];   // inverse FFT mode
                        read_index_r    <= conf_info_index;     // read base index
                        out_index_r     <= conf_info_out_index; // write base index
                        win_start_pulse <= 1'b1;   // reset window_stage position counter
                        read_st         <= REQ_R;
                    end else if (conf_done_rise && !conf_info_window[1] && conf_info_burst_len == 0) begin
                        // Empty request: acknowledge and do nothing else.
                        // Rising-edge guard prevents a repeated pulse if conf_done
                        // stays high for more than one cycle.
                        acc_done_load <= 1'b1;
                    end
                end
                REQ_R: begin
                    dma_read_ctrl_valid       <= 1;
                    // LOAD: exactly FFT_SIZE coefficient beats.
                    // COMPUTE: burst_len*FFT_SIZE sample beats.
                    dma_read_ctrl_data_length <= win_load_r ? FFT_SIZE
                                                            : conf_info_burst_len * FFT_SIZE;
                    dma_read_ctrl_data_size   <= 3'b011; // 64-bit beats
                    dma_read_ctrl_data_user   <= 0;
                    dma_read_ctrl_data_index  <= read_index_r;   // base index of this request
                    read_st                   <= WAIT_R;
                end
                WAIT_R: begin
                    if (dma_read_ctrl_valid && dma_read_ctrl_ready) begin
                        dma_read_ctrl_valid <= 0;
                        if (win_load_r) begin
                            // LOAD: wait for the coefficients to be fully stored.
                            read_st <= LOAD_WAIT_R;
                        end else begin
                            FFTs_read <= conf_info_burst_len;
                            read_st   <= IDLE_R;
                        end
                    end
                end
                LOAD_WAIT_R: begin
                    // The read request was accepted; the agent streams FFT_SIZE
                    // coefficient beats. window_stage.load_done pulses once the
                    // last one is stored: signal completion and return to idle.
                    if (win_load_done) begin
                        acc_done_load <= 1'b1;
                        read_st       <= IDLE_R;
                    end
                end
            endcase
        end
    end

    // ---------------------------------------------------
    //  DMA WRITE FSM
    // ---------------------------------------------------
    typedef enum logic [1:0] { IDLE_W, WAIT_W } state_write_e;
    state_write_e write_st;
    logic [$clog2(FFT_SIZE):0] write_counter;

    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            write_st                   <= IDLE_W;
            dma_write_ctrl_valid       <= 0;
            dma_write_ctrl_data_index  <= 0;
            dma_write_ctrl_data_length <= 0;
            dma_write_ctrl_data_size   <= 0;
            dma_write_ctrl_data_user   <= 0;
            FFTs_written               <= 0;
            acc_done_compute           <= 0;
            write_counter              <= 0;
        end else begin
            acc_done_compute <= 0;
            case (write_st)
                IDLE_W: begin
                    if ((FFTs_written == conf_info_burst_len) && conf_info_burst_len > 0) begin
                        acc_done_compute <= 1;
                        FFTs_written     <= 0;
                    end
                    
                    if (pp_out_valid) begin
                        dma_write_ctrl_valid       <= 1;
                        dma_write_ctrl_data_length <= FFT_SIZE;
                        dma_write_ctrl_data_size   <= 3'b011;
                        dma_write_ctrl_data_user   <= 0;
                        dma_write_ctrl_data_index  <= out_index_r + FFTs_written * FFT_SIZE;
                        write_counter              <= 0;
                        write_st                   <= WAIT_W;
                    end
                end
                WAIT_W: begin
                    if (dma_write_ctrl_valid && dma_write_ctrl_ready) begin
                        dma_write_ctrl_valid <= 0;
                    end

                    if (dma_write_chnl_valid && dma_write_chnl_ready) begin
                        write_counter <= write_counter + 1;
                        if (write_counter == FFT_SIZE - 1) begin
                            FFTs_written <= FFTs_written + 1;
                            write_st     <= IDLE_W;
                        end
                    end
                end
            endcase
        end
    end

    // Merge the two completion sources into the output port.
    assign acc_done = acc_done_compute || acc_done_load;

endmodule

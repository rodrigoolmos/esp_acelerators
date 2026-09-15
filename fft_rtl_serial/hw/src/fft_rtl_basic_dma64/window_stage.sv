`timescale 1us/1ns

// =====================================================================
//  window_stage -- pre-processing windowing stage, placed between the DMA
//  read channel and the FFT_ping_pong wrapper.
//  ---------------------------------------------------------------------
//  A window of FFT_SIZE real coefficients is streamed in first and stored in a
//  combinational RAM. Afterwards, each incoming sample of the
//  burst is multiplied, in place, by the coefficient at the same position
//  in its frame:
//        out_re = sample_re * coef[coef_addr]
//        out_im = sample_im * coef[coef_addr]
//  The imaginary part of a coefficient is always zero.
//
//  Configuration bits (sampled once by the top level, stable during the
//  transaction):
//    win_enable : 1 = apply the window, 0 = bypass (samples pass through).
//    win_load   : 1 = the first FFT_SIZE beats of the transaction are
//                 coefficients to (re)load; 0 = keep the current RAM.
//
//  window_loaded : sticky flag, set once the RAM has been fully loaded.
//                  It survives accelerator soft resets because ESP can reset
//                  the IP between software launches while the coefficient RAM
//                  still keeps its contents. If win_enable=1 but
//                  window_loaded=0,
//                  the stage bypasses instead of multiplying by undefined
//                  RAM contents.

// =====================================================================
module window_stage #(
    parameter int FLOAT_POINT  = 1,   // 1 = IEEE-754 single, 0 = Q16.16 fixed point
    parameter int FFT_SIZE     = 32,
    parameter int DATA_NB_BITS = 64
)(
    input  logic                     clk,
    input  logic                     rst_n,

    // Configuration
    input  logic                     win_enable,
    input  logic                     win_load,
    input  logic                     start_pulse,   // 1-cycle pulse: new DMA transaction begins
    output logic                     window_loaded, // sticky
    output logic                     load_done,     // 1-cycle pulse: last coefficient just stored

    // Upstream (from DMA read channel)
    input  logic                     up_valid,
    input  logic [DATA_NB_BITS-1:0]  up_data,
    output logic                     up_ready,

    // Downstream (to FFT_ping_pong wrapper)
    output logic                     down_valid,
    output logic [DATA_NB_BITS-1:0]  down_data,
    input  logic                     down_ready
);

    localparam int HALF = DATA_NB_BITS/2;
    localparam int AW   = (FFT_SIZE > 1) ? $clog2(FFT_SIZE) : 1;

    // -----------------------------------------------------------------
    //  Current phase and position within the frame
    // -----------------------------------------------------------------
    // loading_coefs : 1 = incoming beats are COEFFICIENTS to be stored in
    //                 RAM (never forwarded downstream).
    //                 0 = incoming beats are SAMPLES to window and forward.
    //                 Loaded from the win_load port by start_pulse.
    logic          loading_coefs;


    logic [AW-1:0] coef_addr;

    // beat_accepted : The master signal of this module. Equals
    //                 up_valid && up_ready, i.e. "a beat is genuinely
    //                 taken this cycle". Nothing advances without it
    logic          beat_accepted;

    // last_coef_accepted : pulse "the very last coefficient was just
    //                      accepted" -> marks the end of the load phase.
    logic last_coef_accepted;
    assign last_coef_accepted = loading_coefs && beat_accepted && (coef_addr == FFT_SIZE-1);

    (* ram_style = "distributed" *) logic [HALF-1:0] coef_ram [FFT_SIZE];

    initial window_loaded = 1'b0;

    logic [HALF-1:0] coef_value;
    assign coef_value = coef_ram[coef_addr];

    always_ff @(posedge clk) begin
        if (loading_coefs && beat_accepted)
            coef_ram[coef_addr] <= up_data[DATA_NB_BITS-1:HALF];   // high 32 bits = real coefficient of window, low 32 bits = 0
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            coef_addr           <= '0;
            loading_coefs       <= 1'b0;
            load_done     <= 1'b0;
        end else begin
            load_done <= 1'b0;             // one-cycle pulse
            if (start_pulse) begin
                coef_addr     <= '0;
                loading_coefs <= win_load;
            end else if (beat_accepted) begin
                if (coef_addr == FFT_SIZE-1) coef_addr <= '0;
                else coef_addr <= coef_addr + 1'b1;
                if (last_coef_accepted) begin
                    loading_coefs <= 1'b0;
                    load_done     <= 1'b1;    // pulse: last coefficient stored this cycle
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (start_pulse && win_load) begin
            window_loaded <= 1'b0;
        end else if (last_coef_accepted) begin
            window_loaded <= 1'b1;
        end
    end

    //   window_active : FINAL decision to windowing, not to be confused with
    //   the win_enable port. Safety net: even if software requests
    //   windowing (win_enable=1), we do not multiply until a window has
    //   actually been loaded (window_loaded=0), otherwise we would
    //   multiply by RAM contents that are still undefined.
    logic window_active;
    assign window_active = win_enable && window_loaded;

    // -----------------------------------------------------------------
    //  Datapath + output handshake.
    //  fp_mul32_lite has one output register (1-cycle latency). A companion
    //  register, clocked identically, carries the raw sample
    //  and the windowing decision, so together they form one output stage
    //  presented to the downstream. A new stream beat is accepted only when
    //  this stage is free or being consumed this cycle, so no result is
    //  overwritten. During the load phase, beats go to the RAM only.
    // -----------------------------------------------------------------
    logic sample_accepted; // A sample (not window coef) is accepted

    // sample_re / sample_im :
    //   Real part in the high bits, imaginary part in the low bits.
    logic [HALF-1:0] sample_re, sample_im;
    assign sample_re = up_data[DATA_NB_BITS-1:HALF];
    assign sample_im = up_data[HALF-1:0];

    // windowed_re / windowed_im: result of the sample*coefficient
    //   product, available one cycle after acceptance.
    logic [HALF-1:0] windowed_re, windowed_im;

    generate
        if (FLOAT_POINT) begin : g_mul_float
            // IEEE-754 single precision: one output register inside (latency 1).
            fp_mul32_lite u_mul_re (
                .clk(clk), .rst_n(rst_n), .en(sample_accepted),
                .a_i(sample_re), .b_i(coef_value), .res_o(windowed_re)
            );
            fp_mul32_lite u_mul_im (
                .clk(clk), .rst_n(rst_n), .en(sample_accepted),
                .a_i(sample_im), .b_i(coef_value), .res_o(windowed_im)
            );
        end else begin : g_mul_fixed
            // Q16.16: the product of two Q16.16 values is a 2*HALF-bit number,
            // rescaled by >>> 16. The full-width intermediate is mandatory:
            // truncating before the shift would destroy the integer part.
            // Registered once, with the same enable, to match the latency of
            // the floating-point multiplier exactly (1 cycle).
            logic signed [2*HALF-1:0] prod_re, prod_im;
            always_comb begin
                prod_re = $signed(sample_re) * $signed(coef_value);
                prod_im = $signed(sample_im) * $signed(coef_value);
            end
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    windowed_re <= '0;
                    windowed_im <= '0;
                end else if (sample_accepted) begin
                    windowed_re <= HALF'($signed(prod_re) >>> 16);
                    windowed_im <= HALF'($signed(prod_im) >>> 16);
                end
            end
        end
    endgenerate

    // --- Output stage ---
    // out_valid_r  : a valid result is present in the stage.
    // out_bypass_r : the RAW data held for the bypass case.
    // out_apply_r  : the windowing decision held together with its data.
    //                Important: if win_enable changed in the meantime, a
    //                sample already in flight keeps its own decision, made
    //                at the moment it was accepted.
    logic                    out_valid_r;
    logic [DATA_NB_BITS-1:0] out_bypass_r;
    logic                    out_apply_r;

    // out_stage_free: the output stage will be able to receive a new
    //   result next cycle, either because it is empty, or because
    //   downstream is draining it this very cycle.
    logic out_stage_free;
    assign out_stage_free = !out_valid_r || down_ready;

    // Accept a new stream beat only when the output stage will be free to
    // receive its result next cycle.
    // sample_accepted : a SAMPLE (not a coefficient) is accepted this
    //   cycle -> this is what enables the multiplier and loads the output
    //   stage. During loading, beats go to the RAM only, so this signal
    //   stays low.
    assign sample_accepted = beat_accepted && !loading_coefs;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid_r  <= 1'b0;
            out_bypass_r <= '0;
            out_apply_r  <= 1'b0;
        end else begin
            if (out_stage_free) begin
                // Next cycle this stage holds the result of a beat accepted now.
                out_valid_r <= sample_accepted;
                if (sample_accepted) begin
                    out_bypass_r <= up_data;
                    out_apply_r  <= window_active;
                end
            end
            // else: hold current output until the downstream consumes it.
        end
    end

    assign down_valid = out_valid_r;
    assign down_data  = out_apply_r ? {windowed_re, windowed_im} : out_bypass_r;

    // -----------------------------------------------------------------
    //  Handshake
    // -----------------------------------------------------------------
    //  Load phase: always accept (RAM writes never stall).
    //  Stream phase: accept only when the output stage is free, so the
    //  multiplier result produced next cycle is never dropped.
    assign up_ready = loading_coefs ? 1'b1 : out_stage_free;
    assign beat_accepted  = up_valid && up_ready;

endmodule

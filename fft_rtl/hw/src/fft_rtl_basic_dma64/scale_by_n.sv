// =====================================================================
//  scale_by_n
//
//  Divides a complex sample by FFT_SIZE.
//
//  Used on the OUTPUT path when the accelerator runs in inverse-FFT mode:
//      iFFT(X) = (1/N) * swap( FFT( swap(X) ) )
//  the 1/N factor being applied here.
//
//  PURELY COMBINATIONAL: adding a pipeline register here
//  would change the accelerator's total latency. Placed on the
//  DMA write path, outside the core pipeline, it costs no cycle at all.
// =====================================================================
module scale_by_n #(
    parameter logic FLOAT_POINT  = 1'b1,   // 1 = IEEE-754 single, 0 = Q16.16
    parameter int   FFT_SIZE     = 4096,   // divide by this (power of 2)
    parameter int   DATA_NB_BITS = 64
)(
    input  logic [DATA_NB_BITS-1:0] din,
    output logic [DATA_NB_BITS-1:0] dout
);

    localparam int HALF  = DATA_NB_BITS/2;      // 32 bits per lane
    localparam int SHIFT = $clog2(FFT_SIZE);    // log2(N)

    // Scale one 32-bit lane by 1/N.
    function automatic logic [HALF-1:0] scale_lane(input logic [HALF-1:0] v);
        logic              s;       // sign bit
        logic [7:0]        e;       // biased exponent
        logic [HALF-10:0]  m;       // mantissa (23 bits when HALF = 32)
        logic signed [9:0] e_new;   // exponent after subtraction (can go <= 0)
        begin
            if (FLOAT_POINT) begin
                s = v[HALF-1];
                e = v[HALF-2 -: 8];
                m = v[HALF-10:0];

                if (e == 8'd0) begin
                    // Input is zero: result is zero, sign preserved.
                    scale_lane = {s, {(HALF-1){1'b0}}};
                end else begin
                    e_new = $signed({2'b00, e}) - SHIFT;
                    if (e_new <= 0)
                        scale_lane = {s, {(HALF-1){1'b0}}};  // underflow -> zero
                    else
                        scale_lane = {s, e_new[7:0], m};     // mantissa unchanged
                end
            end else begin
                // Q16.16: arithmetic right shift by log2(N).
                scale_lane = HALF'($signed(v) >>> SHIFT);
            end
        end
    endfunction

    assign dout[DATA_NB_BITS-1:HALF] = scale_lane(din[DATA_NB_BITS-1:HALF]);
    assign dout[HALF-1:0]            = scale_lane(din[HALF-1:0]);

endmodule

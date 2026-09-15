`timescale 1us/1ns

// =====================================================================
//  twiddle_rom_sdf -- combinational ROM of twiddle factors for one
//  even (rotator) stage of the radix-2^2 SDF pipeline.
//  For a given stage-local address it outputs W = exp(-j*2*pi*p/FFT_SIZE),
//  where p follows the radix-2^2 twiddle schedule. Stored as IEEE-754
//  (FLOAT_POINT=1) or Q16.16 fixed point (FLOAT_POINT=0).
// =====================================================================
module twiddle_rom_sdf #(
    parameter int STAGE = 0,         // global stage index (0-based)
    parameter int FFT_SIZE = 16,
    parameter int FLOAT_POINT=1,
    parameter int WIDTH = 32         // DATA_NB_BITS / 2
)(
    input  logic [$clog2(FFT_SIZE)-1:0] addr, // stage-local counter value
    output logic [WIDTH-1:0]            W_re,
    output logic [WIDTH-1:0]            W_im
);
    localparam int R = STAGE / 2;             // radix-2^2 pair index
    localparam int N_OVER_4_R1 = FFT_SIZE / (1 << (2 + 2 * R));
    localparam int POWER_2K    = 1 << (2 * R);
    localparam int VECTOR_SIZE = 4 * N_OVER_4_R1;

    // Maps the address to the twiddle index 'p' for this stage (radix-2^2 schedule)
    int p_index;
    always_comb begin
        automatic int i = addr % VECTOR_SIZE;
        if (i < N_OVER_4_R1)       p_index = 0;
        else if (i < 2*N_OVER_4_R1) p_index = 2 * POWER_2K * (i - N_OVER_4_R1);
        else if (i < 3*N_OVER_4_R1) p_index = 1 * POWER_2K * (i - 2*N_OVER_4_R1);
        else                        p_index = 3 * POWER_2K * (i - 3*N_OVER_4_R1);
    end

    // ROM contents
    logic [WIDTH-1:0] rom_re [FFT_SIZE];
    logic [WIDTH-1:0] rom_im [FFT_SIZE];

    static real PI = 3.141592653589793;

    function automatic logic [WIDTH-1:0] to_fixed(real value);
        return int'(value * 65536.0);
    endfunction

    initial begin
        for (int i = 0; i < FFT_SIZE; i++) begin
            automatic real real_angle = -2.0 * PI * real'(i) / FFT_SIZE;
            if (FLOAT_POINT) begin
                rom_re[i] = $shortrealtobits(shortreal'($cos(real_angle)));
                rom_im[i] = $shortrealtobits(shortreal'($sin(real_angle)));
                    
            end else begin
                rom_re[i] = to_fixed($cos(real_angle));
                rom_im[i] = to_fixed($sin(real_angle));
            end
        end
    end

    assign W_re = rom_re[p_index];
    assign W_im = rom_im[p_index];

endmodule
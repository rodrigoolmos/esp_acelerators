module transpose #(
    parameter int DATA_WIDTH = 64,
    parameter int ADDR_WIDTH = 10,
    parameter int NUM_ROWS   = 8,
    parameter int NUM_COLS   = 16,
    parameter int DEPTH      = NUM_ROWS * NUM_COLS
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic [ADDR_WIDTH-1:0] addr_read,
    output logic [DATA_WIDTH-1:0] data_read,

    input  logic [ADDR_WIDTH-1:0] addr_write,
    input  logic                  ena_write,
    input  logic [DATA_WIDTH-1:0] data_write
);

    localparam int ROW_BITS = $clog2(NUM_ROWS);
    localparam int COL_BITS = $clog2(NUM_COLS);

    logic [ADDR_WIDTH-1:0] transpose_waddr;
    logic [ADDR_WIDTH-1:0] mem_addr;

    logic [COL_BITS-1:0] col;
    logic [ROW_BITS-1:0] row;

    assign transpose_waddr =
        ((addr_write & (NUM_COLS-1)) << ROW_BITS)
        | (addr_write >> COL_BITS);

    assign mem_addr = ena_write
                    ? transpose_waddr
                    : addr_read;

    bram #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DEPTH(DEPTH)
    ) bram_inst (
        .clk  (clk),
        .en   (1'b1),
        .we   (ena_write),
        .addr (mem_addr),
        .din  (data_write),
        .dout (data_read)
    );

endmodule
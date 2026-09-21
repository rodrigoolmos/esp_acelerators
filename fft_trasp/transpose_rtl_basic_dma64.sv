`timescale 1ns/1ps

// Cada elemento es una muestra compleja I/Q de 32+32 bits.
// Una muestra completa por beat DMA; I y Q siempre se mueven juntos.
// reg0: direccion base en beats; reg1: NUM_ROWS * NUM_COLS beats.
// La salida sobrescribe la entrada una vez cargada toda la matriz en BRAM.
module transpose_rtl_basic_dma64 #(
    parameter int NUM_ROWS = 8,
    parameter int NUM_COLS = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] conf_info_reg0,
    input  logic [31:0] conf_info_reg1,
    input  logic        conf_done,
    output logic        acc_done,
    output logic [31:0] debug,
    input  logic        dma_read_ctrl_ready,
    output logic        dma_read_ctrl_valid,
    output logic [31:0] dma_read_ctrl_data_index,
    output logic [31:0] dma_read_ctrl_data_length,
    output logic [2:0]  dma_read_ctrl_data_size,
    output logic [5:0]  dma_read_ctrl_data_user,
    output logic        dma_read_chnl_ready,
    input  logic        dma_read_chnl_valid,
    input  logic [63:0] dma_read_chnl_data,
    input  logic        dma_write_ctrl_ready,
    output logic        dma_write_ctrl_valid,
    output logic [31:0] dma_write_ctrl_data_index,
    output logic [31:0] dma_write_ctrl_data_length,
    output logic [2:0]  dma_write_ctrl_data_size,
    output logic [5:0]  dma_write_ctrl_data_user,
    input  logic        dma_write_chnl_ready,
    output logic        dma_write_chnl_valid,
    output logic [63:0] dma_write_chnl_data
);
    localparam int DEPTH = NUM_ROWS * NUM_COLS;
    localparam int ADDR_WIDTH = $clog2(DEPTH);
    localparam int DMA_BEATS = DEPTH;

    // La transposicion ocurre al escribir: no requiere fase COMPUTE.
    typedef enum logic [2:0] {
        IDLE = 0, DMA_READ = 1, DMA_WRITE = 3, DONE = 4
    } state_t;
    state_t state;

    logic [31:0] base_index;
    logic config_error;
    logic read_started, write_started, output_valid;
    logic [ADDR_WIDTH-1:0] input_ptr, output_ptr;
    logic core_write;
    logic [63:0] core_read_data;

    // El direccionamiento del core requiere dimensiones potencia de dos.
    // synthesis translate_off
    initial begin
        if (NUM_ROWS < 2 || NUM_COLS < 2 ||
            (NUM_ROWS & (NUM_ROWS - 1)) != 0 ||
            (NUM_COLS & (NUM_COLS - 1)) != 0)
            $fatal(1, "NUM_ROWS y NUM_COLS deben ser potencias de dos >= 2");
    end
    // synthesis translate_on

    assign dma_read_ctrl_valid = rst_n && state == DMA_READ && !read_started;
    assign dma_read_ctrl_data_index = base_index;
    assign dma_read_ctrl_data_length = DMA_BEATS;
    assign dma_read_ctrl_data_size = 3'b011;
    assign dma_read_ctrl_data_user = 6'd0;
    assign dma_read_chnl_ready = rst_n && state == DMA_READ && read_started;

    assign dma_write_ctrl_valid = rst_n && state == DMA_WRITE && !write_started;
    assign dma_write_ctrl_data_index = base_index;
    assign dma_write_ctrl_data_length = DMA_BEATS;
    assign dma_write_ctrl_data_size = 3'b011;
    assign dma_write_ctrl_data_user = 6'd0;
    assign dma_write_chnl_valid = rst_n && state == DMA_WRITE && output_valid;
    assign dma_write_chnl_data = core_read_data;
    assign acc_done = rst_n && state == DONE;
    assign debug = {config_error, 28'd0, state};

    assign core_write = dma_read_chnl_ready && dma_read_chnl_valid;

    transpose #(
        .DATA_WIDTH(64), .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_ROWS(NUM_ROWS), .NUM_COLS(NUM_COLS), .DEPTH(DEPTH)
    ) core (
        .clk(clk), .rst_n(rst_n),
        .addr_read(output_ptr), .data_read(core_read_data),
        .addr_write(input_ptr), .ena_write(core_write),
        .data_write(dma_read_chnl_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            base_index <= '0;
            config_error <= 1'b0;
            input_ptr <= '0;
            output_ptr <= '0;
            read_started <= 1'b0;
            write_started <= 1'b0;
            output_valid <= 1'b0;
        end else begin
            case (state)
                IDLE: if (conf_done) begin
                    base_index <= conf_info_reg0;
                    input_ptr <= '0;
                    output_ptr <= '0;
                    read_started <= 1'b0;
                    write_started <= 1'b0;
                    output_valid <= 1'b0;
                    config_error <= conf_info_reg1 != DMA_BEATS;
                    state <= conf_info_reg1 == DMA_BEATS ? DMA_READ : DONE;
                end
                DMA_READ: begin
                    if (dma_read_ctrl_valid && dma_read_ctrl_ready)
                        read_started <= 1'b1;
                    if (dma_read_chnl_valid && dma_read_chnl_ready) begin
                        // Una escritura de 64 bits conserva la pareja I/Q.
                        if (input_ptr == DEPTH - 1)
                            state <= DMA_WRITE;
                        else
                            input_ptr <= input_ptr + 1'b1;
                    end
                end
                DMA_WRITE: begin
                    if (dma_write_ctrl_valid && dma_write_ctrl_ready)
                        write_started <= 1'b1;
                    if (write_started) begin
                        if (!output_valid) begin
                            // La BRAM registra la direccion actual en este flanco.
                            // Su salida y valid quedan disponibles tras el flanco.
                            output_valid <= 1'b1;
                        end else if (dma_write_chnl_ready) begin
                            output_valid <= 1'b0;
                            if (output_ptr == DEPTH - 1)
                                state <= DONE;
                            else
                                output_ptr <= output_ptr + 1'b1;
                        end
                        // Sin ready se mantiene la direccion y el dato de BRAM.
                    end
                end
                DONE: state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule

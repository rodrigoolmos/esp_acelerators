`timescale 1ns/1ps

module tb_transpose;
    localparam int DATA_WIDTH = 64;
    localparam int ADDR_WIDTH = 10;
    localparam int NUM_ROWS   = 8;
    localparam int NUM_COLS   = 16;
    localparam int DEPTH      = NUM_ROWS * NUM_COLS;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [ADDR_WIDTH-1:0] addr_read = '0;
    logic [DATA_WIDTH-1:0] data_read;
    logic [ADDR_WIDTH-1:0] addr_write = '0;
    logic ena_write = 1'b0;
    logic [DATA_WIDTH-1:0] data_write = '0;
    logic [DATA_WIDTH-1:0] expected;
    int source_index;
    int checks = 0;

    always #5 clk = ~clk; // 100 MHz

    transpose #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_ROWS(NUM_ROWS),
        .NUM_COLS(NUM_COLS),
        .DEPTH(DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .addr_read(addr_read),
        .data_read(data_read),
        .addr_write(addr_write),
        .ena_write(ena_write),
        .data_write(data_write)
    );

    function automatic logic [DATA_WIDTH-1:0] pattern(
        input int index, input int pass
    );
        // I y Q distintos: detectar truncamiento o intercambio de componentes.
        pattern = {32'h80000000 | 32'(index), 32'(index + 1)};
        if (pass != 0) pattern = ~pattern;
    endfunction

    initial begin
        // Activar las ondas ejecutando la simulacion con +dump.
        if ($test$plusargs("dump")) begin
            $dumpfile("tb_transpose.vcd");
            $dumpvars(0, tb_transpose);
        end

        repeat (2) @(negedge clk);
        rst_n = 1'b1; // El RTL actual no utiliza reset ni borra la memoria.

        // Dos pasadas: carga inicial y sobrescritura con otro patron.
        for (int pass = 0; pass < 2; pass++) begin
            for (int i = 0; i < DEPTH; i++) begin
                @(negedge clk);
                ena_write = 1'b1;
                addr_write = ADDR_WIDTH'(i);
                data_write = pattern(i, pass);
            end

            // Se deja pasar el flanco que escribe el ultimo dato.
            @(negedge clk);
            ena_write = 1'b0;
            data_write = '0;

            for (int i = 0; i < DEPTH; i++) begin
                @(negedge clk);
                addr_read = ADDR_WIDTH'(i);
                // B[col][row] = A[row][col], ambas en orden por filas.
                source_index = (i % NUM_ROWS) * NUM_COLS + i / NUM_ROWS;
                expected = pattern(source_index, pass);
                @(posedge clk);
                #1; // Esperar la actualizacion no bloqueante de la BRAM.
                if (data_read !== expected)
                    $fatal(1, "FAIL pasada=%0d addr=%0d esperado=%h obtenido=%h",
                           pass, i, expected, data_read);
                checks++;
            end
        end

        $display("PASS: %0d lecturas correctas, matriz %0dx%0d, dos patrones.",
                 checks, NUM_ROWS, NUM_COLS);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "TIMEOUT: la simulacion no ha terminado");
    end
endmodule

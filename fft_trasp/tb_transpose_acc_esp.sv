`timescale 1ns/1ps
`include "agent_transpose_esp.sv"

module tb_transpose_acc_esp;
    parameter int NUM_ROWS = 8;
    parameter int NUM_COLS = 16;
    localparam int DMA_BEATS = NUM_ROWS * NUM_COLS;
    logic [63:0] source[], gold[], result_acc[];
    agent_transpose_esp agent;
    esp_acc_if esp_acc_if_inst();
    int read_requests = 0, write_requests = 0;
    int read_beats = 0, write_beats = 0, done_pulses = 0;
    bit prev_read_stall = 0, prev_write_stall = 0, prev_data_stall = 0;
    bit prev_done = 0;
    logic [72:0] prev_read_desc, prev_write_desc;
    logic [63:0] prev_data;

    transpose_rtl_basic_dma64 #(.NUM_ROWS(NUM_ROWS), .NUM_COLS(NUM_COLS)) dut (
        .clk(esp_acc_if_inst.clk),
        .rst_n(esp_acc_if_inst.rst),
        .conf_info_reg0(esp_acc_if_inst.conf_info_reg0),
        .conf_info_reg1(esp_acc_if_inst.conf_info_reg1),
        .conf_done(esp_acc_if_inst.conf_done),
        .acc_done(esp_acc_if_inst.acc_done),
        .debug(esp_acc_if_inst.debug),
        .dma_read_ctrl_ready(esp_acc_if_inst.dma_read_ctrl_ready),
        .dma_read_ctrl_valid(esp_acc_if_inst.dma_read_ctrl_valid),
        .dma_read_ctrl_data_index(esp_acc_if_inst.dma_read_ctrl_data_index),
        .dma_read_ctrl_data_length(esp_acc_if_inst.dma_read_ctrl_data_length),
        .dma_read_ctrl_data_size(esp_acc_if_inst.dma_read_ctrl_data_size),
        .dma_read_ctrl_data_user(esp_acc_if_inst.dma_read_ctrl_data_user),
        .dma_read_chnl_ready(esp_acc_if_inst.dma_read_chnl_ready),
        .dma_read_chnl_valid(esp_acc_if_inst.dma_read_chnl_valid),
        .dma_read_chnl_data(esp_acc_if_inst.dma_read_chnl_data),
        .dma_write_ctrl_ready(esp_acc_if_inst.dma_write_ctrl_ready),
        .dma_write_ctrl_valid(esp_acc_if_inst.dma_write_ctrl_valid),
        .dma_write_ctrl_data_index(esp_acc_if_inst.dma_write_ctrl_data_index),
        .dma_write_ctrl_data_length(esp_acc_if_inst.dma_write_ctrl_data_length),
        .dma_write_ctrl_data_size(esp_acc_if_inst.dma_write_ctrl_data_size),
        .dma_write_ctrl_data_user(esp_acc_if_inst.dma_write_ctrl_data_user),
        .dma_write_chnl_ready(esp_acc_if_inst.dma_write_chnl_ready),
        .dma_write_chnl_valid(esp_acc_if_inst.dma_write_chnl_valid),
        .dma_write_chnl_data(esp_acc_if_inst.dma_write_chnl_data)
    );

    initial begin
        esp_acc_if_inst.clk = 0;
        forever #5 esp_acc_if_inst.clk = ~esp_acc_if_inst.clk;
    end

    // Comprobar estabilidad de valid y payload cuando el receptor bloquea.
    always @(posedge esp_acc_if_inst.clk) begin
        if (!esp_acc_if_inst.rst) begin
            prev_read_stall = 0;
            prev_write_stall = 0;
            prev_data_stall = 0;
            prev_done = 0;
        end else begin
            if (prev_read_stall &&
                (esp_acc_if_inst.dma_read_ctrl_valid !== 1'b1 ||
                 {esp_acc_if_inst.dma_read_ctrl_data_index,
                  esp_acc_if_inst.dma_read_ctrl_data_length,
                  esp_acc_if_inst.dma_read_ctrl_data_size,
                  esp_acc_if_inst.dma_read_ctrl_data_user} !== prev_read_desc))
                $fatal(1, "Descriptor de lectura cambia durante bloqueo");
            if (prev_write_stall &&
                (esp_acc_if_inst.dma_write_ctrl_valid !== 1'b1 ||
                 {esp_acc_if_inst.dma_write_ctrl_data_index,
                  esp_acc_if_inst.dma_write_ctrl_data_length,
                  esp_acc_if_inst.dma_write_ctrl_data_size,
                  esp_acc_if_inst.dma_write_ctrl_data_user} !== prev_write_desc))
                $fatal(1, "Descriptor de escritura cambia durante bloqueo");
            if (prev_data_stall &&
                (esp_acc_if_inst.dma_write_chnl_valid !== 1'b1 ||
                 esp_acc_if_inst.dma_write_chnl_data !== prev_data))
                $fatal(1, "Dato de salida cambia durante bloqueo");
            if (prev_done && esp_acc_if_inst.acc_done)
                $fatal(1, "Pulso acc_done demasiado largo");
            prev_read_stall = esp_acc_if_inst.dma_read_ctrl_valid &&
                              !esp_acc_if_inst.dma_read_ctrl_ready;
            prev_write_stall = esp_acc_if_inst.dma_write_ctrl_valid &&
                               !esp_acc_if_inst.dma_write_ctrl_ready;
            prev_data_stall = esp_acc_if_inst.dma_write_chnl_valid &&
                              !esp_acc_if_inst.dma_write_chnl_ready;
            prev_read_desc = {esp_acc_if_inst.dma_read_ctrl_data_index,
                              esp_acc_if_inst.dma_read_ctrl_data_length,
                              esp_acc_if_inst.dma_read_ctrl_data_size,
                              esp_acc_if_inst.dma_read_ctrl_data_user};
            prev_write_desc = {esp_acc_if_inst.dma_write_ctrl_data_index,
                               esp_acc_if_inst.dma_write_ctrl_data_length,
                               esp_acc_if_inst.dma_write_ctrl_data_size,
                               esp_acc_if_inst.dma_write_ctrl_data_user};
            prev_data = esp_acc_if_inst.dma_write_chnl_data;
            prev_done = esp_acc_if_inst.acc_done;
            if (esp_acc_if_inst.dma_read_ctrl_valid && esp_acc_if_inst.dma_read_ctrl_ready)
                read_requests++;
            if (esp_acc_if_inst.dma_write_ctrl_valid && esp_acc_if_inst.dma_write_ctrl_ready)
                write_requests++;
            if (esp_acc_if_inst.dma_read_chnl_valid && esp_acc_if_inst.dma_read_chnl_ready)
                read_beats++;
            if (esp_acc_if_inst.dma_write_chnl_valid && esp_acc_if_inst.dma_write_chnl_ready)
                write_beats++;
            if (esp_acc_if_inst.acc_done) done_pulses++;
        end
    end

    task automatic check_invalid(input int length);
        agent.configure(17, length);
        if (esp_acc_if_inst.acc_done !== 1'b1 || esp_acc_if_inst.debug[31] !== 1'b1 ||
            esp_acc_if_inst.dma_read_ctrl_valid !== 1'b0 ||
            esp_acc_if_inst.dma_write_ctrl_valid !== 1'b0)
            $fatal(1, "No se ha rechazado la longitud %0d", length);
        @(negedge esp_acc_if_inst.clk);
    endtask

    initial begin
        agent = new(esp_acc_if_inst);
        esp_acc_if_inst.rst = 0;
        repeat (3) @(negedge esp_acc_if_inst.clk);
        esp_acc_if_inst.rst = 1;
        source = new[DMA_BEATS];
        // Tres ejecuciones sin reset: distintas bases y muestras I/Q de 64 bits.
        // Convencion del TB: I en [31:0], Q en [63:32], con patrones distintos.
        for (int pass = 0; pass < 3; pass++) begin
            for (int i = 0; i < DMA_BEATS; i++) begin
                case (pass)
                    0: source[i] = {32'h80000000 | 32'(i), 32'(i + 1)};
                    1: source[i] = {32'h7fffffff - 32'(i), ~32'(i)};
                    2: source[i] = {32'h80000000 ^ (32'(2*i+1)*32'h1234567),
                                    32'hdeadbeef ^ (32'(2*i)*32'h7654321)};
                endcase
            end
            agent.load_memory(pass * (DMA_BEATS + 7), DMA_BEATS, source);
            agent.gold_gen(source, NUM_ROWS, NUM_COLS, gold);
            agent.run(pass * (DMA_BEATS + 7), DMA_BEATS, pass != 0);
            agent.collect_memory(pass * (DMA_BEATS + 7), DMA_BEATS, result_acc);
            if (agent.validate_acc(result_acc, gold, DMA_BEATS))
                $fatal(1, "Transposicion incorrecta en pasada %0d", pass);
            $display("PASS pasada=%0d matriz=%0dx%0d beats=%0d pausas=%0d",
                     pass, NUM_ROWS, NUM_COLS, DMA_BEATS, pass != 0);
        end
        check_invalid(0);
        check_invalid(DMA_BEATS - 1);
        check_invalid(DMA_BEATS / 2); // Rechazar la antigua longitud de dos elementos/beat.
        // Recuperacion despues de configuraciones invalidas.
        agent.load_memory(23, DMA_BEATS, source);
        agent.run(23, DMA_BEATS, 1);
        agent.collect_memory(23, DMA_BEATS, result_acc);
        if (agent.validate_acc(result_acc, gold, DMA_BEATS))
            $fatal(1, "Fallo de recuperacion tras configuracion invalida");
        repeat (3) @(negedge esp_acc_if_inst.clk);
        if (read_requests != 4 || write_requests != 4 ||
            read_beats != 4 * DMA_BEATS || write_beats != 4 * DMA_BEATS ||
            done_pulses != 7)
            $fatal(1, "Numero incorrecto de transacciones o pulsos done");
        $display("PASS DMA: 4 matrices, %0d muestras I/Q verificadas, pausas y 3 configuraciones invalidas",
                 4 * DMA_BEATS);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "TIMEOUT debug=%h", esp_acc_if_inst.debug);
    end
endmodule

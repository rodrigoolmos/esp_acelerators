`ifndef AGENT_TRANSPOSE_ESP_SV
`define AGENT_TRANSPOSE_ESP_SV
`timescale 1ns/1ps

interface esp_acc_if;

    logic clk;                              // Main clock signal for the accelerator (provided by ESP socket)
    logic rst;                              // Active-low synchronous reset signal (provided by ESP socket)

    // << User-defined configuration registers >>
    logic [31:0] conf_info_reg0;            // Configuration register 0 (typically used as read data index)
    logic [31:0] conf_info_reg1;            // Configuration register 1 (typically used as read data length)

    logic conf_done;                        // One-cycle pulse indicating that configuration registers are valid

    logic acc_done;                         // One-cycle pulse from the accelerator indicating completion
    logic [31:0] debug;                     // Optional debug output (e.g., error codes, FSM state)

    // DMA Read Control – signals for initiating a DMA read transaction
    logic dma_read_ctrl_ready;              // From socket: high when ready to accept a new read request
    logic dma_read_ctrl_valid;              // From accelerator: high when issuing a read request
    logic [31:0] dma_read_ctrl_data_index;  // Offset (in beats) from the base of the virtual memory region
    logic [31:0] dma_read_ctrl_data_length; // Number of beats to read
    logic [2:0] dma_read_ctrl_data_size;    // Beat size encoding (e.g., 011 = 64-bit)
    logic [5:0] dma_read_ctrl_data_user;    // User-defined field to select source (e.g., memory, P2P, multicast)

    // DMA Read Channel – signals for receiving data from memory
    logic dma_read_chnl_ready;              // From accelerator: high when ready to receive data
    logic dma_read_chnl_valid;              // From socket: high when data is available
    logic [63:0] dma_read_chnl_data;        // Data beat received from memory (typically 64-bit)

    // DMA Write Control – signals for initiating a DMA write transaction
    logic dma_write_ctrl_ready;             // From socket: high when ready to accept a new write request
    logic dma_write_ctrl_valid;             // From accelerator: high when issuing a write request
    logic [31:0] dma_write_ctrl_data_index; // Offset (in beats) from the base of the virtual memory region
    logic [31:0] dma_write_ctrl_data_length;// Number of beats to write
    logic [2:0] dma_write_ctrl_data_size;   // Beat size encoding (e.g., 011 = 64-bit)
    logic [5:0] dma_write_ctrl_data_user;   // User-defined field to select target (e.g., memory, P2P, multicast)

    // DMA Write Channel – signals for sending data to memory
    logic dma_write_chnl_ready;             // From socket: high when ready to receive write data
    logic dma_write_chnl_valid;             // From accelerator: high when write data is valid
    logic [63:0] dma_write_chnl_data;       // Data beat sent to memory (typically 64-bit)

endinterface

class agent_transpose_esp;
    virtual esp_acc_if esp_if;
    logic [63:0] mem[int unsigned];
    int unsigned read_index, read_length, write_index, write_length;

    function new(virtual esp_acc_if esp_if);
        this.esp_if = esp_if;
        esp_if.conf_info_reg0 = 0;
        esp_if.conf_info_reg1 = 0;
        esp_if.conf_done = 0;
        esp_if.dma_read_ctrl_ready = 0;
        esp_if.dma_read_chnl_valid = 0;
        esp_if.dma_read_chnl_data = 0;
        esp_if.dma_write_ctrl_ready = 0;
        esp_if.dma_write_chnl_ready = 0;
    endfunction

    task load_memory(input int unsigned base, input int unsigned length,
                     input logic [63:0] data[]);
        for (int i = 0; i < length; i++) mem[base + i] = data[i];
    endtask

    task collect_memory(input int unsigned base, input int unsigned length,
                        ref logic [63:0] data[]);
        data = new[length];
        for (int i = 0; i < length; i++) data[i] = mem[base + i];
    endtask

    task configure(input int unsigned base, input int unsigned length);
        @(negedge esp_if.clk);
        esp_if.conf_info_reg0 = base;
        esp_if.conf_info_reg1 = length;
        esp_if.conf_done = 1;
        @(negedge esp_if.clk);
        esp_if.conf_done = 0;
    endtask

    // Todos los estimulos cambian en negedge; se muestrean en posedge.
    // stalls introduce pausas reproducibles en control y ambos canales.
    task run(input int unsigned cfg_index, input int unsigned cfg_length,
             input bit stalls = 0);
        configure(cfg_index, cfg_length);
        wait (esp_if.dma_read_ctrl_valid === 1'b1);
        repeat (stalls ? 4 : 0) @(negedge esp_if.clk);
        @(negedge esp_if.clk);
        esp_if.dma_read_ctrl_ready = 1;
        @(posedge esp_if.clk);
        if (esp_if.dma_read_ctrl_valid !== 1'b1 ||
            esp_if.dma_read_ctrl_data_index !== cfg_index ||
            esp_if.dma_read_ctrl_data_length !== cfg_length ||
            esp_if.dma_read_ctrl_data_size !== 3'b011 ||
            esp_if.dma_read_ctrl_data_user !== 6'd0)
            $fatal(1, "Descriptor DMA de lectura incorrecto");
        read_index = esp_if.dma_read_ctrl_data_index;
        read_length = esp_if.dma_read_ctrl_data_length;
        @(negedge esp_if.clk);
        esp_if.dma_read_ctrl_ready = 0;
        // La configuracion ya debe estar registrada en el acelerador.
        esp_if.conf_info_reg0 = '1;
        esp_if.conf_info_reg1 = 0;

        for (int i = 0; i < read_length; i++) begin
            repeat (stalls ? i % 3 : 0) @(negedge esp_if.clk);
            esp_if.dma_read_chnl_data = mem[read_index + i];
            esp_if.dma_read_chnl_valid = 1;
            do @(posedge esp_if.clk);
            while (esp_if.dma_read_chnl_ready !== 1'b1);
            @(negedge esp_if.clk);
            esp_if.dma_read_chnl_valid = 0;
        end

        wait (esp_if.dma_write_ctrl_valid === 1'b1);
        repeat (stalls ? 5 : 0) @(negedge esp_if.clk);
        @(negedge esp_if.clk);
        esp_if.dma_write_ctrl_ready = 1;
        @(posedge esp_if.clk);
        if (esp_if.dma_write_ctrl_valid !== 1'b1 ||
            esp_if.dma_write_ctrl_data_index !== cfg_index ||
            esp_if.dma_write_ctrl_data_length !== cfg_length ||
            esp_if.dma_write_ctrl_data_size !== 3'b011 ||
            esp_if.dma_write_ctrl_data_user !== 6'd0)
            $fatal(1, "Descriptor DMA de escritura incorrecto");
        write_index = esp_if.dma_write_ctrl_data_index;
        write_length = esp_if.dma_write_ctrl_data_length;
        @(negedge esp_if.clk);
        esp_if.dma_write_ctrl_ready = 0;

        for (int i = 0; i < write_length; i++) begin
            if (stalls) begin
                // Esperar valid antes de bloquear para ejercitar backpressure.
                wait (esp_if.dma_write_chnl_valid === 1'b1);
                repeat (2 + i % 4) @(negedge esp_if.clk);
            end
            @(negedge esp_if.clk);
            esp_if.dma_write_chnl_ready = 1;
            do @(posedge esp_if.clk);
            while (esp_if.dma_write_chnl_valid !== 1'b1);
            mem[write_index + i] = esp_if.dma_write_chnl_data;
            @(negedge esp_if.clk);
            esp_if.dma_write_chnl_ready = 0;
        end

        // No perder un pulso done inmediatamente despues del ultimo beat.
        if (esp_if.acc_done !== 1'b1)
            $fatal(1, "Falta acc_done tras el ultimo beat");
        if (esp_if.debug[31] !== 1'b0)
            $fatal(1, "Error de configuracion inesperado");
        @(negedge esp_if.clk);
        if (esp_if.acc_done !== 1'b0)
            $fatal(1, "acc_done debe durar un solo ciclo");
    endtask

    task gold_gen(input logic [63:0] source[], input int rows, input int cols,
                  ref logic [63:0] gold[]);
        int src, dst;
        gold = new[rows * cols];
        for (int r = 0; r < rows; r++) begin
            for (int c = 0; c < cols; c++) begin
                src = r * cols + c;
                dst = c * rows + r;
                // Transponer la muestra completa, conservando ambos componentes.
                gold[dst] = source[src];
            end
        end
    endtask

    function bit validate_acc(input logic [63:0] result_acc[],
                              input logic [63:0] gold[], input int length);
        for (int i = 0; i < length; i++) begin
            if (result_acc[i] !== gold[i]) begin
                $display("Beat %0d: esperado=%h obtenido=%h", i, gold[i], result_acc[i]);
                return 1;
            end
        end
        return 0;
    endfunction
endclass
`endif

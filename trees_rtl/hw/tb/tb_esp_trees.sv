`include "agent_acc_esp.sv"
`timescale 1us/1ns

module tb_esp_trees;
    
    const integer t_clk    = 10;    // Clock period 100MHz

    parameter N_TREES          					= 128;  // Number of trees
    parameter N_NODES         					= 256;  // Number of nodes per tree (power of 2)
    parameter N_FEATURE        					= 32;   // Number of features per sample
    parameter N_CLASES        					= 32;   // Number of classes
    parameter MAX_BURST        					= 128;  // Power of 2 and > 8

    parameter N_ITERATIONS = 10; // Number of iterations for the testbench

    parameter N_SAMPLES = 10000;    // Number of samples
    parameter COLUMNAS = 33;        // 32 features + 1 label

    parameter N_64_FEATURES = N_SAMPLES/2*(COLUMNAS-1);

    bit [63:0] trees            [N_TREES*N_NODES-1:0];
    bit [63:0] features_mem_64  [N_64_FEATURES-1:0];
    bit [31:0] labels_mem       [N_SAMPLES-1:0];
    bit [31:0] predictions      [N_SAMPLES-1:0];

    bit error_acc;

    esp_acc_if esp_acc_if_inst();

    agent_esp_acc agent_esp_acc_inst;

    trees_rtl_basic_dma64 #(
	    .N_TREES(N_TREES),
	    .N_NODE_AND_LEAFS(N_NODES),
	    .N_FEATURE(N_FEATURE),
	    .N_CLASES(N_CLASES),
	    .MAX_BURST(MAX_BURST)
    )trees_rtl_basic_dma64_inst(
        .clk(esp_acc_if_inst.clk),
        .rst(esp_acc_if_inst.rst),
        .conf_info_load_trees(esp_acc_if_inst.conf_info_load_trees),
        .conf_info_burst_len(esp_acc_if_inst.conf_info_burst_len),
        .conf_done(esp_acc_if_inst.conf_done),
        .acc_done(esp_acc_if_inst.acc_done),
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

    task automatic read_trees(
        input string nombre_archivo,
        output bit [63:0] datos [N_TREES*N_NODES-1:0]
      );
        integer file, status;
        begin
          file = $fopen(nombre_archivo, "r");
          if (file == 0) begin
            $display("ERROR: No se pudo abrir el archivo: %s", nombre_archivo);
            $finish;
          end
    
          for (int i = 0; i < N_TREES; i++) begin
            for (int j = 0; j < N_NODES; j++) begin
              status = $fscanf(file, "0x%h ", datos[i*N_NODES+j]);
              if (status != 1) begin
                $display("ERROR: Lectura fallida en [%0d][%0d]", i, j);
                $fclose(file);
                $finish;
              end
            end
          end
          $fclose(file);
        end
    endtask

    task read_features(
        input  string nombre_archivo,
        output bit [63:0] features [N_64_FEATURES-1:0],           // 32 columnas
        output bit [31:0] labels   [N_SAMPLES-1:0]              // última columna
    );
        integer file, status;
        shortreal temp_float_l;
        shortreal temp_float_h;
        int temp_int;
        bit [31:0] temp_float_32_l;
        bit [31:0] temp_float_32_h;

        file = $fopen(nombre_archivo, "r");
        if (file == 0) begin
        $display("ERROR: No se pudo abrir el archivo: %s", nombre_archivo);
        $finish;
        end

        for (int i = 0; i < N_SAMPLES; i++) begin
            for (int j = 0; j < (COLUMNAS-1)/2; j++) begin
                status = $fscanf(file, "%f ", temp_float_l); // ← %f + shortreal
                if (status != 1) begin
                    $display("ERROR leyendo feature[%0d][%0d]", i, j);
                    $finish;
                end               
                status = $fscanf(file, "%f ", temp_float_h); // ← %f + shortreal
                if (status != 1) begin
                    $display("ERROR leyendo feature[%0d][%0d]", i, j);
                    $finish;
                end
                temp_float_32_l = $shortrealtobits(temp_float_l); // ← binario exacto
                temp_float_32_h = $shortrealtobits(temp_float_h); // ← binario exacto
                features[i*(COLUMNAS-1)/2 + j] = {temp_float_32_h, temp_float_32_l}; // ← 64 bits
            end
            
            // Leer la etiqueta como entero (si es 0 o 1, por ejemplo)
            status = $fscanf(file, "%d\n", temp_int);
            if (status != 1) begin
                $display("ERROR leyendo label[%0d]", i);
                $finish;
            end
            labels[i] = temp_int;
        end

        $fclose(file);
    endtask

    // Clock generation 
    initial begin
        esp_acc_if_inst.clk = 0;
        forever #(t_clk/2) esp_acc_if_inst.clk = 
                    ~esp_acc_if_inst.clk;
    end

    // Reset generation and initialization
    initial begin
        agent_esp_acc_inst = new(esp_acc_if_inst);
        // Read the trees and features from files
        read_trees("../../../data/model_caracterizacion_frec.dat", trees);
        read_features("../../../data/dataset_caracterizacion_frec_shuffled.dat", features_mem_64, labels_mem);
        esp_acc_if_inst.rst = 0;
        #100 @(posedge esp_acc_if_inst.clk);
        esp_acc_if_inst.rst = 1;
        @(posedge esp_acc_if_inst.clk);
    end

    initial begin
        int data_processed;
        int offset_processed;
        int samples_2_process;
        int load_length;
        @(posedge esp_acc_if_inst.rst);
        agent_esp_acc_inst.gold_gen(
            trees,
            COLUMNAS-1,
            features_mem_64,
            labels_mem
        );

        for (int i=0; i<N_ITERATIONS; ++i) begin
            
            // Load the trees into the RTL module
            agent_esp_acc_inst.load_memory(0, N_TREES*N_NODES, 0, trees);
            agent_esp_acc_inst.run(1, 0);
            data_processed = 0;
            offset_processed = 0;
            while (data_processed < N_SAMPLES) begin
                samples_2_process = $urandom_range(1, MAX_BURST*5);
                if ((data_processed + samples_2_process) >= N_SAMPLES) begin
                    samples_2_process = N_SAMPLES - data_processed;
                end
                $display("Data processed: %0d, Samples to process: %0d", data_processed, samples_2_process);
                // Load the features into the RTL module
                load_length = samples_2_process * (COLUMNAS-1)/2; // 2 features per beat
                agent_esp_acc_inst.load_memory(0, load_length, offset_processed, features_mem_64);
                // Run the RTL module with the features
                agent_esp_acc_inst.run(0, samples_2_process);
                data_processed += samples_2_process;
                offset_processed += load_length;
            end
    
            agent_esp_acc_inst.print_metrics(labels_mem);
            agent_esp_acc_inst.reset(); // Reset the agent for next processing
        end


        $stop;

    end

endmodule

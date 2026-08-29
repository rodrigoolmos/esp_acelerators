interface esp_acc_if;

    logic clk;                              // Main clock signal for the accelerator (provided by ESP socket)
    logic rst;                              // Active-low synchronous reset signal (provided by ESP socket)

    // << User-defined configuration registers >>
    logic [31:0] conf_info_load_trees;      // FLAG: load trees
    logic [31:0] conf_info_burst_len;       // Burst length

    logic conf_done;                        // One-cycle pulse indicating that configuration registers are valid

    logic acc_done;                         // One-cycle pulse from the accelerator indicating completion

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


    ////////////////////////
    /* assertions section */
    ////////////////////////

    property b_changes_only_on_a_rise(logic sigA, logic [31:0] sigB);
        @(posedge clk) disable iff (!rst)
            $changed(sigB) |-> $changed(sigA) || !sigA;
    endproperty


    property p_ctrl_stable_while_wait(valid, ready, idx,len,sz,usr);
    @(posedge clk) disable iff (!rst)
        (valid && !ready) |=> ($stable(idx) && $stable(len) && $stable(sz) && $stable(usr));
    endproperty

    write_ctrl_back_pressure: assert property (p_ctrl_stable_while_wait(
    dma_write_ctrl_valid, dma_write_ctrl_ready,
    dma_write_ctrl_data_index, dma_write_ctrl_data_length,
    dma_write_ctrl_data_size, dma_write_ctrl_data_user))
    else $error("[WRITE CTRL] Error back-pressure");

    read_ctrl_back_pressure: assert property (p_ctrl_stable_while_wait(
    dma_read_ctrl_valid, dma_read_ctrl_ready,
    dma_read_ctrl_data_index, dma_read_ctrl_data_length,
    dma_read_ctrl_data_size, dma_read_ctrl_data_user))
    else $error("[READ CTRL] Error back-pressure");

    // CHECK acc_done pulse
    acc_done_pulse: assert property (@(posedge clk) disable iff (!rst)
        $rose(acc_done) |-> ##1 !acc_done
    ) else $error("acc_done pulse should be one cycle only");

    ////////   WRITE CONTROL ASSERTIONS   ////////
    // CHECK dma_write_ctrl_valid read_ctrl_ready handshake
    write_ctrl_valid_pulse: assert property (@(posedge clk) disable iff (!rst)
        dma_write_ctrl_valid && dma_write_ctrl_ready |-> ##1 !dma_write_ctrl_valid
    ) else $error("dma_write_ctrl_valid should be low one cycle after dma_write_ctrl_valid && dma_write_ctrl_ready");
    // CHECK dma_write_ctrl_data_length stability
    stable_w_length: assert property (b_changes_only_on_a_rise(dma_write_ctrl_valid, dma_write_ctrl_data_length)) 
        else $error("dma_write_ctrl_data_length shouldn't change when dma_write_ctrl_valid is high");
    // CHECK dma_write_ctrl_data_index stability
    stable_w_index: assert property (b_changes_only_on_a_rise(dma_write_ctrl_valid, dma_write_ctrl_data_index)) 
        else $error("dma_write_ctrl_data_index shouldn't change when dma_write_ctrl_valid is high");
    // CHECK dma_write_ctrl_data_size stability
    stable_w_size: assert property (b_changes_only_on_a_rise(dma_write_ctrl_valid, dma_write_ctrl_data_size)) 
        else $error("dma_write_ctrl_data_size shouldn't change when dma_write_ctrl_valid is high");
    // CHECK dma_write_ctrl_data_user stability
    stable_w_user: assert property (b_changes_only_on_a_rise(dma_write_ctrl_valid, dma_write_ctrl_data_user)) 
        else $error("dma_write_ctrl_data_user shouldn't change when dma_write_ctrl_valid is high");

    ////////   READ CONTROL ASSERTIONS   ////////
    // CHECK read_ctrl_valid read_ctrl_ready handshake
    read_ctrl_valid_pulse: assert property (@(posedge clk) disable iff (!rst)
        dma_read_ctrl_valid && dma_read_ctrl_ready |-> ##1 !dma_read_ctrl_valid
    ) else $error("dma_read_ctrl_valid should be low one cycle after dma_read_ctrl_valid && dma_read_ctrl_ready");
    // CHECK dma_read_ctrl_data_length stability
    stable_r_length: assert property (b_changes_only_on_a_rise(dma_read_ctrl_valid, dma_read_ctrl_data_length)) 
        else $error("dma_read_ctrl_data_length shouldn't change when dma_read_ctrl_valid is high");
    // CHECK dma_read_ctrl_data_index stability
    stable_r_index: assert property (b_changes_only_on_a_rise(dma_read_ctrl_valid, dma_read_ctrl_data_index)) 
        else $error("dma_read_ctrl_data_index shouldn't change when dma_read_ctrl_valid is high");
    // CHECK dma_read_ctrl_data_size stability
    stable_r_size: assert property (b_changes_only_on_a_rise(dma_read_ctrl_valid, dma_read_ctrl_data_size)) 
        else $error("dma_read_ctrl_data_size shouldn't change when dma_read_ctrl_valid is high");
    // CHECK dma_read_ctrl_data_user stability
    stable_r_user: assert property (b_changes_only_on_a_rise(dma_read_ctrl_valid, dma_read_ctrl_data_user)) 
        else $error("dma_read_ctrl_data_user shouldn't change when dma_read_ctrl_valid is high");

    ////////   WRITE ASSERTIONS   ////////
    // Normal write transaction
    initial begin
        int remaining;
        forever begin
            @(posedge clk iff dma_write_ctrl_ready && dma_write_ctrl_valid);
            remaining = dma_write_ctrl_data_length;
            @(posedge clk);
            if (remaining == 0) begin
                $error("dma_write_ctrl_data_length should be greater than 0");
            end

            fork
            begin : data_beats
                for (int i = 0; i < remaining; i++) begin
                @(posedge clk iff dma_write_chnl_ready && dma_write_chnl_valid);
                end
                remaining = 0;
            end

            begin : guard_new_start
                @(posedge clk iff dma_write_ctrl_ready && dma_write_ctrl_valid);
                #0;
                if (remaining > 0) begin
                $error("New ctrl before finishing previous transaction data");
                end
            end
            join_any
            disable fork;
        end
    end
    // back-pressure WRITE
    back_pressure_write: assert property (@(posedge clk)disable iff (!rst)
        (dma_write_chnl_valid && !dma_write_chnl_ready) |=> 
            (dma_write_chnl_valid && $stable(dma_write_chnl_data))
    ) else $error("back-pressure WRITE not been handled correctly");

    // CHECK data/valid stability under back-pressure
    back_pressure_read: assert property (@(posedge clk) disable iff(!rst)
        (dma_read_chnl_valid && !dma_read_chnl_ready) |=> 
            (dma_read_chnl_valid && $stable(dma_read_chnl_data)))
    else $error("back-pressure READ not been handled correctly");

    ////////   READ ASSERTIONS   ////////
    initial begin
        int remaining;
        forever begin
            @(posedge clk iff dma_read_ctrl_ready && dma_read_ctrl_valid);
            remaining = dma_read_ctrl_data_length;
            @(posedge clk);
            if (remaining == 0) begin
                $error("dma_read_ctrl_data_length should be greater than 0");
            end

            fork
            begin : data_beats
                for (int i = 0; i < remaining; i++) begin
                @(posedge clk iff dma_read_chnl_ready && dma_read_chnl_valid);
                end
                remaining = 0;
            end

            begin : guard_new_start
                @(posedge clk iff dma_read_ctrl_ready && dma_read_ctrl_valid);
                #0;
                if (remaining > 0) begin
                $error("New ctrl before finishing previous transaction data");
                end
            end
            join_any
            disable fork;
        end
    end

    ////////   conf_done -> acc_done   ////////
    initial begin
        typedef enum logic { w_conf_done, w_acc_done } t_state;
	    t_state state;
        state = w_conf_done;
        forever begin
            @(posedge clk);
            case (state)
                w_conf_done: begin
                    if (conf_done)
                        state = w_acc_done;
                    else if (acc_done)
                        $error("acc_done should not be high before conf_done");

                end
                w_acc_done: begin
                    if (acc_done)
                        state = w_conf_done;
                    else if (conf_done)
                        $error("conf_done should not be high before acc_done");

                end
            endcase
        end
    end
    // CHECK conf_done -> acc_done
    cover property (@(posedge clk) disable iff (rst == 1'b0)
        conf_done |-> ##[1:$] acc_done
    );

    function automatic bit size_ok(input [2:0] s);
    return (s==3'b000) || (s==3'b001) || (s==3'b010) || (s==3'b011);
    endfunction

    write_ctrl_size: assert property (@(posedge clk) disable iff(!rst)
    (dma_write_ctrl_valid && dma_write_ctrl_ready) |-> size_ok(dma_write_ctrl_data_size))
    else $error("[WRITE CTRL] size out of codification");

    read_ctrl_size: assert property (@(posedge clk) disable iff(!rst)
    (dma_read_ctrl_valid && dma_read_ctrl_ready) |-> size_ok(dma_read_ctrl_data_size))
    else $error("[READ CTRL] size out of codification");

    ctrl_write_X_Z: assert property (@(posedge clk) disable iff(!rst)
    dma_write_ctrl_valid |-> !$isunknown({dma_write_ctrl_data_index,
                                            dma_write_ctrl_data_length,
                                            dma_write_ctrl_data_size,
                                            dma_write_ctrl_data_user}))
    else $error("[WRITE CTRL] X/Z in camps VALID=1");

    ctrl_read_X_Z: assert property (@(posedge clk) disable iff(!rst)
    dma_read_ctrl_valid |-> !$isunknown({dma_read_ctrl_data_index,
                                        dma_read_ctrl_data_length,
                                        dma_read_ctrl_data_size,
                                        dma_read_ctrl_data_user}))
    else $error("[READ CTRL] X/Z in camps VALID=1");


    data_write_X_Z: assert property (@(posedge clk) disable iff(!rst)
        dma_write_chnl_valid |-> !$isunknown(dma_write_chnl_data))
    else $error("[WRITE DATA] X/Z with VALID=1");

    data_read_X_Z: assert property (@(posedge clk) disable iff(!rst)
        dma_read_chnl_valid |-> !$isunknown(dma_read_chnl_data))
    else $error("[READ DATA] X/Z with VALID=1");


endinterface


class agent_esp_acc;

    parameter N_NODES = 256;        // Number of nodes in each tree
    parameter N_TREES = 128;        // Number of trees in the forest

    parameter N_SAMPLES = 10000;    // Number of samples
    parameter COLUMNAS = 33;        // 32 features + 1 label

    // Virtual interface to the DUT (ESP accelerator)
    virtual esp_acc_if esp_if;

    // Local storage for read and write parameters
    int unsigned read_index;
    int unsigned read_length;
    int unsigned write_index;
    int unsigned write_length;

    // Local storage for predictions
    bit [7:0] predictions_sw[N_SAMPLES-1:0];
    bit [7:0] predictions_hw[2*N_SAMPLES-1:0];
    int predictions_count = 0;
    int mismatches_count = 0;

    // Simulated memory array accessed by the DMA
    bit [63:0] mem[*];

    int unsigned burst_len_1;

    // Constructor: bind the interface and reset relevant signals
    function new(virtual esp_acc_if esp_if);
        this.esp_if = esp_if;
        esp_if.conf_done             = 0;
        esp_if.dma_read_ctrl_ready   = 0;
        esp_if.dma_read_chnl_valid   = 0;
        esp_if.dma_write_ctrl_ready  = 0;
        esp_if.dma_write_chnl_ready  = 0;
    endfunction

    // Load a contiguous block of 64-bit data into simulated memory
    task load_memory(
        input int unsigned base,
        input int unsigned n_elements,
        input int unsigned offset,
        input bit [63:0] data[]
    );
        int start_idx = data.size() - offset - 1;

        for (int i = 0; i < n_elements; i++) begin
            int idx = start_idx - i;
            mem[base + i] = data[idx];
        end
    endtask

    local task read_predictions(int n_predictions, bit check_mismatches = 1);
        int i, j;
        for (i = 0; i < n_predictions/8; i++) begin
            for (j=0; j<8; ++j) begin
                predictions_hw[predictions_count++] = mem[i][8*j+: 8];
                $display("Prediction %0d: %0h", predictions_count, predictions_hw[predictions_count-1]);
                if (predictions_hw[predictions_count-1] != predictions_sw[predictions_count-1] && check_mismatches) begin
                    mismatches_count++;
                    $display("Mismatch at prediction %0d: expected %0h, got %0h", 
                             predictions_count-1, predictions_sw[predictions_count-1], 
                             predictions_hw[predictions_count-1]);
                    $stop;
                end
            end
        end
        for (j=0; j<n_predictions%8; ++j) begin
            predictions_hw[predictions_count++] = mem[i][8*j+: 8];
            $display("Prediction %0d: %0h", predictions_count, predictions_hw[predictions_count-1]);
            if (predictions_hw[predictions_count-1] != predictions_sw[predictions_count-1] && check_mismatches) begin
                mismatches_count++;
                $display("Mismatch at prediction %0d: expected %0h, got %0h", 
                         predictions_count-1, predictions_sw[predictions_count-1], 
                         predictions_hw[predictions_count-1]);
                $stop;
            end
        end
    endtask

    local task wait_acc_done ();
        // WAIT for accelerator to assert acc_done
        wait (esp_if.acc_done == 1);
        @(posedge esp_if.clk);
    endtask

    local task automatic back_pressure(ref logic signal);
        signal = 0;
        repeat($urandom_range(0,3)) @(posedge esp_if.clk);
    endtask


    local task dma_read();
            // READ CONTROL: handshake
            back_pressure(esp_if.dma_read_ctrl_ready);
            esp_if.dma_read_ctrl_ready = 1;
            wait (esp_if.dma_read_ctrl_valid && esp_if.dma_read_ctrl_ready);
            @(posedge esp_if.clk);
            read_index  = esp_if.dma_read_ctrl_data_index;
            read_length = esp_if.dma_read_ctrl_data_length;
            esp_if.dma_read_ctrl_ready = 0;

            assert (read_length != 0) else begin
                $display("Error: read_length can not be 0");
                $stop;
            end

            // READ CHANNEL: supply data beats
            esp_if.dma_read_chnl_valid = 1;
            for (int i = 0; i < read_length; ) begin
                esp_if.dma_read_chnl_data = mem[read_index + i];
                i++;
                @(posedge esp_if.clk iff esp_if.dma_read_chnl_ready && esp_if.dma_read_chnl_valid);
                back_pressure(esp_if.dma_read_chnl_valid);
                esp_if.dma_read_chnl_valid = 1;
            end
            esp_if.dma_read_chnl_valid = 0;
            @(posedge esp_if.clk);
    endtask

    local task dma_write();

        bit [31:0] clk_stamp1, clk_stamp2; 

        // WRITE CONTROL: handshake
        back_pressure(esp_if.dma_write_ctrl_ready);
        esp_if.dma_write_ctrl_ready = 1;
        wait (esp_if.dma_write_ctrl_valid && esp_if.dma_write_ctrl_ready);
        @(posedge esp_if.clk);
        write_index  = esp_if.dma_write_ctrl_data_index;
        write_length = esp_if.dma_write_ctrl_data_length;
        esp_if.dma_write_ctrl_ready = 0;

        assert (write_length != 0) else begin
            $display("Error: write_length can not be 0");
            $stop;
        end 

        // WRITE CHANNEL: capture returned data
        back_pressure(esp_if.dma_write_chnl_ready);
        esp_if.dma_write_chnl_ready = 1;
        for (int i = 0; i < write_length; ) begin
            if (i<write_length-1) begin
                @(posedge esp_if.clk iff esp_if.dma_write_chnl_ready && esp_if.dma_write_chnl_valid);
                mem[write_index + i] = esp_if.dma_write_chnl_data;
		        $display("Writing to memory address %0h Data %0h", 
                            esp_if.dma_write_chnl_data, write_index + i);
            end else begin
                // Last beat contains clock stamps
                @(posedge esp_if.clk iff esp_if.dma_write_chnl_ready && esp_if.dma_write_chnl_valid);
                {clk_stamp1, clk_stamp2} = esp_if.dma_write_chnl_data;
                $display("Clock stamps: send %0d, process %0d clk cicles", clk_stamp1, clk_stamp2);
            end
            i++;
            back_pressure(esp_if.dma_write_chnl_ready);
            esp_if.dma_write_chnl_ready = 1;
        end

        esp_if.dma_write_chnl_ready = 0;
        @(posedge esp_if.clk);
    endtask

    local task config_acc(input int unsigned load_trees,
                            input int unsigned burst_len);

        // CONFIG PHASE: apply registers
        esp_if.conf_info_load_trees = load_trees;
        esp_if.conf_info_burst_len = burst_len;
        @(posedge esp_if.clk);
        esp_if.conf_done      = 1;
        @(posedge esp_if.clk);
        esp_if.conf_done      = 0;
    endtask

    // Reset agent
    task reset();
        predictions_count = 0;
        mismatches_count = 0;
    endtask

    // Extract a block of data from simulated memory
    task automatic collect_memory(input int unsigned base, input int unsigned length, ref bit [63:0] data[]);
        data = new[length];
        for (int i = 0; i < length; i++) begin
            data[i] = mem[base + i];
        end
    endtask

    function void print_metrics(input bit [31:0] labels[N_SAMPLES-1:0]);
        int correct = 0;
        // Imprime los resultados
        for (int p = 0; p < 10000; ++p) begin
            if (labels[p] == predictions_hw[p]) begin
                correct++;
            end
        end

        $display("Correct predictions hw: %0d of %0d", correct, 10000);
        $display("Accuracy: %f", (correct / 10000.0));
        $display("Mismatches hw, sw: %0d", mismatches_count);
    endfunction

    // Drive the full accelerator transaction emulating
    // the ESP interface and handling DMA read/write operations
    // emulation of the SW stack when using the accelerator
    task run(input int unsigned load_trees,
             input int unsigned burst_len);

        logic dma_active = 1;
        if (burst_len) burst_len_1 = burst_len;

        config_acc(load_trees, burst_len);

        dma_block: fork
            while (dma_active) begin
                if (burst_len || load_trees) dma_read();
            end

            while (dma_active) begin
                dma_write();
            end
        join_none

        wait_acc_done();
        dma_active = 0;
        disable dma_block;

        // Read predictions from "memory"
        if (!load_trees)
            read_predictions(burst_len_1, (burst_len) ? 1 : 0);

    endtask

    // Generate a gold standard for the expected output
    task automatic gold_gen(input bit[63:0] trees [N_NODES*N_TREES-1:0], 
                            input integer n_features, 
                            input bit [63:0] features[N_SAMPLES/2*(COLUMNAS-1)-1:0], 
                            input bit [31:0] labels[N_SAMPLES-1:0]);

        logic[31:0] sum = 0;
        logic[31:0] leaf_value;
        logic[31:0] counts[32];
        logic[7:0]  node_index;
        logic[7:0]  node_right;
        logic[7:0]  node_left;
        logic[7:0]  feature_index;
        logic[31:0] threshold;
        logic[63:0] node;
        logic[31:0] best;
        logic[31:0] best_count;
        logic[31:0] feature_h;
        logic[31:0] feature_l;

        integer correct = 0;

        for (int p=0; p<10000; ++p) begin
            for (int c=0; c<32; ++c)
                counts[c] = 0;

            for (int t = 0; t < N_TREES; t++) begin
                node_index = 0;
    
                while(1) begin
                    node = trees[t*N_NODES+node_index];
                    feature_index = node[15:8];
                    threshold = node[63:32];
                    node_left = node_index + 1;
                    node_right = node[23:16];
                    
                    {feature_h, feature_l} = features[p*n_features/2+feature_index/2];
                    
                    if (feature_index%2) begin
                        node_index = feature_h < threshold ? 
                                                node_left : node_right;
                    end else begin
                        node_index = feature_l < threshold ? 
                                                node_left : node_right;
                    end
    
                    if (!(node[0]))
                        break;
                end
    
                leaf_value = node[63:32];
                if (leaf_value >= 0 && leaf_value < 32)
                    counts[leaf_value]++;
    
            end
    
            // Busca la clase ganadora
            best      = 0;
            best_count = counts[0];
            for (int c = 1; c < 32; c++) begin
                
                if (counts[c] > best_count) begin
                    best_count = counts[c];
                    best       = c;
                end
            end
    
            predictions_sw[p] = best;
            $display("Prediction %0d: %0h", p, predictions_sw[p]);
        end

        // Imprime los resultados
        for (int p = 0; p < 10000; ++p) begin
            if (labels[p] == predictions_sw[p]) begin
                correct++;
            end
        end

        $display("Correct predictions: %0d de %0d", correct, 10000);
        $display("Accuracy: %f", (correct / 10000.0));

    endtask

endclass

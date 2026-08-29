`timescale 1us/1ns
    
interface esp_acc_if;

    logic clk;                              // Main clock signal for the accelerator (provided by ESP socket)
    logic rst;                              // Active-low synchronous reset signal (provided by ESP socket)
    
    // << User-defined configuration registers >>
    logic [31:0] conf_info_reg0;            // Configuration register 0 (typically used as read data index)
    logic [31:0] conf_info_reg1;            // Configuration register 1 (typically used as read data length / number of FFTs)
    logic [31:0] conf_info_reg2;            // Configuration register 2 (base memory index for results)
    logic [31:0] conf_window;               // Windowing config: bit0 = enable, bit1 = load coefficients
    logic [31:0] conf_ifft;                 // Transform direction: bit0 = 1 -> inverse FFT

    logic conf_done;                        // One-cycle pulse indicating that configuration registers are valid

    logic acc_done;                         // One-cycle pulse from the accelerator indicating completion
    logic [31:0] debug;                     // Optional debug output (e.g., error codes, FSM state)

    // DMA Read Control - signals for initiating a DMA read transaction
    logic dma_read_ctrl_ready;              // From socket: high when ready to accept a new read request
    logic dma_read_ctrl_valid;              // From accelerator: high when issuing a read request
    logic [31:0] dma_read_ctrl_data_index;  // Offset (in beats) from the base of the virtual memory region
    logic [31:0] dma_read_ctrl_data_length; // Number of beats to read
    logic [2:0] dma_read_ctrl_data_size;    // Beat size encoding (e.g., 011 = 64-bit)
    logic [5:0] dma_read_ctrl_data_user;    // User-defined field to select source (e.g., memory, P2P, multicast)

    // DMA Read Channel - signals for receiving data from memory
    logic dma_read_chnl_ready;              // From accelerator: high when ready to receive data
    logic dma_read_chnl_valid=1'b0;         // From socket: high when data is available
    logic [63:0] dma_read_chnl_data='0;     // Data beat received from memory (typically 64-bit)

    // DMA Write Control - signals for initiating a DMA write transaction
    logic dma_write_ctrl_ready;             // From socket: high when ready to accept a new write request
    logic dma_write_ctrl_valid;             // From accelerator: high when issuing a write request
    logic [31:0] dma_write_ctrl_data_index; // Offset (in beats) from the base of the virtual memory region
    logic [31:0] dma_write_ctrl_data_length;// Number of beats to write
    logic [2:0] dma_write_ctrl_data_size;   // Beat size encoding (e.g., 011 = 64-bit)
    logic [5:0] dma_write_ctrl_data_user;   // User-defined field to select target (e.g., memory, P2P, multicast)

    // DMA Write Channel - signals for sending data to memory
    logic dma_write_chnl_ready;             // From socket: high when ready to receive write data
    logic dma_write_chnl_valid;             // From accelerator: high when write data is valid
    logic [63:0] dma_write_chnl_data;       // Data beat sent to memory (typically 64-bit)

endinterface

class agent_esp_acc
    #(
    logic FLOAT_POINT=1'b1,
    int N_FFT,
    int FFT_SIZE,
    int DATA_NB_BITS = 64
    );


    virtual esp_acc_if esp_if;

    // Local storage for read and write parameters
    int unsigned read_index;
    int unsigned read_length;
    int unsigned write_index;
    int unsigned write_length;

    // Simulated memory array
    bit [DATA_NB_BITS-1:0] mem[*];
    
    // Constructor: bind the interface and reset relevant signals
    function new(virtual esp_acc_if esp_if);
        this.esp_if = esp_if;
        esp_if.conf_done             = 0;
        esp_if.conf_window           = 0;
        esp_if.conf_ifft             = 0;
        esp_if.conf_info_reg2        = 0;
        esp_if.dma_read_ctrl_ready   = 0;
        esp_if.dma_read_chnl_valid   = 0;
        esp_if.dma_write_ctrl_ready  = 0;
        esp_if.dma_write_chnl_ready  = 0;
    endfunction
    
    // Convert a real value to fixed step value (Q16.16 - logic [31:0])
    function automatic logic [DATA_NB_BITS/2-1:0] to_fixed(real value);
        return int'(value * 65536.0);//2**16 = 65536.0
    endfunction
    
    // Convert a binary value (Q16.16) to real value
    function automatic real to_real(logic [DATA_NB_BITS/2-1:0] value);
        int signed_int;
        signed_int = $signed(value);
        return real'(signed_int) / 65536.0;//2**16 = 65536.0
    endfunction
    
    // Exports inputs as hexa
    function automatic export_inputs_to_file(input string filename, input bit [DATA_NB_BITS-1:0] data[], input int unsigned length);
        int fd;
        fd = $fopen(filename, "w");
        if (fd == 0) $fatal(1, "Couldn't open the inputts file inputs.txt");
        for (int i=0; i<length; i++) begin
            $fwrite(fd, "%016h\n", data[i]);
        end
        $fclose(fd);
        $display("[TB] Inputs exported in %s", filename);
    endfunction
    
    // Exports outputs as hexa
    task export_outputs_to_file(input string filename, input int unsigned base, input int unsigned length);
        int fd;
        fd = $fopen(filename, "w");
        if (fd == 0) $fatal(1, "Couldn't create the results file for MATLAB");
        
        for (int i = 0; i < length; i++) begin
            $fwrite(fd, "%016h\n", mem[base + i]); 
        end
        $fclose(fd);
        $display("[Agent] Results exported in %s to be verified with MATLAB.", filename);
    endtask
    
    // Export data as float, useful to easily verify i-FFT
    function automatic data_numbers_to_file(input string filename, input bit [DATA_NB_BITS-1:0] data[], input int unsigned length);
        int fd;
        fd = $fopen(filename, "w");
        if (fd == 0) $fatal(1, "Couldn't open the inputts file inputs.txt");
        for (int i=0; i<length; i++) begin
            if (FLOAT_POINT)
                $fwrite(fd, "%f + j* %f\n", $bitstoshortreal(data[i][DATA_NB_BITS-1: DATA_NB_BITS/2]), $bitstoshortreal(data[i][DATA_NB_BITS/2-1: 0]) );
            else
                $fwrite(fd, "%f + j* %f\n", to_real(data[i][DATA_NB_BITS-1: DATA_NB_BITS/2]), to_real(data[i][DATA_NB_BITS/2-1: 0]) );       
        end
        $fclose(fd);
        $display("[TB] Inputs exported in %s", filename);
    endfunction 
    
    // Export data to an open file descriptor, without closing it
    function automatic dump_beats_to_fd(input int fd, input bit [DATA_NB_BITS-1:0] data[], input int unsigned length);
        if (fd == 0) $fatal(1, "Invalid file descriptor (0) passed to dump_beats_to_fd");
        for (int i=0; i<length; i++) begin
            $fwrite(fd, "%016h\n", data[i]);
        end
    endfunction
    
    //  Generate random inputs for nf FFTs
    task automatic gen_random_inputs(input int nf,
                                    ref bit [DATA_NB_BITS-1:0] data[][]);
        real PI = 3.14159265359;
        real f1, f2, a1, a2, sre, sim;
        int  ti;
        data = new[nf];
        for (int fr = 0; fr < nf; fr++) begin
            data[fr] = new[FFT_SIZE];
            // Frequences less than then FFT_SIZE/2 (Shannon-Nyquist's theoreme).
            f1 = $urandom_range(0, FFT_SIZE/2) / 10.0;
            f2 = $urandom_range(0, FFT_SIZE/2) / 10.0;
            a1 = $urandom_range(0, 100);
            a2 = $urandom_range(0, 100);
            for (int i = 0; i < FFT_SIZE; i++) begin
                ti  = fr*FFT_SIZE + i;
                sre = a1*$cos(2*PI*f1*real'(ti)/real'(FFT_SIZE))
                    + a2*$cos(2*PI*f2*real'(ti)/real'(FFT_SIZE));
                sim = a1*$sin(2*PI*f1*real'(ti)/real'(FFT_SIZE))
                    + a2*$sin(2*PI*f2*real'(ti)/real'(FFT_SIZE));
                if (FLOAT_POINT) begin
                    data[fr][i][DATA_NB_BITS-1:DATA_NB_BITS/2] = $shortrealtobits(shortreal'(sre));
                    data[fr][i][DATA_NB_BITS/2-1:0]           = $shortrealtobits(shortreal'(sim));
                end else begin
                    data[fr][i][DATA_NB_BITS-1:DATA_NB_BITS/2] = to_fixed(sre);
                    data[fr][i][DATA_NB_BITS/2-1:0]            = to_fixed(sim);
                end
            end
        end
    endtask
    
    // Convert a 2D buffer to 1D
    task automatic twod_to_oned(input bit [DATA_NB_BITS-1:0] src[][], input int nf, ref bit [DATA_NB_BITS-1:0] dst[]);
        dst = new[nf*FFT_SIZE];
        for (int j = 0; j < nf; j++)
            for (int i = 0; i < FFT_SIZE; i++)
                dst[j*FFT_SIZE + i] = src[j][i];
    endtask
    
    // Convert a 1D buffer to 2D
    task automatic oned_to_twod(input bit [DATA_NB_BITS-1:0] src[], input int nf, ref bit [DATA_NB_BITS-1:0] dst[][]);
        dst = new[nf];
        for (int j = 0; j < nf; j++) begin
            dst[j] = new[FFT_SIZE];
            for (int i = 0; i < FFT_SIZE; i++)
                dst[j][i] = src[j*FFT_SIZE + i];
        end
    endtask

    // Load data form 1D buffer into simulated memory
    task load_memory(input int unsigned base, input int unsigned offset, input int unsigned length, input bit [DATA_NB_BITS-1:0] data[]);
        for (int i = 0; i < length; i++) begin
            mem[base + i] = data[offset + i];
            //$display("[Agent Mem] Loading Data %0h at index %0d", $signed(data[i]), base + i);
        end
    endtask

    // Load FFT_SIZE window coefficients into simulated memory
    task load_window(input int unsigned base, input int unsigned length, input bit [DATA_NB_BITS/2-1:0] coef [FFT_SIZE]);
        for (int i = 0; i < length; i++) begin
            mem[base + i] = {coef[i], {(DATA_NB_BITS/2){1'b0}}};
            //$display("[Agent Mem] Loading window coef %0h at index %0d", $signed(coef[i]), base + i);
        end
    endtask

    // Extract a block of data from simulated memory
    task automatic collect_memory(input int unsigned base, input int unsigned length, ref bit [DATA_NB_BITS-1:0] data[]);
        data = new[length];
        for (int i = 0; i < length; i++) begin
            data[i] = mem[base + i];
            //$display("[Agent Mem] Collecting Data %0h from index %0d", $signed(data[i]), base + i);
        end
    endtask


    // Window-load request: configure the window (load=1), stream the
    // FFT_SIZE coefficients and wait for acc_done
    // No FFT is computed and nothing is written back.
    task configure_window(input int unsigned cfg_index);
        // CONFIGURATION: enable=1, load=1, burst_len irrelevant (0).
        esp_if.conf_info_reg0 = cfg_index;
        esp_if.conf_info_reg1 = 0;
        esp_if.conf_window    = {30'b0, 1'b1, 1'b1}; // load=1, enable=1
        esp_if.conf_ifft      = 0;                   // irrelevant for a load request
        @(posedge esp_if.clk);
        esp_if.conf_done = 1;
        @(posedge esp_if.clk);
        esp_if.conf_done = 0;

        $display("[Agent WINDOW] Loading %0d coefficients into the window RAM.", FFT_SIZE);

        // READ only: serve FFT_SIZE coefficient beats from memory.
        esp_if.dma_read_ctrl_ready = 1;
        wait (esp_if.dma_read_ctrl_valid && esp_if.dma_read_ctrl_ready);
        @(posedge esp_if.clk);
        read_index  = esp_if.dma_read_ctrl_data_index;
        read_length = esp_if.dma_read_ctrl_data_length; // == FFT_SIZE
        esp_if.dma_read_ctrl_ready = 0;

        esp_if.dma_read_chnl_valid = 1;
        for (int i = 0; i < read_length; ) begin
            esp_if.dma_read_chnl_data = mem[read_index + i];
            @(posedge esp_if.clk);
            if (esp_if.dma_read_chnl_ready && esp_if.dma_read_chnl_valid) i++;
        end
        esp_if.dma_read_chnl_valid = 0;

        wait (esp_if.acc_done == 1);
        $display("[Agent WINDOW] Window stored (acc_done received).");
        @(posedge esp_if.clk);
        esp_if.conf_window = 0;
    endtask

    // Compute request: send cfg_ffts frames of samples (load=0). The window
    // must have been loaded earlier with configure_window if win_enable=1.
    task run(input int unsigned cfg_index, input int unsigned cfg_ffts,
             input bit win_enable = 1'b0, input int unsigned cfg_out_index = 0,
             input bit ifft_mode = 1'b0);
        int unsigned total_ffts = cfg_ffts; 
        int unsigned ffts_read = 0;
        int unsigned ffts_written = 0;

        // CONFIGURATION
        esp_if.conf_info_reg0 = cfg_index;
        esp_if.conf_info_reg1 = cfg_ffts;
        esp_if.conf_info_reg2 = cfg_out_index;
        esp_if.conf_window    = {31'b0, win_enable}; // load=0 (compute only), bit0=enable
        esp_if.conf_ifft      = {31'b0, ifft_mode};  // bit0=1 -> inverse FFT
        @(posedge esp_if.clk);
        esp_if.conf_done = 1;
        @(posedge esp_if.clk);
        esp_if.conf_done = 0;

        if (win_enable)
            $display("[Agent-DEBUG] Windowing enabled (reusing coefficients already loaded).");

        $display("[Agent-DEBUG] Configuration done. Start sending/reading %0d FFTs.", total_ffts);

        // EMPTY REQUEST (cfg_ffts == 0): the RTL issues no DMA read and no DMA
        // write, it simply pulses acc_done.
        if (total_ffts == 0) begin
            $display("[Agent-DEBUG] Empty request (0 FFT): waiting for acc_done only.");
            wait (esp_if.acc_done == 1);
            @(posedge esp_if.clk);
            esp_if.conf_done = 0;
            return;
        end

        // Fork to read, write and monitor acc_done simultaneously
        fork
            // READ
            begin
                esp_if.dma_read_ctrl_ready = 1;
                wait (esp_if.dma_read_ctrl_valid && esp_if.dma_read_ctrl_ready);
                @(posedge esp_if.clk);
                read_index  = esp_if.dma_read_ctrl_data_index;
                read_length = esp_if.dma_read_ctrl_data_length; // Equals to total_ffts * FFT_SIZE
                esp_if.dma_read_ctrl_ready = 0;

                $display("[Agent READ] RTL requested a single burst of %0d beats for all FFTs.", read_length);

                esp_if.dma_read_chnl_valid = 1;
                for (int i = 0; i < read_length; ) begin
                    esp_if.dma_read_chnl_data = mem[read_index + i];
                    @(posedge esp_if.clk);
                    if (esp_if.dma_read_chnl_ready && esp_if.dma_read_chnl_valid) i++;
                end
                esp_if.dma_read_chnl_valid = 0;
                ffts_read = total_ffts; // All FFTs are sent in one request
                @(posedge esp_if.clk);
                $display("[Agent READ] All the FFTs are sent/read.");
            end

            // WRITE
            begin
                while (ffts_written < total_ffts) begin
                    esp_if.dma_write_ctrl_ready = 1;
                    wait (esp_if.dma_write_ctrl_valid && esp_if.dma_write_ctrl_ready);
                    @(posedge esp_if.clk);
                    write_index  = esp_if.dma_write_ctrl_data_index;
                    write_length = esp_if.dma_write_ctrl_data_length;
                    esp_if.dma_write_ctrl_ready = 0;

                    esp_if.dma_write_chnl_ready = 1;
                    for (int i = 0; i < write_length; ) begin
                        @(posedge esp_if.clk);
                        if (esp_if.dma_write_chnl_ready && esp_if.dma_write_chnl_valid) begin
                            mem[write_index + i] = esp_if.dma_write_chnl_data;
                            i++;
                        end
                    end
                    esp_if.dma_write_chnl_ready = 0;
                    ffts_written++;
                    @(posedge esp_if.clk);
                end
                $display("[Agent WRITE] All the FFTs are received/wrote.");
            end

        join
        
        wait (esp_if.acc_done == 1);

        @(posedge esp_if.clk);
        esp_if.conf_done = 0;
    endtask
        
    task automatic run_with_reset_via_disable(input int nf, input int reset_at_cycle, input bit win_enable = 1'b0);

        $display("[TB][t=%0t] --- Test RESET WHILE COMPUTING : %0d FFT(s), reset at cycle %0d ---",
                 $time, nf, reset_at_cycle);

        fork
            // --- Process A : run() as it should be ---
            begin : run_branch
                run(0, nf, win_enable, 0);
            end

            // --- Process B : apply RESET and then kill process A ---
            begin : reset_branch
                repeat (reset_at_cycle) @(posedge esp_if.clk);
                esp_if.rst = 0;             
                $display("[TB][t=%0t] RESET APPLIED WHILE COMPUTING (rst=0).", $time);
                disable run_branch;
                repeat (4) @(posedge esp_if.clk);
                esp_if.rst = 1;
                $display("[TB][t=%0t] Reset deactivated (rst=1).", $time);
            end
        join
        // Need to reset all signals after RESET
        esp_if.conf_done            = 0;
        esp_if.dma_read_ctrl_ready  = 0;
        esp_if.dma_read_chnl_valid  = 0;
        esp_if.dma_write_ctrl_ready = 0;
        esp_if.dma_write_chnl_ready = 0;
        @(posedge esp_if.clk);
    endtask

    // Validation for a burst of any size
    // Compares result[nf][FFT_SIZE] against gold[nf][FFT_SIZE]
    // with some tolerence (+-delta).
    function bit validate_acc_with_error(input int nf,
                                input bit [DATA_NB_BITS-1:0] result_acc[][],
                                input bit [DATA_NB_BITS-1:0] gold[][], input real delta);
        for (int j = 0; j < nf; j++) begin
            for (int i = 0; i < FFT_SIZE; i++) begin
                real gr, gi, rr, ri;
                if (FLOAT_POINT) begin
                    gr = $bitstoshortreal(gold[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                    gi = $bitstoshortreal(gold[j][i][DATA_NB_BITS/2-1:0]);
                    rr = $bitstoshortreal(result_acc[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                    ri = $bitstoshortreal(result_acc[j][i][DATA_NB_BITS/2-1:0]);
                    if ((((rr-gr) > delta) || ((gr-rr) > delta)) || (((ri-gi) > delta) || ((gi-ri) > delta))) begin
                        $display("[Mismatch] FFT %0d index %0d: Expected (%f,%f), Got (%f,%f)",
                         j, i, gr, gi, rr, ri);
                        return 1;
                    end
                end else begin
                    gr = to_real(gold[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                    gi = to_real(gold[j][i][DATA_NB_BITS/2-1:0]);
                    rr = to_real(result_acc[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                    ri = to_real(result_acc[j][i][DATA_NB_BITS/2-1:0]);
                    if ((((rr-gr) > delta) || ((gr-rr) > delta)) || (((ri-gi) > delta) || ((gi-ri) > delta))) begin
                        $display("[Mismatch] FFT %0d index %0d: Expected (%f,%f), Got (%f,%f)",
                         j, i, gr, gi, rr, ri);
                        return 1;
                    end                        
                end
               
            end
        end
        return 0;
    endfunction

    // Validation for a burst of any size
    // Compares result[nf][FFT_SIZE] against gold[nf][FFT_SIZE]
    // with no tolerence (delta=0).
    function bit validate_acc_no_error(input bit [DATA_NB_BITS-1:0] result_acc[N_FFT][FFT_SIZE], input bit [DATA_NB_BITS-1:0] gold[N_FFT][FFT_SIZE]);
        for (int j=0; j<N_FFT; j++) begin
            for (int i = 0; i <FFT_SIZE ; i++) begin
                if (result_acc[j][i] != gold[j][i]) begin
                    if (FLOAT_POINT) begin
                        real real_part_gold = $bitstoshortreal(gold[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                        real imag_part_gold = $bitstoshortreal((gold[j][i][DATA_NB_BITS/2-1:0]));
                        real real_part_result = $bitstoshortreal(result_acc[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                        real imag_part_result = $bitstoshortreal(result_acc[j][i][DATA_NB_BITS/2-1:0]);
                        $display("[Mismatch] FFT number %0d and index %0d: Expected %0h(%f, %f), Got %0h(%f, %f)", j, i, $signed(gold[j][i]),real_part_gold, imag_part_gold,$signed(result_acc[j][i]),real_part_result ,imag_part_result);
                        return 1; // Error detected
                    end else begin
                        real real_part_gold = to_real(gold[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                        real imag_part_gold = to_real(gold[j][i][DATA_NB_BITS/2-1:0]);
                        real real_part_result = to_real(result_acc[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                        real imag_part_result = to_real(result_acc[j][i][DATA_NB_BITS/2-1:0]);
                        $display("[Mismatch] FFT number %0d and index %0d: Expected %0h(%f, %f), Got %0h(%f, %f)", j, i, $signed(gold[j][i]),real_part_gold, imag_part_gold,$signed(result_acc[j][i]),real_part_result ,imag_part_result);
                        return 1; // Error detected
                    end
                end
            end
        end;
        return 0;
    endfunction


    // Generate a golden reference for validation
    task automatic gold_gen(input bit [DATA_NB_BITS-1:0] entradas_fft[][],
                            ref   bit [DATA_NB_BITS-1:0] gold[][],
                            input bit apply_window = 1'b0,
                            input bit [DATA_NB_BITS/2-1:0] window [FFT_SIZE],
                            input bit ifft_mode = 1'b0);
        int n_frames;
        // Parameters for floating point
        shortreal x_re[FFT_SIZE], x_im[FFT_SIZE];
        shortreal X_re[FFT_SIZE], X_im[FFT_SIZE];
        shortreal temp_re, temp_im;
        shortreal tw_re[FFT_SIZE/2], tw_im[FFT_SIZE/2];

        // Parameters for fixed point
        bit [DATA_NB_BITS-1:0] ROM_fft[][]; 
        int unsigned addr_A;      
        int unsigned addr_B;      
        int twiddle_idx;
        bit [DATA_NB_BITS-1:0] twiddle_rom[FFT_SIZE/2];
        logic signed [DATA_NB_BITS/2-1:0] A_re, A_im; // Input A of Butterfly
        logic signed [DATA_NB_BITS/2-1:0] B_re, B_im; // Input B of Butterfly
        logic signed [DATA_NB_BITS/2-1:0] W_re, W_im; // Twiddle factor
        logic signed [DATA_NB_BITS-1:0]   mult_re_1, mult_re_2; // Intermediate parameters
        logic signed [DATA_NB_BITS-1:0]   mult_im_1, mult_im_2; // Intermediate parameters
        logic signed [DATA_NB_BITS/2-1:0] B_scaled_re, B_scaled_im; // Intermediate parameters

        // Global parameters
        real real_angle;
        const real PI = 3.14159265359;

        n_frames = entradas_fft.size();
        gold = new[n_frames];
        for (int j = 0; j < n_frames; j++) gold[j] = new[FFT_SIZE];

        if (FLOAT_POINT) begin
            // Twiddles buffer
            for (int k = 0; k < FFT_SIZE/2; k++) begin
                real_angle = -2.0 * PI * k / FFT_SIZE;
                tw_re[k] = shortreal'($cos(real_angle));
                tw_im[k] = shortreal'($sin(real_angle));
            end
            
            for (int j = 0; j < n_frames; j++) begin
                // Bit-reversal
                for (int i = 0; i < FFT_SIZE; i++) begin
                    logic [$clog2(FFT_SIZE)-1:0] rev_i;
                    shortreal wr;
                    shortreal sr, si;
                    for (int k = 0; k < $clog2(FFT_SIZE); k++) begin
                        rev_i[k] = i[$clog2(FFT_SIZE)-1-k];
                    end
                    wr = apply_window ? $bitstoshortreal(window[i]) : shortreal'(1.0);
                    sr = $bitstoshortreal(entradas_fft[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                    si = $bitstoshortreal(entradas_fft[j][i][DATA_NB_BITS/2-1:0]);
                    // iFFT : swap re/im at the beginning
                    x_re[rev_i] = (ifft_mode ? si : sr) * wr;
                    x_im[rev_i] = (ifft_mode ? sr : si) * wr;
                end
                
                // FFT
                for (int stage = 0; stage < $clog2(FFT_SIZE); stage++) begin
                    int distance = 2**stage;
                    for (int group = 0; group < FFT_SIZE; group += 2 * distance) begin
                        for (int elem = 0; elem < distance; elem++) begin
                            addr_A = group + elem;
                            addr_B = group + elem + distance;
                            twiddle_idx = elem * (FFT_SIZE / (2 * distance));
                            
                            temp_re = x_re[addr_B] * tw_re[twiddle_idx] - x_im[addr_B] * tw_im[twiddle_idx];
                            temp_im = x_re[addr_B] * tw_im[twiddle_idx] + x_im[addr_B] * tw_re[twiddle_idx];
                            
                            X_re[addr_A] = x_re[addr_A] + temp_re;
                            X_im[addr_A] = x_im[addr_A] + temp_im;
                            X_re[addr_B] = x_re[addr_A] - temp_re;
                            X_im[addr_B] = x_im[addr_A] - temp_im;
                        end
                    end

                    for (int i = 0; i < FFT_SIZE; i++) begin
                        x_re[i] = X_re[i];
                        x_im[i] = X_im[i];
                    end
                end
                
                
                for (int i = 0; i < FFT_SIZE; i++) begin
                    if (ifft_mode) begin
                        // swap re/im at the end, then 1/FFT_SIZE
                        gold[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2] = $shortrealtobits(X_im[i] / shortreal'(FFT_SIZE));
                        gold[j][i][DATA_NB_BITS/2-1:0]            = $shortrealtobits(X_re[i] / shortreal'(FFT_SIZE));
                    end else begin
                        gold[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2] = $shortrealtobits(X_re[i]);
                        gold[j][i][DATA_NB_BITS/2-1:0]            = $shortrealtobits(X_im[i]);
                    end
                end
            end
        
        end else begin

            ROM_fft = new[n_frames];
            for (int j = 0; j < n_frames; j++) ROM_fft[j] = new[FFT_SIZE];

            // Twiddles buffer
            for (int k = 0; k < FFT_SIZE/2; k++) begin
                real_angle = -2.0 * PI * k / FFT_SIZE;
                twiddle_rom[k] = {to_fixed($cos(real_angle)), to_fixed($sin(real_angle))};
            end
            

            // Bit-Reversal
            for (int j = 0; j < n_frames; j++) begin
                for (int i = 0; i < FFT_SIZE; i++) begin
                    logic [$clog2(FFT_SIZE)-1:0] rev_i;
                    logic signed [DATA_NB_BITS/2-1:0] xr, xi, wc;
                    logic signed [DATA_NB_BITS-1:0]   mul_re, mul_im;
                    for (int k = 0; k < $clog2(FFT_SIZE); k++) begin
                        rev_i[k] = i[$clog2(FFT_SIZE)-1-k];
                    end
                    // iFFT : swap re/im a l'entree (comme le RTL)
                    if (ifft_mode) begin
                        xr = $signed(entradas_fft[j][i][DATA_NB_BITS/2-1:0]);             
                        xi = $signed(entradas_fft[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                    end else begin
                        xr = $signed(entradas_fft[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                        xi = $signed(entradas_fft[j][i][DATA_NB_BITS/2-1:0]);
                    end
                    if (apply_window) begin
                        wc = $signed(window[i]);   
                        mul_re = $signed(xr) * $signed(wc);  
                        mul_im = $signed(xi) * $signed(wc);
                        ROM_fft[j][rev_i][DATA_NB_BITS-1:DATA_NB_BITS/2] = (DATA_NB_BITS/2)'($signed(mul_re) >>> 16);
                        ROM_fft[j][rev_i][DATA_NB_BITS/2-1:0]           = (DATA_NB_BITS/2)'($signed(mul_im) >>> 16);
                    end else begin
                        ROM_fft[j][rev_i][DATA_NB_BITS-1:DATA_NB_BITS/2] = xr;
                        ROM_fft[j][rev_i][DATA_NB_BITS/2-1:0]           = xi;
                    end
                end
            
                // FFT            
                
                for (int stage=0; stage<$clog2(FFT_SIZE); stage++) begin
                    int distance = 2**stage;
                    for (int group = 0; group < FFT_SIZE; group += 2 * distance) begin  
                        for (int elem = 0; elem < distance; elem++) begin
                            addr_A = group + elem;
                            addr_B = group + elem + distance;
                            twiddle_idx = elem * (FFT_SIZE / (2 * distance));
                        
                            A_re = $signed(ROM_fft[j][addr_A][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                            A_im = $signed(ROM_fft[j][addr_A][DATA_NB_BITS/2-1:0]);
                            B_re = $signed(ROM_fft[j][addr_B][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                            B_im = $signed(ROM_fft[j][addr_B][DATA_NB_BITS/2-1:0]);
                            
                            W_re = $signed(twiddle_rom[twiddle_idx][DATA_NB_BITS-1:DATA_NB_BITS/2]);
                            W_im = $signed(twiddle_rom[twiddle_idx][DATA_NB_BITS/2-1:0]); 
        
                            mult_re_1 = B_re * W_re;
                            mult_re_2 = B_im * W_im;
                            mult_im_1 = B_re * W_im;
                            mult_im_2 = B_im * W_re;
        
                            B_scaled_re = (DATA_NB_BITS/2)'($signed(mult_re_1 - mult_re_2) >>> DATA_NB_BITS/4);
                            B_scaled_im = (DATA_NB_BITS/2)'($signed(mult_im_1 + mult_im_2) >>> DATA_NB_BITS/4);
        
                            ROM_fft[j][addr_A][DATA_NB_BITS-1:DATA_NB_BITS/2] = A_re + B_scaled_re;
                            ROM_fft[j][addr_A][DATA_NB_BITS/2-1:0]  = A_im + B_scaled_im;
                            
                            ROM_fft[j][addr_B][DATA_NB_BITS-1:DATA_NB_BITS/2] = A_re - B_scaled_re;
                            ROM_fft[j][addr_B][DATA_NB_BITS/2-1:0]  = A_im - B_scaled_im;
                        end
                    end
                end

                for (int i = 0; i < FFT_SIZE; i++) begin
                    if (ifft_mode) begin
                        gold[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2] =
                            (DATA_NB_BITS/2)'($signed(ROM_fft[j][i][DATA_NB_BITS/2-1:0]) >>> $clog2(FFT_SIZE));
                        gold[j][i][DATA_NB_BITS/2-1:0] =
                            (DATA_NB_BITS/2)'($signed(ROM_fft[j][i][DATA_NB_BITS-1:DATA_NB_BITS/2]) >>> $clog2(FFT_SIZE));
                    end else begin
                        gold[j][i] = ROM_fft[j][i];
                    end
                end
            end
        end
    endtask

endclass
module trees_rtl_basic_dma64 #(
	parameter N_TREES          					= 128,
	parameter N_NODE_AND_LEAFS 					= 256,		// POWER OF 2
	parameter N_FEATURE        					= 32,
	parameter N_CLASES  		       			= 32,
	parameter MAX_BURST        					= 128 		// POWER OF 2 AND > 8
) (
	input  logic        clk,
	input  logic        rst,                          // Active-low reset

	// Configuration
	input  logic [31:0] conf_info_load_trees,
	input  logic [31:0] conf_info_burst_len,
	input  logic        conf_done,

	// Accelerator status
	output logic        acc_done,

	// DMA read control
	input  logic        dma_read_ctrl_ready,
	output logic        dma_read_ctrl_valid,
	output logic [31:0] dma_read_ctrl_data_index,
	output logic [31:0] dma_read_ctrl_data_length,
	output logic [2:0]  dma_read_ctrl_data_size,
	output logic [5:0]  dma_read_ctrl_data_user,

	// DMA read channel
	output logic        dma_read_chnl_ready,
	input  logic        dma_read_chnl_valid,
	input  logic [63:0] dma_read_chnl_data,

	// DMA write control
	input  logic        dma_write_ctrl_ready,
	output logic        dma_write_ctrl_valid,
	output logic [31:0] dma_write_ctrl_data_index,
	output logic [31:0] dma_write_ctrl_data_length,
	output logic [2:0]  dma_write_ctrl_data_size,
	output logic [5:0]  dma_write_ctrl_data_user,

	// DMA write channel
	input  logic        dma_write_chnl_ready,
	output logic        dma_write_chnl_valid,
	output logic [63:0] dma_write_chnl_data
);

	localparam integer TREES_LEN_BITS    = $clog2(N_NODE_AND_LEAFS);
	localparam integer TREE_IDX_BITS     = $clog2(N_TREES);
	localparam integer FEATURE_ADDR_BITS = $clog2(MAX_BURST*N_FEATURE/2);
	localparam integer BURST_CNT_BITS    = $clog2(MAX_BURST+1);
	localparam integer PRED_WORDS        = (MAX_BURST + 7) / 8;
	localparam integer PRED_ADDR_BITS    = $clog2(PRED_WORDS+1);

	typedef enum logic [1:0] {
		IDLE_R,
		DMA_PONG_PING,
		DMA_TREES,
		START_TREES
	} state_read_e;
	state_read_e                  read_e;

	typedef enum logic [1:0] {
		IDLE_W,
		DMA_WRITE_TREES,
		DMA_WRITE_PREDICTIONS
	} state_write_e;
	state_write_e                   write_e;

	logic [31:0]                    rd_ptr, wr_ptr;
	logic [TREES_LEN_BITS-1:0]      address_node;
	logic [TREE_IDX_BITS-1:0]       address_tree;
	logic [FEATURE_ADDR_BITS-1:0]   feature_addr;
	logic [BURST_CNT_BITS-1:0]      burst_len_acc;
	logic [PRED_ADDR_BITS-1:0]      prediction_addr;
	logic                           end_compute;
	logic                           idle;
	logic [63:0]                    prediction;
	logic                           start;
	logic                           load_features_dma;
	logic                           load_trees_dma;
	logic [31:0]                    clk_stamp1, clk_stamp2;
	logic [31:0]                    clk_stamp1_ff, clk_stamp2_ff;
	logic                           m_ping_pong;
	logic                           e_ping_pong;
	logic [31:0]                    burst_len;
	logic [31:0]                    burst_write;


	logic 							write_trees_clk;
	logic [31:0]                    samples_2_process;
	logic [31:0]                    samples_processed;
	logic [31:0]                    samples_written;


	// TREES COMPUTE UNIT
	trees_ping_pong #(
		.N_TREES(N_TREES),
		.N_NODE_AND_LEAFS(N_NODE_AND_LEAFS),
		.N_FEATURE(N_FEATURE),
	    .N_CLASES(N_CLASES),
		.MAX_BURST(MAX_BURST)
	) trees_ping_pong_ins (
		.clk(clk),
		.rst_n(rst),
		.start(start),
		.idle(idle),
		.m_ping_pong(m_ping_pong),
		.e_ping_pong(e_ping_pong),
		
		.load_trees(load_trees_dma),
		.n_node(address_node),
		.n_tree(address_tree),
		.tree_nodes(dma_read_chnl_data),

		.load_features(load_features_dma),
		.feature_addr(feature_addr),
		.burst_len(burst_len_acc),
		.features2(dma_read_chnl_data),

		.prediction(prediction),
		.prediction_addr(prediction_addr),
		.done(end_compute)
	);

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			read_e <= IDLE_R;
			dma_read_ctrl_valid     	<= 0;
			dma_read_ctrl_data_index 	<= 0;
			dma_read_ctrl_data_length 	<= 0;
			dma_read_ctrl_data_size 	<= 0;
			dma_read_ctrl_data_user 	<= 0;
			dma_read_chnl_ready     	<= 0;
			write_trees_clk         	<= 0;
			samples_2_process 			<= 0;
			samples_processed 			<= 0;
			rd_ptr                   	<= 0;
			m_ping_pong		 			<= 1; // Start with ping
			e_ping_pong		 			<= 0;
			start 						<= 0;
			burst_len					<= 0;
			burst_write					<= 0;
			clk_stamp1 <= 0;
			clk_stamp2 <= 0;
		end else begin
			case (read_e)
				IDLE_R: begin
					write_trees_clk <= 0;
					samples_processed <= 0;
					start <= 0;

					if (conf_done && conf_info_load_trees[0]) begin
						dma_read_ctrl_valid       <= 1;
						dma_read_ctrl_data_length <= N_TREES * N_NODE_AND_LEAFS;
						dma_read_ctrl_data_size   <= 3'b011;
						dma_read_ctrl_data_user   <= 0;
						dma_read_chnl_ready       <= 1;
						dma_read_ctrl_data_index  <= 0;
						clk_stamp1 <= 32'h526F6472;
						clk_stamp2 <= 32'h69676F00;
						read_e <= DMA_TREES;
					end else if (conf_done && conf_info_burst_len != 0) begin
						m_ping_pong <= 1; // Start with ping
						e_ping_pong <= 0;
						dma_read_ctrl_valid       <= 1;
						// FEATURES COME IN PAIRS
						dma_read_ctrl_data_length <= conf_info_burst_len <= MAX_BURST ? 
														(conf_info_burst_len * N_FEATURE + 1) >> 1 : 
														(MAX_BURST * N_FEATURE + 1) >> 1;
						samples_2_process <= conf_info_burst_len;
						dma_read_ctrl_data_size   <= 3'b011;
						dma_read_ctrl_data_user   <= 0;
						dma_read_chnl_ready       <= 1;
						dma_read_ctrl_data_index  <= 0;
						clk_stamp1 <= 0;
						clk_stamp2 <= 0;
						read_e <= DMA_PONG_PING;
					end
				end
					DMA_TREES: begin
						if (dma_read_ctrl_valid && dma_read_ctrl_ready)
							dma_read_ctrl_valid <= 0;
						if (dma_read_chnl_valid && dma_read_chnl_ready) begin
							rd_ptr <= rd_ptr + 1;
							if (rd_ptr == dma_read_ctrl_data_length - 1) begin
								dma_read_chnl_ready <= 0;
								rd_ptr <= 0;
								write_trees_clk <= 1;
								read_e  <= IDLE_R;
							end
						end
					end
					DMA_PONG_PING: begin
						clk_stamp1 <= clk_stamp1 + 1;
						start <= 0;
						if (dma_read_ctrl_valid && dma_read_ctrl_ready)
							dma_read_ctrl_valid <= 0;

						if (dma_read_chnl_valid && dma_read_chnl_ready) begin
							rd_ptr <= rd_ptr + 1;
							if (rd_ptr == dma_read_ctrl_data_length - 1) begin
								dma_read_chnl_ready <= 0;
								rd_ptr <= 0;
								burst_len <= (samples_2_process - samples_processed) < MAX_BURST ?
												(samples_2_process - samples_processed) : MAX_BURST;
								read_e  <= START_TREES;
							end
						end
					end
				START_TREES: begin
					clk_stamp2 <= clk_stamp2 + 1;
					if(idle && write_e == IDLE_W) begin
						if(samples_processed + burst_len < samples_2_process) begin
							burst_write <= burst_len;
							start <= 1;
							samples_processed <= samples_processed + burst_len;

							dma_read_ctrl_valid       <= 1;
							// FEATURES COME IN PAIRS
							dma_read_ctrl_data_length <= (samples_2_process - burst_len - samples_processed) < MAX_BURST ?
															((samples_2_process - burst_len - samples_processed) * N_FEATURE + 1) >> 1 :
															(MAX_BURST * N_FEATURE + 1) >> 1;

							dma_read_ctrl_data_size   <= 3'b011;
							dma_read_ctrl_data_user   <= 0;
							dma_read_chnl_ready       <= 1;
							dma_read_ctrl_data_index  <= (samples_processed + burst_len)*(N_FEATURE ) >> 1;
							m_ping_pong <= !m_ping_pong;
							e_ping_pong <= m_ping_pong;
							read_e  <= DMA_PONG_PING;
						end else begin
							burst_write <= burst_len;
							start <= 1;
							samples_processed <= samples_processed + burst_len;
							dma_read_ctrl_valid       <= 0;
							dma_read_ctrl_data_length <= 0;

							dma_read_ctrl_data_size   <= 3'b011;
							dma_read_ctrl_data_user   <= 0;
							dma_read_chnl_ready       <= 0;
							dma_read_ctrl_data_index  <= 0;
							e_ping_pong <= m_ping_pong;
							read_e  <= IDLE_R;
						end

					end
				end
				default: begin
					read_e <= IDLE_R;
				end
			endcase
		end
	end

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			dma_write_ctrl_valid    	<= 0;
			dma_write_ctrl_data_index 	<= 0;
			dma_write_ctrl_data_length 	<= 0;
			dma_write_ctrl_data_size 	<= 0;
			dma_write_ctrl_data_user 	<= 0;
			dma_write_chnl_valid	   	<= 0;
			acc_done			 		<= 0;
			samples_written				<= 0;
			wr_ptr						<= 0;
			write_e 					<= IDLE_W;
		end else begin
			case (write_e)
				IDLE_W: begin
					acc_done <= 0;
					if (samples_written == samples_2_process && samples_2_process != 0) begin
						acc_done <= 1;
						samples_written <= 0;
					end
					if (write_trees_clk) begin
						dma_write_ctrl_valid       <= 1;
						dma_write_ctrl_data_length <= 1;	// performance CLK
						dma_write_ctrl_data_size   <= 3'b011;
						dma_write_ctrl_data_user   <= 0;
						dma_write_chnl_valid	   <= 1;
						dma_write_ctrl_data_index  <= 0;
						write_e <= DMA_WRITE_TREES;

					end 
					if (end_compute) begin
						write_e <= DMA_WRITE_PREDICTIONS;
						dma_write_ctrl_valid       <= 1;
						//ceil(x) / 8) + performance CLK
						dma_write_ctrl_data_length <= ((burst_write + 7) >> 3) + 1;
						dma_write_ctrl_data_size   <= 3'b011;
						dma_write_ctrl_data_user   <= 0;
						dma_write_chnl_valid	   <= 1;
						dma_write_ctrl_data_index  <= samples_written >> 3; // 8 predictions per beat

					end
				end
				DMA_WRITE_TREES: begin
					if (dma_write_ctrl_valid && dma_write_ctrl_ready)
						dma_write_ctrl_valid <= 0;

					if (dma_write_chnl_valid && dma_write_chnl_ready) begin
						dma_write_chnl_valid <= 0;
						write_e <= IDLE_W;
						acc_done <= 1;
					end
				end
				DMA_WRITE_PREDICTIONS: begin
					if (dma_write_ctrl_valid && dma_write_ctrl_ready)
						dma_write_ctrl_valid <= 0;

					if (dma_write_chnl_valid && dma_write_chnl_ready) begin
						wr_ptr <= wr_ptr + 1;
						if (wr_ptr == dma_write_ctrl_data_length - 1) begin
							dma_write_chnl_valid <= 0;
							wr_ptr  <= 0;
							samples_written <= samples_written + burst_write;
							write_e   <= IDLE_W;
						end
					end
				end
				default: begin
					write_e <= IDLE_W;
				end
			endcase
		end

	end

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			clk_stamp1_ff <= 32'b0;
			clk_stamp2_ff <= 32'b0;
		end else begin
			if (dma_write_chnl_ready && dma_write_chnl_valid) begin
				clk_stamp1_ff <= clk_stamp1;
				clk_stamp2_ff <= clk_stamp2;
			end
		end
	end

	always_comb begin
		if (write_e == DMA_WRITE_TREES) begin
			dma_write_chnl_data = {clk_stamp1_ff, clk_stamp2_ff};
		end else if (write_e == DMA_WRITE_PREDICTIONS) begin

			if (wr_ptr == dma_write_ctrl_data_length-1)
				dma_write_chnl_data = {clk_stamp1_ff, clk_stamp2_ff};
			else
				dma_write_chnl_data = prediction;
		end else begin
			dma_write_chnl_data = {clk_stamp1_ff, clk_stamp2_ff};
		end
	end

	always_comb begin
		address_node = rd_ptr[TREES_LEN_BITS-1:0];
		address_tree = rd_ptr[TREES_LEN_BITS +: TREE_IDX_BITS];
		feature_addr = rd_ptr[FEATURE_ADDR_BITS-1:0];
		burst_len_acc = burst_len[BURST_CNT_BITS-1:0];
		prediction_addr = wr_ptr[PRED_ADDR_BITS-1:0];
		load_trees_dma = dma_read_chnl_valid && dma_read_chnl_ready && (read_e == DMA_TREES);
		load_features_dma = dma_read_chnl_valid && dma_read_chnl_ready && (read_e == DMA_PONG_PING);
	end

endmodule

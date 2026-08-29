module trees_ping_pong #(
	parameter N_TREES          					= 16,
	parameter N_NODE_AND_LEAFS 					= 256,
	parameter N_FEATURE        					= 32,
	parameter N_CLASES  		       			= 32,
	parameter MAX_BURST        					= 5000
)(
    input  logic                                    	clk,
    input  logic                                    	rst_n,
    input  logic                                    	start,
    output logic                                    	idle,

    input  logic                                    	m_ping_pong, // 1: ping, 0: pong
    input  logic                                    	e_ping_pong, // 1: ping, 0: pong

    input  logic                                    	load_trees,
    input  logic [$clog2(N_NODE_AND_LEAFS)-1:0]     	n_node,
    input  logic [$clog2(N_TREES)-1:0]              	n_tree,
    input  logic [63:0]                             	tree_nodes,

    input  logic                                   		load_features,
    input  logic [$clog2(MAX_BURST*N_FEATURE/2)-1:0]	feature_addr,
    input  logic [$clog2(MAX_BURST):0]     				burst_len,
    input  logic [63:0]                             	features2,

    output logic [63:0]									prediction,
    input  logic [$clog2(((MAX_BURST + 7) / 8)+1)-1:0]	prediction_addr,
    output logic										done
	);

		localparam HALF_N_FEATURE     = N_FEATURE/2;
		localparam HALF_N_FEATURE_BITS = $clog2(HALF_N_FEATURE);
		localparam MAX_BURST_BITS     = $clog2(MAX_BURST);
		localparam BURST_CNT_BITS     = $clog2(MAX_BURST+1);
		localparam FEATURE_WORDS      = MAX_BURST*HALF_N_FEATURE;
		localparam FEATURE_ADDR_BITS  = $clog2(FEATURE_WORDS);
		localparam PRED_WORDS         = (MAX_BURST + 7) / 8;
		localparam PRED_WORD_BITS     = $clog2(PRED_WORDS);
		localparam PRED_ADDR_BITS     = $clog2(PRED_WORDS+1);

    typedef enum logic[1:0] { P_IDLE, P_PING, P_PONG, P_WAIT} process_state;
	process_state proc_st;

    typedef enum logic[1:0] { C_IDLE, C_PING, C_PONG, C_WAIT} copy_state;
	copy_state copy_st;

	(* ram_style = "block" *) 
		logic [63:0] 					prediction_mem [0:PRED_WORDS-1];
	    logic [7:0]                    	prediction_set;
	    logic [63:0]                	prediction_packed;
		logic [BURST_CNT_BITS-1:0] 		prediction_index;
		logic [BURST_CNT_BITS-1:0] 		n_starts;
		logic [PRED_WORD_BITS-1:0]		prediction_wr_addr;


	(* ram_style = "block" *) 
	logic [63:0] 						features_mem_ping [MAX_BURST*HALF_N_FEATURE-1:0];
	logic								load_features_ping;

	(* ram_style = "block" *) 
	logic [63:0] 						features_mem_pong [MAX_BURST*HALF_N_FEATURE-1:0];
	logic								load_features_pong;

	logic [N_FEATURE-1:0][31:0] 		features_mux;
	logic [HALF_N_FEATURE-1:0][63:0] 	features_ping;
	logic [HALF_N_FEATURE-1:0][63:0] 	features_pong;
		logic [HALF_N_FEATURE_BITS:0] 		feature_index;
		logic [BURST_CNT_BITS-1:0]			burst_len_ff;
		logic [BURST_CNT_BITS-1:0]			burst_index;
		logic [FEATURE_ADDR_BITS-1:0]		feature_mem_addr;

	logic 								c_ping_ready;
	logic 								c_pong_ready;
	logic 								c_ping_pong;

	logic 								p_ping_ready;
	logic 								p_pong_ready;
	logic 								p_ping_pong;

	logic 								start_set;
	logic 								done_set;
	logic 								store_predictions;

	logic								load_predictions;

	logic 								idle_sys;

    trees #(
        .N_TREES(N_TREES),
        .N_NODE_AND_LEAFS(N_NODE_AND_LEAFS),
        .N_FEATURE(N_FEATURE),
	    .N_CLASES(N_CLASES)
	)trees_u (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_set),

        .load_trees(load_trees),
        .n_node(n_node),
        .n_tree(n_tree),
        .tree_nodes(tree_nodes),

        .features(features_mux),

        .prediction(prediction_set),
        .done(done_set),
		.store_predictions(store_predictions),
		.idle_sys(idle_sys)
    );

	// ---------------------------------------------------
	//  LOAD FEATURES
	// ---------------------------------------------------
	always_comb begin
		load_features_ping = load_features && m_ping_pong;
		load_features_pong = load_features && !m_ping_pong;		
	end

		always_comb begin
			feature_mem_addr = {burst_index[MAX_BURST_BITS-1:0], {HALF_N_FEATURE_BITS{1'b0}}} +
				FEATURE_ADDR_BITS'(feature_index[HALF_N_FEATURE_BITS-1:0]);
			prediction_wr_addr = PRED_WORD_BITS'((prediction_index - BURST_CNT_BITS'(1)) >> 3);
		end

		always_ff @(posedge clk)
	    	if (load_features_ping)
	    	  	features_mem_ping[feature_addr] <= features2;

	always_ff @(posedge clk)
    	if (load_features_pong)
    	  	features_mem_pong[feature_addr] <= features2;

		// ---------------------------------------------------
		//  LOAD PREDICTIONS
		// ---------------------------------------------------
		always_ff @(posedge clk)
	    	if (load_predictions)
				prediction_mem[prediction_wr_addr] <= prediction_packed;

	// ---------------------------------------------------
		//  READ PREDICTIONS
		// ---------------------------------------------------
		always_comb
			prediction = (int'(prediction_addr) < PRED_WORDS) ?
				prediction_mem[prediction_addr[PRED_WORD_BITS-1:0]] : 64'b0;

	// ---------------------------------------------------
	//  COPY FEATURES PING PONG
	// ---------------------------------------------------
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			copy_st <= C_IDLE;
			p_ping_ready <= 0;
			p_pong_ready <= 0;
			c_ping_pong <= 1;
			feature_index <= 0;
			burst_index <= 0;
			features_ping <= 0;
			features_pong <= 0;
		end else begin
			case (copy_st)
				C_IDLE: begin
					if (start) begin
						copy_st <= C_WAIT;
						p_ping_ready <= 0;
						p_pong_ready <= 0;
						burst_index <= 0;
						feature_index <= 0;
						c_ping_pong <= 1;
						burst_len_ff <= burst_len;
					end
				end
				C_WAIT: begin
					feature_index <= 0;
					if (c_ping_ready && c_ping_pong)
						copy_st <= C_PING;
					if (c_pong_ready && !c_ping_pong)
						copy_st <= C_PONG;
					if (burst_index == burst_len_ff) begin
						copy_st <= C_IDLE;
					end
				end
				C_PING: begin
						if (int'(feature_index) < HALF_N_FEATURE) begin
							features_ping[feature_index[HALF_N_FEATURE_BITS-1:0]] <= e_ping_pong ?
								features_mem_ping[feature_mem_addr] :
								features_mem_pong[feature_mem_addr];
						feature_index <= feature_index + 1;
						p_ping_ready <= 0;
					end else begin
						burst_index <= burst_index + 1;
						p_ping_ready <= 1;
						c_ping_pong <= 0;
						copy_st <= C_WAIT;
					end
				end
				C_PONG: begin
						if (int'(feature_index) < HALF_N_FEATURE) begin
							features_pong[feature_index[HALF_N_FEATURE_BITS-1:0]] <= e_ping_pong ?
								features_mem_ping[feature_mem_addr] :
								features_mem_pong[feature_mem_addr];
						feature_index <= feature_index + 1;
						p_pong_ready <= 0;
					end else begin
						burst_index <= burst_index + 1;
						p_pong_ready <= 1;
						c_ping_pong <= 1;
						copy_st <= C_WAIT;
					end
				end
			endcase
		end
	end

	// ---------------------------------------------------
	//  PROCESS FEATURES PING PONG
	// ---------------------------------------------------
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			proc_st <= P_IDLE;
			c_ping_ready <= 1;
			c_pong_ready <= 1;
			p_ping_pong <= 1;
			start_set <= 0;
			done <= 0;
			idle <= 1;
			n_starts <= 0;
		end else begin
			case (proc_st)
				P_IDLE: begin
					start_set <= 0;
					done <= 0;
					idle <= 1;
					if (start) begin
						idle <= 0;
						n_starts <= 0;
						proc_st <= P_WAIT;
						c_ping_ready <= 1;
						c_pong_ready <= 1;
						p_ping_pong <= 1;
					end
				end
				P_WAIT: begin
					c_ping_ready <= idle_sys;
					c_pong_ready <= idle_sys;
					if (n_starts < burst_len_ff) begin
						if (p_ping_ready && p_ping_pong && idle_sys) begin
							proc_st <= P_PING;
							start_set <= 1;
							n_starts <= n_starts + 1;
							c_ping_ready <= 0;
							/* 
							Each 64-bit word in features_ping contains two 32-bit features;
							the assignment to features_mux splits them to feed the tree ensemble.
							*/
							features_mux <= features_ping;
						end
						if (p_pong_ready && !p_ping_pong && idle_sys) begin
							proc_st <= P_PONG;
							start_set <= 1;
							n_starts <= n_starts + 1;
							c_pong_ready <= 0;
							/* 
							Each 64-bit word in features_ping contains two 32-bit features;
							the assignment to features_mux splits them to feed the tree ensemble.
							*/
							features_mux <= features_pong;
						end
					end
					if (prediction_index == burst_len_ff) begin
						proc_st <= P_IDLE;
						done <= 1;
					end
				end
				P_PING: begin
					start_set <= 0;
					if (done_set) begin
						proc_st <= P_WAIT;
						c_ping_ready <= 1;
						p_ping_pong <= 0;
					end
				end
				P_PONG: begin
					start_set <= 0;
					if (done_set) begin
						proc_st <= P_WAIT;
						c_pong_ready <= 1;
						p_ping_pong <= 1;
					end
				end
			endcase
		end
	end

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			prediction_packed <= 0;
			load_predictions <= 0;
			prediction_index <= 0;
		end else begin
			if (proc_st == P_IDLE) begin
				prediction_packed <= 0;
				load_predictions  <= 0;
				prediction_index  <= 0;
			end

				if (store_predictions) begin
					load_predictions <= 1;
					prediction_packed[{prediction_index[2:0], 3'b000} +: 8] <= prediction_set[7:0];
					prediction_index <= prediction_index + 1;
			end else begin
				load_predictions <= 0;
			end
		end
	end

endmodule

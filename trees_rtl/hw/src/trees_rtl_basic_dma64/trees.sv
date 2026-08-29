module trees #(
	parameter int N_TREES          = 16,
	parameter int N_NODE_AND_LEAFS = 256,
	parameter int N_FEATURE        = 32,
	parameter int N_CLASES         = 32,
	parameter int UNROLL_C	       = 8,
	parameter int UNROLL_V	       = 2
)(
	input  logic                          		clk,
	input  logic                          		rst_n,
	input  logic                          		start,

	// Port para carga de nodos
	input  logic                          		load_trees,
	input  logic [$clog2(N_NODE_AND_LEAFS)-1:0] n_node,
	input  logic [$clog2(N_TREES)-1:0]         	n_tree,
	input  logic [63:0]                   		tree_nodes,

	// Características de entrada
	input  logic [N_FEATURE-1:0][31:0]    		features,

	// Salida final
	output logic [7:0]                    		prediction,
	output logic                          		done,
	output logic                          		store_predictions,
	output logic                          		idle_sys
);

	// ----------------------------------------------------------------
	//  Anchos internos
	// ----------------------------------------------------------------
	localparam int FEAT_IDX_W  = $clog2(N_FEATURE);
	localparam int N_CLASES_W  = $clog2(N_CLASES);
	localparam int CNT_W       = $clog2(N_TREES+1);
	localparam int N_NODE_W    = $clog2(N_NODE_AND_LEAFS);
	localparam int VOTE_IDX_W  = $clog2(N_CLASES+1);
	localparam int TREES_PER_UNROLL = N_TREES / UNROLL_C;

	// ----------------------------------------------------------------
	//  Señales para el ensamble de árboles
	// ----------------------------------------------------------------
	logic [31:0]               leaf_vals    [0:N_TREES-1];
	logic [31:0]               leaf_vals_ff [0:N_TREES-1];
	logic [N_TREES-1:0]        tree_done;
	logic [FEAT_IDX_W-1:0]     feature_idx  [0:N_TREES-1];
	logic [N_NODE_W-1:0]       node_idx     [0:N_TREES-1];

	// ----------------------------------------------------------------
	//  Contadores para votación
	// ----------------------------------------------------------------
	logic [CNT_W-1:0]          			voted_trees  	[UNROLL_C-1:0][0:N_CLASES-1];
	logic [CNT_W-1:0]          			voted_trees_s  	[0:N_CLASES-1];
	logic [CNT_W-1:0]          			voted_trees_s_f	[0:N_CLASES-1];
	logic [CNT_W-1:0]          			cnt_trees;
	logic [VOTE_IDX_W-1:0]       		cnt_vote;
	logic [CNT_W-1:0]     				max_vote;
	logic [CNT_W-1:0]     				max_vote_ff;
	logic [7:0]     					prediction_ff;
	logic [7:0]     					prediction_next;

	function automatic logic leaf_value_valid(input logic [31:0] leaf_value);
		leaf_value_valid = !leaf_value[31] && (leaf_value < N_CLASES);
	endfunction

	function automatic logic [N_CLASES_W-1:0] leaf_value_index(input logic [31:0] leaf_value);
		leaf_value_index = leaf_value[N_CLASES_W-1:0];
	endfunction

	// FSM de control de trees
	typedef enum logic { T_IDLE, T_WORK } tree_st_t;
	tree_st_t tree_st;
	logic t_done;
	// FSM de control de count
	typedef enum logic { C_IDLE, C_WORK } count_st_t;
	count_st_t count_st;
	logic c_done;
	// FSM de control de votación
	typedef enum logic { V_IDLE, V_WORK} vote_st_t;
	vote_st_t vote_st;
	logic v_done;

	// ----------------------------------------------------------------
	//  Instanciación de N_TREES BRAMs y motores tree
	// ----------------------------------------------------------------
	genvar t;
	generate
		for (t = 0; t < N_TREES; t++) begin : GEN_TREES
			// Cada árbol tiene su BRAM individual inferida
			(* ram_style = "block" *)
			logic [63:0] tree_mem_t [0:N_NODE_AND_LEAFS-1];

			// Dato leído registrado
			logic [63:0] tree_node_q;

			// Escritura y lectura síncronas en un solo always_ff
			always_ff @(posedge clk) begin
				// Escritura de nodos
				if (load_trees && (n_tree == t))
				  	tree_mem_t[n_node] <= tree_nodes;
			end
		    
		  	always_comb tree_node_q = tree_mem_t[ node_idx[t] ];
		  
		    
			// Instancia del árbol de decisión
			tree #(
				.N_NODE_AND_LEAFS(N_NODE_AND_LEAFS),
				.N_FEATURE       (N_FEATURE)
			) tree_u (
				.clk           (clk),
				.rst_n         (rst_n),
				.start         (start),
				.feature       (features[ feature_idx[t] ]),
				.feature_index (feature_idx[t]),
				.node          (tree_node_q),
				.node_index    (node_idx[t]),
				.leaf_value    (leaf_vals[t]),
				.done          (tree_done[t])
			);
		end
	endgenerate

	// ----------------------------------------------------------------
	//  FSM de: TREES
	// ----------------------------------------------------------------
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			tree_st <= T_IDLE;
			t_done <= 0;
			for (int i = 0; i < N_TREES; i++)
				leaf_vals_ff[i] <= 0;
		end else begin

			case (tree_st)
			T_IDLE: begin
				t_done <= 0;
				if (start) begin
					tree_st <= T_WORK;
				end
			end
				T_WORK: begin
					if (&tree_done && count_st == C_IDLE) begin
						tree_st <= T_IDLE;
						t_done <= 1;
						// Copiar valores de hojas a registros
						for (int i = 0; i < N_TREES; i++)
							leaf_vals_ff[i] <= leaf_vals[i];
					end
				end
				default: tree_st <= T_IDLE;
			endcase
		end
	end

	always_comb begin
		done = t_done;
		idle_sys = (tree_st == T_IDLE);
	end 

	// ----------------------------------------------------------------
	//  FSM de: COUNT
	// ----------------------------------------------------------------
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			count_st 	<= C_IDLE;
			c_done   	<= 0;
			cnt_trees   <= 0;
			for (int i = 0; i < N_CLASES; i++)
				voted_trees_s_f[i] <= 0;
			for (int j=0; j<UNROLL_C; ++j)
				for (int i = 0; i < N_CLASES; i++)
					voted_trees[j][i] <= 0;
		end else begin
			case (count_st)
			C_IDLE: begin
				cnt_trees   <= 0;
				c_done <= 0;
				for (int j=0; j<UNROLL_C; ++j)
					for (int i = 0; i < N_CLASES; i++)
						voted_trees[j][i] <= 0;
				if (t_done) begin
					count_st <= C_WORK;
				end
			end
				C_WORK: begin
					if (int'(cnt_trees) < TREES_PER_UNROLL) begin
						for (int j = 0; j < UNROLL_C; j++) begin
							int unsigned tree_i;
							tree_i = int'(cnt_trees) + j * TREES_PER_UNROLL;
							if (tree_i < N_TREES && leaf_value_valid(leaf_vals_ff[tree_i])) begin
								voted_trees[j][leaf_value_index(leaf_vals_ff[tree_i])] <= 
									voted_trees[j][leaf_value_index(leaf_vals_ff[tree_i])] + 1;
							end
						end
						cnt_trees <= cnt_trees + 1;
					end else if (vote_st == V_IDLE) begin
						c_done    <= 1;
					count_st  <= C_IDLE;
					for (int i = 0; i < N_CLASES; i++)
						voted_trees_s_f[i] <= voted_trees_s[i];
				end
			end
			default: count_st <= C_IDLE;
			endcase
		end
	end

	always_comb begin
		for (int i = 0; i < N_CLASES; i++) begin
			voted_trees_s[i] = 0;
			for (int j = 0; j < UNROLL_C; j++)
				voted_trees_s[i] += voted_trees[j][i];
		end
	end

	// ----------------------------------------------------------------
	//  FSM de: VOTE
	// ----------------------------------------------------------------
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			vote_st   <= V_IDLE;
			v_done    <= 0;
			cnt_vote  <= 0;
			prediction <= 0;
			max_vote_ff <= 0;
			prediction_ff <= 0;
		end else begin
			case (vote_st)
			V_IDLE: begin
				prediction <= 0;
				max_vote_ff <= 0;
				prediction_ff <= 0;
				v_done <= 0;
				cnt_vote <= 0;
				if (c_done) begin
					vote_st <= V_WORK;
				end
				end
				V_WORK: begin
					if (int'(cnt_vote) < N_CLASES) begin
						cnt_vote <= cnt_vote + VOTE_IDX_W'(UNROLL_V);
					end else begin
						v_done <= 1;
					prediction <= prediction_ff;
					vote_st <= V_IDLE;
				end
				prediction_ff <= prediction_next;
				max_vote_ff <= max_vote;
			end
			default: vote_st <= V_IDLE;
			endcase
		end
	end

	always_comb	store_predictions = v_done;

	always_comb begin
		max_vote = max_vote_ff;
		prediction_next = prediction_ff;

		for (int j = 0; j < UNROLL_V; j++) begin
			int unsigned vote_i;
			vote_i = int'(cnt_vote) + j;
			if (vote_i < N_CLASES && max_vote < voted_trees_s_f[vote_i]) begin
				max_vote = voted_trees_s_f[vote_i];
				prediction_next = vote_i[7:0];
			end
		end
	end


endmodule

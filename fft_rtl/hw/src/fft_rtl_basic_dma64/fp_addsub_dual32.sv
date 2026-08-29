module fp_addsub_dual32 (
  input  logic        clk, 
  input  logic        rst_n, 
  input  logic        en,
  input  logic [31:0] a_i, 
  input  logic [31:0] b_i, 
  output logic [31:0] sum_o,    // = a + b
  output logic [31:0] diff_o    // = a - b 
);
  // Shared front-end signals
  logic Sa, Sb; 
  logic [7:0] Ea, Eb, Eae, Ebe, EL, ES, ediff; 
  logic [23:0] Ma, Mb, ML, MS; 
  logic swap; 
  logic a_is_zero, b_is_zero, a_is_special, b_is_special; 

  // Mantissas extended to 27 bits (24 + GRS)
  logic [26:0] ML_ext, MS_ext, MSa_ext;
  logic sticky;
  logic [27:0] sum_add, sum_sub; // Datapath extended to 28 bits

  function automatic logic [4:0] lzc27(input logic [26:0] v);
    casez (v)
      27'b1??????????????????????????: lzc27 = 5'd0;
      27'b01?????????????????????????: lzc27 = 5'd1;
      27'b001????????????????????????: lzc27 = 5'd2;
      27'b0001???????????????????????: lzc27 = 5'd3;
      27'b00001??????????????????????: lzc27 = 5'd4;
      27'b000001?????????????????????: lzc27 = 5'd5;
      27'b0000001????????????????????: lzc27 = 5'd6;
      27'b00000001???????????????????: lzc27 = 5'd7;
      27'b000000001??????????????????: lzc27 = 5'd8;
      27'b0000000001?????????????????: lzc27 = 5'd9;
      27'b00000000001????????????????: lzc27 = 5'd10;
      27'b000000000001???????????????: lzc27 = 5'd11;
      27'b0000000000001??????????????: lzc27 = 5'd12;
      27'b00000000000001?????????????: lzc27 = 5'd13;
      27'b000000000000001????????????: lzc27 = 5'd14;
      27'b0000000000000001???????????: lzc27 = 5'd15;
      27'b00000000000000001??????????: lzc27 = 5'd16;
      27'b000000000000000001?????????: lzc27 = 5'd17;
      27'b0000000000000000001????????: lzc27 = 5'd18;
      27'b00000000000000000001???????: lzc27 = 5'd19;
      27'b000000000000000000001??????: lzc27 = 5'd20;
      27'b0000000000000000000001?????: lzc27 = 5'd21;
      27'b00000000000000000000001????: lzc27 = 5'd22;
      27'b000000000000000000000001???: lzc27 = 5'd23;
      27'b0000000000000000000000001??: lzc27 = 5'd24;
      27'b00000000000000000000000001?: lzc27 = 5'd25;
      27'b000000000000000000000000001: lzc27 = 5'd26;
      default:                         lzc27 = 5'd27;
    endcase
  endfunction

  always_comb begin
    Sa = a_i[31];  Sb = b_i[31]; 
    Ea = a_i[30:23]; Eb = b_i[30:23];
    a_is_zero    = (Ea == 8'd0);
    b_is_zero    = (Eb == 8'd0); 
    a_is_special = (Ea == 8'hff); 
    b_is_special = (Eb == 8'hff); 

    Ma  = a_is_zero ? 24'd0 : {1'b1, a_i[22:0]};
    Mb  = b_is_zero ? 24'd0 : {1'b1, b_i[22:0]}; 
    Eae = a_is_zero ? 8'd1  : Ea; 
    Ebe = b_is_zero ? 8'd1  : Eb; 

    swap = ({Eae, Ma} < {Ebe, Mb}); 
    EL   = swap ? Ebe : Eae;
    ES   = swap ? Eae : Ebe; 
    ML   = swap ? Mb  : Ma; 
    MS   = swap ? Ma  : Mb;

    ediff  = EL - ES;
    ML_ext = {ML, 3'b000};
    MS_ext = {MS, 3'b000};

    // Shared alignment shifter with exact Sticky-bit computation
    if (ediff >= 8'd27) begin
      MSa_ext = 27'd0;
      sticky  = |MS;
    end else begin
      MSa_ext = MS_ext >> ediff[4:0];
      sticky  = (ediff[4:0] != 5'd0) ? |({5'b0, MS_ext} & ((32'd1 << ediff[4:0]) - 32'd1)) : 1'b0;
    end
    MSa_ext[0] = MSa_ext[0] | sticky;

    sum_add = {1'b0, ML_ext} + {1'b0, MSa_ext};
    sum_sub = {1'b0, ML_ext} - {1'b0, MSa_ext};
  end

  // Shared normalisation shifter for the subtraction (cancellation) case
  logic [4:0]  lz_shared; 
  logic [26:0] Mnorm_shared;
  always_comb begin
    lz_shared    = lzc27(sum_sub[26:0]);
    Mnorm_shared = sum_sub[26:0] << lz_shared;
  end

  // Packing function, per operation
  function automatic logic [31:0] pack_result(
      input logic sub_flag 
  );
    logic Sbe, same_sign, Sbig, Ssmall, Sres; 
    logic [23:0] Mres; 
    logic signed [10:0] Eres_s; 
    logic force_zero, force_sat, sat_sign; 
    logic [26:0] sum_norm;
    logic g_bit, r_bit, s_bit, round_up;
    logic [24:0] Mres_rounded;

    begin
      Sbe       = Sb ^ sub_flag; 
      Sbig      = swap ? Sbe : Sa; 
      Ssmall    = swap ? Sa  : Sbe; 
      same_sign = (Sbig == Ssmall); 
      Sres      = Sbig; 

      Mres = 24'd0; Eres_s = 11'sd0; 
      force_zero = 1'b0; force_sat = 1'b0; sat_sign = Sres; 
      sum_norm = 27'd0;

      if (a_is_special || b_is_special) begin 
        if (a_is_special && b_is_special) begin 
          if (Sa != Sbe) force_zero = 1'b1; 
          else begin force_sat = 1'b1; sat_sign = Sa; end 
        end else if (a_is_special) begin force_sat = 1'b1; sat_sign = Sa; 
        end else begin force_sat = 1'b1; sat_sign = Sbe; 
        end
      end else if (same_sign) begin
        // Same-sign addition case
        if (sum_add[27]) begin
          sum_norm = sum_add[27:1];
          sum_norm[0] = sum_norm[0] | sum_add[0];
          Eres_s = $signed({1'b0, EL}) + 11'sd1;
        end else begin
          sum_norm = sum_add[26:0];
          Eres_s = $signed({1'b0, EL});
        end
      end else begin
        // Opposite-sign subtraction case
        if (sum_sub[26:0] == 27'd0) begin
          force_zero = 1'b1; 
          Sres = 1'b0; 
        end else begin
          sum_norm = Mnorm_shared; 
          Eres_s   = $signed({1'b0, EL}) - $signed({6'b0, lz_shared});
        end
      end

      // Round to Nearest Even (RNE)
      if (!force_zero && !force_sat && !(a_is_special || b_is_special)) begin
        g_bit    = sum_norm[2];
        r_bit    = sum_norm[1];
        s_bit    = sum_norm[0];
        round_up = g_bit & (sum_norm[3] | r_bit | s_bit);

        Mres_rounded = {1'b0, sum_norm[26:3]} + round_up;

        if (Mres_rounded[24]) begin
          Mres   = Mres_rounded[24:1];
          Eres_s = Eres_s + 11'sd1;
        end else begin
          Mres   = Mres_rounded[23:0];
        end
      end

      if (force_zero)   pack_result = 32'h0000_0000;
      else if (force_sat)  pack_result = {sat_sign, 8'd254, 23'h7fffff};
      else if ((Eres_s <= 11'sd0) || (Mres == 24'd0)) pack_result = 32'h0000_0000; 
      else if (Eres_s >= 11'sd255) pack_result = {Sres, 8'd254, 23'h7fffff}; 
      else pack_result = {Sres, Eres_s[7:0], Mres[22:0]}; 
    end
  endfunction

  logic [31:0] sum_c, diff_c;
  always_comb begin
    sum_c  = pack_result(1'b0); 
    diff_c = pack_result(1'b1); 
  end 

  always_ff @(posedge clk or negedge rst_n) begin 
    if (!rst_n) begin 
      sum_o  <= 32'd0; 
      diff_o <= 32'd0; 
    end else if (en) begin 
      sum_o  <= sum_c; 
      diff_o <= diff_c; 
    end
  end
endmodule
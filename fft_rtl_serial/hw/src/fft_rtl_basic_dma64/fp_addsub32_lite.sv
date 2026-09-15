module fp_addsub32_lite (
  input  logic        clk, 
  input  logic        rst_n, 
  input  logic        en,         // clock-enable 
  input  logic [31:0] a_i, 
  input  logic [31:0] b_i, 
  input  logic        sub_i,      // 0: res = a + b   1: res = a - b [cite: 50]
  output logic [31:0] res_o       // result, valid 1 cycle after inputs [cite: 50]
);
  logic Sa, Sb, Sbe; 
  logic [7:0] Ea, Eb, Eae, Ebe, EL, ES; 
  logic [23:0] Ma, Mb, ML, MS, Mres;
  logic swap, same_sign, Sres, Sbig, Ssmall;
  logic [7:0] ediff; 
  logic [4:0] shr_amt; 

  // Datapath étendu (27 bits: 24 mantisse + 3 bits GRS)
  logic [26:0] ML_ext, MS_ext, MSa_ext;
  logic sticky;
  logic [27:0] sum_ext;
  logic [26:0] sum_norm;
  logic [4:0]  lz;

  logic a_is_zero, b_is_zero; 
  logic a_is_special, b_is_special; 
  logic force_zero, force_sat; 
  logic sat_sign; 
  logic signed [10:0] Eres_s; 

  logic g_bit, r_bit, s_bit, round_up;
  logic [24:0] Mres_rounded;

  // Compteur de zéros sur 27 bits
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
    Sa  = a_i[31]; 
    Sb  = b_i[31]; 
    Sbe = Sb ^ sub_i; 
    Ea  = a_i[30:23]; 
    Eb  = b_i[30:23]; 
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
    Sbig      = swap ? Sbe : Sa; 
    Ssmall    = swap ? Sa  : Sbe; 
    same_sign = (Sbig == Ssmall); 
    Sres      = Sbig; 

    ediff   = EL - ES; 
    shr_amt = ediff[4:0];

    ML_ext = {ML, 3'b000};
    MS_ext = {MS, 3'b000};

    // Alignement des mantisses avec calcul exact du bit Sticky
    if (ediff >= 8'd27) begin
      MSa_ext = 27'd0;
      sticky  = |MS;
    end else begin
      MSa_ext = MS_ext >> shr_amt;
      sticky  = (shr_amt != 5'd0) ? |({5'b0, MS_ext} & ((32'd1 << shr_amt) - 32'd1)) : 1'b0;
    end
    MSa_ext[0] = MSa_ext[0] | sticky; // Injection du sticky bit dans la position LSB

    sum_ext = same_sign ? ({1'b0, ML_ext} + {1'b0, MSa_ext}) : ({1'b0, ML_ext} - {1'b0, MSa_ext});

    Mres = 24'd0; 
    Eres_s = 11'sd0; 
    force_zero = 1'b0; 
    force_sat = 1'b0;
    sat_sign = Sres; 
    sum_norm = 27'd0;

    if (a_is_special || b_is_special) begin 
      if (a_is_special && b_is_special) begin 
        if (Sa != Sbe) force_zero = 1'b1; 
        else begin force_sat = 1'b1; sat_sign = Sa; end
      end else if (a_is_special) begin force_sat = 1'b1; sat_sign = Sa; 
      end else begin force_sat = 1'b1; sat_sign = Sbe; 
      end
    end else if (same_sign && sum_ext[27]) begin
      // Débordement d'addition (carry) -> décalage de 1 bit à droite
      sum_norm = sum_ext[27:1];
      sum_norm[0] = sum_norm[0] | sum_ext[0]; // Conserve le bit sticky
      Eres_s = $signed({1'b0, EL}) + 11'sd1;
    end else if (same_sign) begin
      sum_norm = sum_ext[26:0];
      Eres_s = $signed({1'b0, EL});
    end else if (sum_ext[26:0] == 27'd0) begin
      force_zero = 1'b1;
      Sres = 1'b0;
    end else begin
      // Soustraction avec annulation -> normalisation via LZC
      lz       = lzc27(sum_ext[26:0]);
      sum_norm = sum_ext[26:0] << lz;
      Eres_s   = $signed({1'b0, EL}) - $signed({6'b0, lz});
    end

    // Arrondi RNE généralisé sur la mantisse normalisée
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
  end

  // Packing final 
  logic [31:0] res_c; 
  always_comb begin
    if (force_zero) begin 
      res_c = 32'h0000_0000; 
    end else if (force_sat) begin 
      res_c = {sat_sign, 8'd254, 23'h7fffff}; 
    end else if ((Eres_s <= 11'sd0) || (Mres == 24'd0)) begin 
      res_c = 32'h0000_0000; 
    end else if (Eres_s >= 11'sd255) begin 
      res_c = {Sres, 8'd254, 23'h7fffff}; 
    end else begin
      res_c = {Sres, Eres_s[7:0], Mres[22:0]}; 
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin 
    if (!rst_n)   res_o <= 32'd0; 
    else if (en)  res_o <= res_c; 
  end
endmodule
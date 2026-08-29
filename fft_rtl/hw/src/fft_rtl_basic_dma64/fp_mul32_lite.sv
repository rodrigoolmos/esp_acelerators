// =====================================================================
//  fp_mul32_lite -- lightweight IEEE-754 single-precision multiplier.
//  Latency: 1 cycle. Subnormals are flushed to zero; Inf/NaN inputs
//  saturate to the largest finite magnitude (this core never emits
//  Inf/NaN). The 24x24 mantissa product maps onto DSP48 blocks.
// =====================================================================
module fp_mul32_lite (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,          // clock-enable: output register updates only when en = 1
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  output logic [31:0] res_o        // result, valid one cycle after the inputs
);

  // Unpack + classification
  logic        Sa, Sb, Sres;
  logic [7:0]  Ea, Eb;
  logic [23:0] Ma, Mb;
  logic [47:0] P, Pn;
  logic [23:0] Mres;
  logic        a_is_zero, b_is_zero;
  logic        a_is_special, b_is_special;

  // Signed exponents to avoid wrap-around
  logic signed [10:0] Etmp_s;
  logic signed [10:0] Eres_s;
  logic               force_zero;
  logic               force_sat;

  // Round-to-nearest with guard bit
  logic round_bit;
  logic [24:0] Mres_rounded;
  assign round_bit = Pn[22];
  assign Mres_rounded = {1'b0, Pn[46:23]} + round_bit;

  always_comb begin
    Sa = a_i[31];
    Sb = b_i[31];
    Ea = a_i[30:23];
    Eb = b_i[30:23];
    Sres = Sa ^ Sb;

    // Flush subnormals to zero and detect special values
    a_is_zero    = (Ea == 8'd0);
    b_is_zero    = (Eb == 8'd0);
    a_is_special = (Ea == 8'hff);
    b_is_special = (Eb == 8'hff);

    // Only normal numbers enter the multiplier
    Ma = a_is_zero ? 24'd0 : {1'b1, a_i[22:0]};
    Mb = b_is_zero ? 24'd0 : {1'b1, b_i[22:0]};

    Etmp_s = 11'sd0;
    Eres_s = 11'sd0;
    P      = 48'd0;
    Pn     = 48'd0;
    Mres   = 24'd0;

    force_zero = 1'b0;
    force_sat  = 1'b0;

    // Special cases (never emit NaN/Inf): saturate to finite, or zero
    if (a_is_special || b_is_special) begin
      if (a_is_zero || b_is_zero) force_zero = 1'b1;  // 0 * X -> 0
      else                        force_sat  = 1'b1;  // inf/nan * finite -> largest finite magnitude
    end else if (a_is_zero || b_is_zero) begin
      force_zero = 1'b1;
    end else begin
      // Provisional exponent (signed): both operands normal
      Etmp_s = $signed({1'b0, Ea}) + $signed({1'b0, Eb}) - 11'sd127;

      // Mantissa product (range [1,4))
      P = Ma * Mb;

      // Normalization: [2,4) -> shift right by 1 and E+1
      if (P[47]) begin
        Pn     = {1'b0, P[47:1]};
        Eres_s = Etmp_s + 11'sd1;
      end else begin
        Pn     = P;
        Eres_s = Etmp_s;
      end

      // Normalized mantissa: 1.xxx + 23 fraction bits
      //Mres = Pn[46:23];
      if (Mres_rounded[24]) begin
        Mres   = Mres_rounded[24:1];
        Eres_s = Eres_s + 11'sd1;
      end else begin
        Mres   = Mres_rounded[23:0];
      end
    end
  end

  logic [31:0] res_c;
  always_comb begin
    if (force_zero) begin
      res_c = 32'h0000_0000;
    end else if (force_sat) begin
      res_c = {Sres, 8'd254, 23'h7fffff};
    end else if ((Eres_s <= 11'sd0) || (Mres == 24'd0)) begin
      res_c = 32'h0000_0000;
    end else if (Eres_s >= 11'sd255) begin
      res_c = {Sres, 8'd254, 23'h7fffff};
    end else begin
      res_c = {Sres, Eres_s[7:0], Mres[22:0]};
    end
  end

  // Output register: 1-cycle latency
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)   res_o <= 32'd0;
    else if (en)  res_o <= res_c;
  end
endmodule

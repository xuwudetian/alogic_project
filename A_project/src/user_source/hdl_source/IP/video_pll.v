// XGA: VCO=50/2*39=975 MHz; scene=/15, serial=/3, pixel=/15.
`timescale 1 ns / 100 fs

module video_pll (
  refclk,
  reset,
  clk0_out,
  clk1_out,
  clk2_out,
  locked
);

  input refclk;
  input reset;
  output clk0_out;
  output clk1_out;
  output clk2_out;
  output locked;

  wire clk0_buf;

  EG_LOGIC_BUFG bufg_feedback (
    .i(clk0_buf),
    .o(clk0_out) 
  );

  EG_PHY_PLL #(
    .DPHASE_SOURCE("DISABLE"),
    .DYNCFG("DISABLE"),
    .FIN("50.000000"),
    .FEEDBK_MODE("NOCOMP"),
    .FEEDBK_PATH("VCO_PHASE_0"),
    .STDBY_ENABLE("DISABLE"),
    .PLLRST_ENA("ENABLE"),
    .SYNC_ENABLE("DISABLE"),
    .GMC_GAIN(2),
    .ICP_CURRENT(9),
    .KVCO(2),
    .LPF_CAPACITOR(1),
    .LPF_RESISTOR(8),
    .REFCLK_DIV(2),
    .FBCLK_DIV(39),
    .CLKC0_ENABLE("ENABLE"),
    .CLKC0_DIV(15),
    .CLKC0_CPHASE(14),
    .CLKC0_FPHASE(0),
    .CLKC1_ENABLE("ENABLE"),
    .CLKC1_DIV(3),
    .CLKC1_CPHASE(2),
    .CLKC1_FPHASE(0),
    .CLKC2_ENABLE("ENABLE"),.CLKC2_DIV(15),.CLKC2_CPHASE(14),.CLKC2_FPHASE(0) 
  ) pll_inst (
    .refclk(refclk),
    .reset(reset),
    .stdby(1'b0),
    .extlock(locked),
    .load_reg(1'b0),
    .psclk(1'b0),
    .psdown(1'b0),
    .psstep(1'b0),
    .psclksel(3'b000),
    .psdone(open),
    .dclk(1'b0),
    .dcs(1'b0),
    .dwe(1'b0),
    .di(8'b00000000),
    .daddr(6'b000000),
    .do({open, open, open, open, open, open, open, open}),
    .fbclk(1'b0),
    .clkc({open, open, clk2_out, clk1_out, clk0_buf}) 
  );

endmodule


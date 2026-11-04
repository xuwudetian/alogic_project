`timescale 1ns/1ps
// EG4S20's 8 MiB package SDRAM is connected internally by this primitive.
// No package SDRAM signals are routed through top-level user I/O pins.
module preview_sdram_phy(
    input clk,input rst_n,input mem_forward_clk,input clock_enable,input initialized,input ras_n,input cas_n,input we_n,
    input [10:0] address,input [1:0] bank,
    input [31:0] data_out,input data_output_enable,output [31:0] data_in);
    // Forwarded 100 MHz clock leads clk by 2 ns to compensate SIP clock pads.
    // Commands have 8 ns nominal setup; return DQ has a 12 ns capture window.
    wire sdram_clk=mem_forward_clk;
    tri [31:0] dq;
    // Capture the previous SDRAM beat on the next rising edge (12 ns after
    // launch), then consume the register one edge later. READ_WAIT includes
    // both the delayed command acceptance and this input-register latency.
    reg [31:0] dq_capture;
    always @(posedge clk) dq_capture<=dq;
    assign dq=data_output_enable ? data_out : 32'bz;
    assign data_in=dq_capture;
`ifdef SIMULATION
    preview_sdram_model sdram(.clk(sdram_clk),.rst_n(rst_n),.ras_n(ras_n),.cas_n(cas_n),
        .we_n(we_n),.addr(address),.ba(bank),.dq(dq),.cs_n(1'b0),.dm(initialized?4'h0:4'hf),.cke(clock_enable));
`else
    EG_PHY_SDRAM_2M_32 sdram(.clk(sdram_clk),.ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),
        .addr(address),.ba(bank),.dq(dq),.cs_n(1'b0),.dm0(!initialized),.dm1(!initialized),
        .dm2(!initialized),.dm3(!initialized),.cke(clock_enable));
`endif
endmodule

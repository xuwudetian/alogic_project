`timescale 1ns/1ps
// Two 160x120x8 frames packed into 19200x16 words: exactly ten M32K.
// Writes and reads use independent clocks. One-edge synchronous read latency.
module video_frame_ram #(
    parameter WORDS=19200,parameter BANKS=10
)(
    input write_clk,input write_enable,input [14:0] write_address,input [15:0] write_data,
    input read_clk,input read_enable,input [14:0] read_address,output [15:0] read_data);
`ifdef SIMULATION
    reg [15:0] mem[0:WORDS-1];
    reg [15:0] dout;
    always @(posedge write_clk) if(write_enable && write_address<WORDS)
        mem[write_address]<=write_data;
    always @(posedge read_clk) if(read_enable && read_address<WORDS)
        dout<=mem[read_address];
    assign read_data=dout;
`else
    wire [15:0] bank_data[0:BANKS-1];
    reg [3:0] read_bank_q;
    always @(posedge read_clk) if(read_enable) read_bank_q<=read_address[14:11];
    assign read_data=bank_data[read_bank_q];
    genvar b;
    generate for(b=0;b<BANKS;b=b+1) begin: banks
        EG_PHY_BRAM32K #(
            .MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
            .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
            .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.SRMODE("SYNC")
        ) ram (
            .doa(),.dia(write_data),.addra(write_address[10:0]),
            .bytea(1'b0),.bytewea(1'b0),
            .csa(write_enable && write_address[14:11]==b),.wea(1'b1),
            .clka(write_clk),.rsta(1'b0),.ocea(1'b1),
            .dob(bank_data[b]),.dib(16'd0),.addrb(read_address[10:0]),
            .byteb(1'b0),.byteweb(1'b0),
            .csb(read_enable && read_address[14:11]==b),.web(1'b0),
            .clkb(read_clk),.rstb(1'b0),.oceb(1'b1)
        );
    end endgenerate
`endif
endmodule

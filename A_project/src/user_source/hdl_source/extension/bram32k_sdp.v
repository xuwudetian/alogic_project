`timescale 1ns/1ps
// EG4 independent-clock simple dual-port storage, built from real 32 Kbit RAMs.
// TN308 section 3.2: each block supports 2048 x 16, independent A/B clocks.
// NOREG disables the OPTIONAL extra output register: reads still take one
// rising read-clock edge. The bank select is delayed by exactly that edge.
// Contents are not reset. Callers publish a slot/row only after writing it;
// simultaneous access to the same word across clocks must be avoided.
module bram32k_sdp #(
    parameter integer DEPTH=2048,
    parameter integer ADDR_BITS=$clog2(DEPTH)
)(
    input write_clk,input write_enable,input [ADDR_BITS-1:0] write_address,
    input [15:0] write_data,
    input read_clk,input read_enable,input [ADDR_BITS-1:0] read_address,
    output [15:0] read_data
);
    localparam integer BANKS=(DEPTH+2047)/2048;
    localparam integer BANK_BITS=BANKS>1 ? $clog2(BANKS) : 1;
    wire [10:0] write_word=write_address;
    wire [10:0] read_word=read_address;
    wire [BANK_BITS-1:0] write_bank=write_address>>11;
    wire [BANK_BITS-1:0] read_bank=read_address>>11;
    wire write_valid=write_enable && write_address<DEPTH;
    wire read_valid=read_enable && read_address<DEPTH;
    wire [15:0] bank_data[0:BANKS-1];
    reg [BANK_BITS-1:0] bank_q;
    always @(posedge read_clk) if(read_valid) bank_q<=read_bank;
    assign read_data=bank_data[bank_q];

    genvar b;
    generate for(b=0;b<BANKS;b=b+1) begin: banks
        EG_LOGIC_BRAM #(
            .DATA_WIDTH_A(16),.DATA_WIDTH_B(16),
            .ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
            .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),
            .BYTE_ENABLE(0),.BYTE_A(1),.BYTE_B(1),.MODE("DP"),
            .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
            .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
            .RESETMODE("SYNC"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
            .INIT_FILE("NONE"),.FILL_ALL("NONE"),.IMPLEMENT("32K")
        ) ram (
            .doa(),.dob(bank_data[b]),.dia(write_data),.dib(16'd0),
            .cea(write_valid && write_bank==b),.ocea(1'b1),
            .clka(write_clk),.wea(1'b1),.rsta(1'b0),
            .ceb(read_valid && read_bank==b),.oceb(1'b1),
            .clkb(read_clk),.web(1'b0),.rstb(1'b0),
            .bea(1'b1),.beb(1'b1),.addra(write_word),.addrb(read_word)
        );
    end endgenerate
endmodule

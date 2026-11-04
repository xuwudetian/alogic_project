`timescale 1ns/1ps
module tb_rgb332_contention;
    reg mc=0,wc=0,pc=0,rst=1,wreq=0,rreq=0,we=0,re=0,produce=0;
    reg [7:0] din=0;
    wire wa,ra,done,ready,overflow,underflow,mw,mr;
    wire [20:0] waddr,raddr;
    wire [31:0] wd;
    wire [7:0] pixel;
    reg [7:0] rv=0;
    reg [31:0] rd[0:7];
    reg [8:0] cycle=0;
    integer sent=0,stored=0,stalls=0,i,p;
    always #12.5 mc=~mc;
    always #10 wc=~wc;
    always #7.6923075 pc=~pc;
    function [7:0] color(input integer index);
        color=(index*13)^(index>>3);
    endfunction
    function [31:0] word_at(input integer index);
        word_at={color(index*4),color(index*4+1),color(index*4+2),color(index*4+3)};
    endfunction
    frame_read_write #(.READ_DATA_BITS(8),.WRITE_DATA_BITS(8),.BURST_SIZE(128),.FRAME_WIDTH(1024),.FRAME_HEIGHT(4)) dut(
        .rst(rst),.mem_clk(mc),.Sdr_init_done(!rst),.Sdr_init_ref_vld(cycle<12),.Sdr_busy(1'b0),
        .App_rd_en(mr),.App_rd_addr(raddr),.Sdr_rd_en(rv[7]),.Sdr_rd_dout(rd[7]),
        .read_clk(pc),.read_req(rreq),.read_req_ack(ra),.read_finish(),
        .read_addr_0(21'd0),.read_addr_1(21'd1024),.read_addr_2(21'd2048),
        .read_addr_3(21'd3072),.read_addr_4(21'd4096),.read_addr_5(21'd5120),
        .read_addr_6(21'd6144),.read_addr_7(21'd7168),.read_addr_8(21'd8192),
        .read_addr_index(4'd7),.read_len(21'd1024),.read_en(re),.read_data(pixel),
        .App_wr_en(mw),.App_wr_addr(waddr),.App_wr_din(wd),.App_wr_dm(),
        .write_clk(wc),.write_req(wreq),.write_req_ack(wa),.write_finish(done),
        .write_addr_0(21'd0),.write_addr_1(21'd1024),.write_addr_2(21'd2048),
        .write_addr_3(21'd3072),.write_addr_4(21'd4096),.write_addr_5(21'd5120),
        .write_addr_6(21'd6144),.write_addr_7(21'd7168),.write_addr_8(21'd8192),
        .write_addr_index(4'd8),.write_len(21'd1024),.write_en(we),.write_data(din),
        .write_v_flip(1'b0),.write_overflow(overflow),.read_underflow(underflow),.write_ready(ready),
        .slide_active(1'b0),.slide_offset(20'd0),.slide_bank(4'd0));
    always @(posedge mc) begin
        if(rst) begin rv<=0;cycle<=0;end
        else begin rv<={rv[6:0],mr};cycle<=cycle+1'b1;end
        if(mr) rd[0]<=word_at(raddr-7168);
        for(i=1;i<8;i=i+1) rd[i]<=rd[i-1];
        if(!rst && mw && mr) $fatal(1,"packed concurrent bus collision");
        if(!rst && mw) begin
            if(waddr!==8192+stored || wd!==word_at(stored)) $fatal(1,"packed concurrent write mismatch %0d",stored);
            stored=stored+1;
        end
    end
    always @(negedge wc) begin
        we=0;
        if(!rst && produce && sent<4096) begin
            if(ready) begin we=1;din=color(sent);sent=sent+1;end
            else stalls=stalls+1;
        end
    end
    initial begin
        repeat(8) @(negedge pc);rst=0;
        repeat(8) @(negedge pc);wreq=1;rreq=1;
        wait(wa && ra);@(negedge pc);wreq=0;rreq=0;
        wait(!wa && !ra);produce=1;
        repeat(550) @(negedge pc);
        for(p=0;p<4096;p=p+1) begin
            @(negedge pc);re=1;@(posedge pc);#1;
            if(pixel!==color(p) || underflow || overflow) $fatal(1,"packed concurrent raster pixel%0d got%h expected%h",p,pixel,color(p));
        end
        @(negedge pc);re=0;wait(stored==1024);repeat(20) @(negedge pc);
        if(stalls==0 || overflow || underflow) $fatal(1,"packed contention did not exercise safe backpressure");
        $display("PASS packed contention: simultaneous RGB332 50MHz producer / 65MHz display, independent clocks, refresh, bank7 read/bank8 write, stalled producer, no overflow/underflow");
        $finish;
    end
    initial begin #1000000;$fatal(1,"packed contention timeout sent%0d stored%0d",sent,stored);end
endmodule

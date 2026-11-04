`timescale 1ns/1ps
// Full rasters through real RGB565 FIFOs/controller/filter. Memory expectations
// are computed independently with integer coordinate ratios, including bank8.
module tb_hdmi576_frame;
    reg mc=0,pc=0,wc=0,rst=1,request=0,re=0,zoom=1,sliding=0;
    reg [9:0] width=640,height=480,left=40,top=32;
    reg [3:0] bank=8,next_bank=0;
    reg [18:0] slide_pixels=0;
    wire ack,mr,mw,underflow;wire [20:0] address;wire [15:0] pixel;
    reg [7:0] valid_pipe=0;reg [31:0] data_pipe[0:7];reg [9:0] memory_cycle=0;
    integer n,x,y,j,reads=0,expected_address,msy,mbank,msource;
    integer checked=0,inside_checked=0,sx,sy,source_y,source_bank;
    reg [15:0] expected;
    always #12.5 mc=~mc;always #18.5185 pc=~pc;always #10 wc=~wc;
    function [15:0] color(input integer id,input integer xx,input integer yy);
        color=(((xx^id*29)&255)/8)*2048+(((yy+id*17)&255)/4)*32+(((xx+yy*3+id*11)&255)/8);
    endfunction
    function [31:0] memory_word(input integer addr);
        integer idx,id;
        begin id=addr/207360;idx=(addr%207360)*2;
            memory_word={color(id,idx%720,idx/720),color(id,(idx+1)%720,(idx+1)/720)};
        end
    endfunction
    frame_read_write #(.READ_DATA_BITS(16),.WRITE_DATA_BITS(16),.FRAME_WIDTH(720),.FRAME_HEIGHT(576),
      .BURST_SIZE(128),.SLIDE_ENABLE(1),.ZOOM_ENABLE(1),.EXPLICIT_ZOOM(1)) dut(
      .rst(rst),.mem_clk(mc),.Sdr_init_done(!rst),.Sdr_init_ref_vld(memory_cycle<12),.Sdr_busy(memory_cycle>=1010),
      .App_rd_en(mr),.App_rd_addr(address),.Sdr_rd_en(valid_pipe[7]),.Sdr_rd_dout(data_pipe[7]),
      .read_clk(pc),.read_req(request),.read_req_ack(ack),.read_finish(),
      .read_addr_0(21'd0),.read_addr_1(21'd207360),.read_addr_2(21'd414720),.read_addr_3(21'd622080),
      .read_addr_4(21'd829440),.read_addr_5(21'd1036800),.read_addr_6(21'd1244160),.read_addr_7(21'd1451520),.read_addr_8(21'd1658880),
      .read_addr_index(bank),.read_len(21'd207360),.read_en(re),.read_data(pixel),
      .App_wr_en(mw),.App_wr_addr(),.App_wr_din(),.App_wr_dm(),.write_clk(wc),.write_req(1'b0),.write_req_ack(),.write_finish(),
      .write_addr_0(21'd0),.write_addr_1(21'd207360),.write_addr_2(21'd414720),.write_addr_3(21'd622080),
      .write_addr_4(21'd829440),.write_addr_5(21'd1036800),.write_addr_6(21'd1244160),.write_addr_7(21'd1451520),.write_addr_8(21'd1658880),
      .write_addr_index(4'd0),.write_len(21'd207360),.write_en(1'b0),.write_data(16'd0),.write_v_flip(1'b0),
      .write_overflow(),.read_underflow(underflow),.write_ready(),
      .slide_active(sliding),.slide_offset(slide_pixels),.slide_bank(next_bank),
      .zoom_active(zoom),.zoom_size(8'd160),.zoom_left(left),.zoom_top(top),.zoom_width(width),.zoom_height(height));
    always @(posedge mc) begin
        if(rst) begin valid_pipe<=0;memory_cycle<=0;end
        else begin valid_pipe<={valid_pipe[6:0],mr};memory_cycle<=memory_cycle+1'b1;end
        if(mr) begin
            data_pipe[0]<=memory_word(address);
            msy=zoom ? ((reads/360)*576+height-1)/height : reads/360;
            msource=msy+(sliding ? slide_pixels/720 : 0);mbank=msource>=576 ? next_bank : bank;
            expected_address=mbank*207360+(msource%576)*360+reads%360;
            if(address!==expected_address || address>=1866240)
                $fatal(1,"source address frame%0d word%0d @%0d expected%0d",n,reads,address,expected_address);
            reads=reads+1;
        end
        for(j=1;j<8;j=j+1) data_pipe[j]<=data_pipe[j-1];
    end
    initial begin
        repeat(8) @(negedge pc);rst=0;
        for(n=0;n<5;n=n+1) begin
            @(negedge pc);re=0;zoom=n!=4;bank=n==0 ? 8 : n;next_bank=8;
            width=n==0 ? 640 : n==1 ? 680 : n==2 ? 716 : 720;
            height=n==0 ? 480 : n==1 ? 528 : n==2 ? 571 : 576;
            left=(720-width)/2;top=n==0 ? 32 : n==1 ? 16 : n==2 ? 1 : 0;
            sliding=n!=0;slide_pixels=n==1 ? 720*24 : n==2 ? 720*552 : n==3 ? 720*288 : 720;
            repeat(20) @(negedge pc);reads=0;request=1;wait(ack);@(negedge pc);request=0;wait(!ack);
            repeat(2000) @(negedge pc);
            for(y=0;y<576;y=y+1) begin
                for(x=0;x<720;x=x+1) begin
                    @(negedge pc);re=1;@(posedge pc);#1;
                    if(underflow) $fatal(1,"underflow frame%0d xy%0d,%0d",n,x,y);
                    if(!zoom || (x>=left && x<left+width && y>=top && y<top+height)) begin
                        sx=zoom ? ((x-left)*720+width-1)/width : x;
                        sy=zoom ? ((y-top)*576+height-1)/height : y;
                        source_y=sy+(sliding ? slide_pixels/720 : 0);source_bank=source_y>=576 ? next_bank : bank;
                        expected=color(source_bank,sx,source_y%576);
                        if(pixel!==expected) $fatal(1,"pixel frame%0d xy%0d,%0d got%h expected%h source%0d,%0d bank%0d",n,x,y,pixel,expected,sx,source_y%576,source_bank);
                        inside_checked=inside_checked+1;
                    end
                    checked=checked+1;
                end
                @(negedge pc);re=0;repeat(143) @(negedge pc);
            end
            if(underflow || reads!=(zoom ? height*360 : 207360)) $fatal(1,"frame read count frame%0d got%0d expected%0d",n,reads,zoom ? height*360 : 207360);
            $display("verified native frame%0d %0dx%0d zoom%b slide_pixels%0d reads%0d",n,width,height,zoom,slide_pixels,reads);
        end
        if(checked!=5*414720) $fatal(1,"raster pixel total");
        $display("PASS 576 RGB565 reader: 5 native720x576 rasters;640/680/716/720 widths; banks0..8, selected rows, slide seams, max bank,27MHz display,40MHz memory,refresh,busy,FIFO,zero underflow; %0d active image pixels",inside_checked);$finish;
    end
    initial begin #140000000;$fatal(1,"native frame timeout");end
endmodule

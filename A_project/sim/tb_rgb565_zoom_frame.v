`timescale 1ns/1ps
// Actual frame controllers, RGB565 pack/unpack and asynchronous FIFOs. The
// memory and pixel expectations are computed independently from integer ratios.
module tb_rgb565_zoom_frame #(parameter integer FIRST=0,parameter integer LAST=4);
    reg mclk=0,pclk=0,wclk=0,rst=1,request=0,re=0;
    reg zoom=1;
    reg sliding=0;reg [18:0] slide_pixels=0;reg [3:0] next_bank=0;integer source_y,source_bank;
    reg [7:0] size=40;
    reg [9:0] left=424;
    reg [8:0] top=336;
    reg [3:0] bank=8;
    reg [2:0] dim=4;
    reg [1:0] border=0;
    wire ack,mr,mw,underflow;
    wire [20:0] address;
    wire [15:0] pixel;
    wire [23:0] expanded={pixel[15:11],pixel[15:13],pixel[10:5],pixel[10:9],pixel[4:0],pixel[4:2]};
    wire read_enable,vhs,vvs,vde,oh,ov,od;
    wire [23:0] raw_rgb,scene_rgb;
    reg frame_vs=1,previous_de=0;
    integer dx=0,dy=0,lx,ly,col,row,idx,ox,oy,amount,shade;
    reg [22:0] de_pipe=0,vs_pipe=0;
    reg [7:0] valid_pipe=0;
    reg [31:0] data_pipe[0:7];
    reg [9:0] memory_cycle=0;
    integer n,x,y,j,reads=0,expected_address,sy,sx,checked=0;
    reg [23:0] expected;
    always #12.5 mclk=~mclk;
    always #20 pclk=~pclk;
    always #10 wclk=~wclk;
    function [15:0] packed_color(input integer id,input integer xx,input integer yy);
        packed_color=(((xx^id*29)&255)/8)*2048+(((yy+id*17)&255)/4)*32+(((xx+yy*3+id*11)&255)/8);
    endfunction
    function [23:0] color(input integer id,input integer xx,input integer yy);
        integer r,g,b;
        begin
            r=((xx^id*29)&255)/8;g=((yy+id*17)&255)/4;b=((xx+yy*3+id*11)&255)/8;
            color={8'(r*8+r/4),8'(g*4+g/16),8'(b*8+b/4)};
        end
    endfunction
    function [31:0] memory_word(input integer addr);
        integer idx,id;
        begin
            id=addr/153600;idx=(addr%153600)*2;
            memory_word={packed_color(id,idx%640,idx/640),packed_color(id,(idx+1)%640,(idx+1)/640)};
        end
    endfunction
    frame_read_write #(.READ_DATA_BITS(16),.WRITE_DATA_BITS(16),.BURST_SIZE(128),.SLIDE_ENABLE(1),.ZOOM_ENABLE(1)) dut(
        .rst(rst),.mem_clk(mclk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(memory_cycle<12),.Sdr_busy(memory_cycle>=1010),
        .App_rd_en(mr),.App_rd_addr(address),.Sdr_rd_en(valid_pipe[7]),.Sdr_rd_dout(data_pipe[7]),
        .read_clk(pclk),.read_req(request),.read_req_ack(ack),.read_finish(),
        .read_addr_0(21'd0),.read_addr_1(21'd153600),.read_addr_2(21'd307200),
        .read_addr_3(21'd460800),.read_addr_4(21'd614400),.read_addr_5(21'd768000),
        .read_addr_6(21'd921600),.read_addr_7(21'd1075200),.read_addr_8(21'd1228800),
        .read_addr_index(bank),.read_len(21'd153600),.read_en(read_enable),.read_data(pixel),
        .App_wr_en(mw),.App_wr_addr(),.App_wr_din(),.App_wr_dm(),
        .write_clk(wclk),.write_req(1'b0),.write_req_ack(),.write_finish(),
        .write_addr_0(21'd0),.write_addr_1(21'd153600),.write_addr_2(21'd307200),
        .write_addr_3(21'd460800),.write_addr_4(21'd614400),.write_addr_5(21'd768000),
        .write_addr_6(21'd921600),.write_addr_7(21'd1075200),.write_addr_8(21'd1228800),
        .write_addr_index(4'd0),.write_len(21'd153600),.write_en(1'b0),.write_data(16'd0),
        .write_v_flip(1'b0),.write_overflow(),.read_underflow(underflow),.write_ready(),
        .slide_active(sliding),.slide_offset(slide_pixels),.slide_bank(next_bank),
        .zoom_active(zoom),.zoom_size(size),.zoom_left(left),.zoom_top(top));
    video_delay delay(.video_clk(pclk),.rst(rst),.read_en(read_enable),.read_data(expanded),
        .hs(1'b1),.vs(frame_vs),.de(re),.hs_r(vhs),.vs_r(vvs),.de_r(vde),.vout_data(raw_rgb));
    thumbnail_scene scene(.write_clk(wclk),.write_enable(1'b0),.write_slot(4'd0),
        .pixel_x(16'd0),.pixel_y(16'd0),.pixel_rgb(24'd0),
        .clk(pclk),.rst(rst),.hs(vhs),.vs(vvs),.de(vde),.rgb(raw_rgb),
        .browse(1'b0),.focus(bank),.ready(9'd0),.available(9'd0),.failed(9'd0),
        .active(zoom),.moving(zoom),.target(bank),.left(left),.top(top),.size(size),
        .border_size(border),.dim(dim),.out_hs(oh),.out_vs(ov),.out_de(od),.out_rgb(scene_rgb));
    always @(posedge pclk) begin
        de_pipe<={de_pipe[21:0],re};vs_pipe<={vs_pipe[21:0],frame_vs};
        #2;
        if(rst || request) begin dx=0;dy=0;previous_de=0;end
        else begin
            if(od) begin
                if(!zoom || (dx>=left && dx<left+size*4 && dy>=top && dy<top+size*3)) begin
                    sx=zoom ? ((dx-left)*640+size*4-1)/(size*4) : dx;
                    sy=zoom ? ((dy-top)*480+size*3-1)/(size*3) : dy;
                    source_y=sy+(sliding ? slide_pixels/640 : 0);
                    source_bank=source_y>=480 ? next_bank : bank;
                    expected=color(source_bank,sx,source_y%480);
                    if(zoom && border!=0 && (dx-left<border || dx-left>=size*4-border || dy-top<border || dy-top>=size*3-border)) expected=24'hffd050;
                end else begin
                    expected=24'h182024;
                    col=dx>=424 ? 2 : dx>=240 ? 1 : 0;
                    row=dy>=336 ? 2 : dy>=192 ? 1 : 0;
                    lx=dx-(56+col*184);ly=dy-(48+row*144);idx=row*3+col;
                    if(lx>=0 && lx<160 && ly>=0 && ly<120 && idx!=bank) begin
                        expected=24'h282c30;
                        if(lx<3 || lx>=157 || ly<3 || ly>=117) expected=24'h849498;
                    end
                    amount=dim==1 ? 224 : dim==2 ? 192 : dim==3 ? 160 : dim==4 ? 128 : 256;
                    if(dx>=left+5 && dx<left+5+size*4 && dy>=top+6 && dy<top+6+size*3) amount=amount/4;
                    expected={8'((expected[23:16]*amount)/256),8'((expected[15:8]*amount)/256),8'((expected[7:0]*amount)/256)};
                end
                if(scene_rgb!==expected || underflow)
                    $fatal(1,"zoom raster size%0d (%0d,%0d) got%h expected%h underflow%b read%0d",size,dx,dy,scene_rgb,expected,underflow,reads);
                checked=checked+1;
                dx=dx+1;
            end else begin dx=0;if(previous_de) dy=dy+1;end
            if((od || previous_de) && (od!==de_pipe[22] || ov!==vs_pipe[22] || oh!==1))
                $fatal(1,"zoom video sync lost alignment");
            previous_de=od;
        end
    end
    always @(posedge mclk) begin
        if(rst) begin valid_pipe<=0;memory_cycle<=0;end
        else begin valid_pipe<={valid_pipe[6:0],mr};memory_cycle<=memory_cycle+1'b1;end
        if(mr) begin
            data_pipe[0]<=memory_word(address);
            sy=zoom ? ((reads/320)*480+size*3-1)/(size*3) : reads/320;
            source_y=sy+(sliding ? slide_pixels/640 : 0);
            source_bank=source_y>=480 ? next_bank : bank;
            expected_address=source_bank*153600+(source_y%480)*320+reads%320;
            if(address!==expected_address || address>=1382400)
                $fatal(1,"source address size%0d word%0d @%0d expected%0d",size,reads,address,expected_address);
            reads=reads+1;
        end
        for(j=1;j<8;j=j+1) data_pipe[j]<=data_pipe[j-1];
    end
    initial begin
        repeat(8) @(negedge pclk);rst=0;
        for(n=FIRST;n<=LAST;n=n+1) begin
            @(negedge pclk);re=0;size=n==0 ? 136 : n==1 ? 144 : n==2 ? 148 : n==3 ? 159 : 160;zoom=1;bank=(n%9);next_bank=8;sliding=n>0 && n<4;
            slide_pixels=n==1 ? 10240 : n==2 ? 153600 : n==3 ? 296960 : 0;
            dim=0;border=0;left=320-size*2;top=n==0 ? 32 : n==1 ? 22 : n==2 ? 16 : n==3 ? 1 : 0;
            repeat(20) @(negedge pclk);reads=0;request=1;frame_vs=0;
            wait(ack);@(negedge pclk);request=0;wait(!ack);repeat(100) @(negedge pclk);frame_vs=1;
            repeat(1900) @(negedge pclk);
            for(y=0;y<480;y=y+1) begin
                for(x=0;x<640;x=x+1) begin
                    @(negedge pclk);re=1;
                end
                @(negedge pclk);re=0;repeat(159) @(negedge pclk);
            end
            if(underflow || reads!=(zoom ? size*3*320 : 153600)) $fatal(1,"frame size/count size%0d reads%0d",size,reads);
            $display("frame %0d size%0d bank%0d verified",n,size,bank);
        end
        if(checked!=(LAST-FIRST+1)*307200) $fatal(1,"raster pixel total %0d",checked);
        $display("PASS SW1 zoom frame: sizes 136/144/148/159/160 (full 640x480) and source-coordinate slides at 16/240/464 rows; rasters %0d..%0d, exact SDRAM addresses, RGB565 pixels, grid dimming/shadow/borders, synchronized video, FIFO/refresh/backpressure, no underflow (%0d pixels)",FIRST,LAST,checked);$finish;
    end
    initial begin #400000000;$fatal(1,"zoom frame timeout");end
    initial begin
        #100000;$display("zoom raster progress: time%0t frame%0d xy%0d,%0d reads%0d reader_state%0d",$time,n,x,y,reads,dut.frame_fifo_read_m0.state);
        #900000;$display("zoom raster progress: time%0t frame%0d xy%0d,%0d reads%0d reader_state%0d",$time,n,x,y,reads,dut.frame_fifo_read_m0.state);
    end
endmodule

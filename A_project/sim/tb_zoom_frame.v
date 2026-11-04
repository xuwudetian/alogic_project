`timescale 1ns/1ps
// Actual frame controllers, RGB888 pack/unpack and asynchronous FIFOs. The
// memory and pixel expectations are computed independently from integer ratios.
module tb_zoom_frame #(parameter integer FIRST=0,parameter integer LAST=16);
    reg mclk=0,pclk=0,wclk=0,rst=1,request=0,re=0;
    reg zoom=1;
    reg [7:0] size=40;
    reg [9:0] left=424;
    reg [8:0] top=336;
    reg [3:0] bank=8;
    reg [2:0] dim=4;
    reg [1:0] border=0;
    wire ack,mr,mw,underflow;
    wire [20:0] address;
    wire [23:0] pixel;
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
    function [23:0] color(input integer id,input integer xx,input integer yy);
        color={8'(xx^id*29),8'(yy+id*17),8'(xx+yy*3+id*11)};
    endfunction
    function [31:0] memory_word(input integer addr);
        integer k,b,idx,id;reg [23:0] c;
        begin
            id=addr/230400;idx=addr%230400;memory_word=0;
            for(k=0;k<4;k=k+1) begin
                b=idx*4+k;c=color(id,(b/3)%640,(b/3)/640);
                memory_word[31-k*8 -: 8]=c>>(8*(2-b%3));
            end
        end
    endfunction
    frame_read_write #(.READ_DATA_BITS(24),.WRITE_DATA_BITS(24),.BURST_SIZE(128),.SLIDE_ENABLE(1),.ZOOM_ENABLE(1)) dut(
        .rst(rst),.mem_clk(mclk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(memory_cycle<12),.Sdr_busy(memory_cycle>=1010),
        .App_rd_en(mr),.App_rd_addr(address),.Sdr_rd_en(valid_pipe[7]),.Sdr_rd_dout(data_pipe[7]),
        .read_clk(pclk),.read_req(request),.read_req_ack(ack),.read_finish(),
        .read_addr_0(21'd0),.read_addr_1(21'd230400),.read_addr_2(21'd460800),
        .read_addr_3(21'd691200),.read_addr_4(21'd921600),.read_addr_5(21'd1152000),
        .read_addr_6(21'd1382400),.read_addr_7(21'd1612800),.read_addr_8(21'd1843200),
        .read_addr_index(bank),.read_len(21'd230400),.read_en(read_enable),.read_data(pixel),
        .App_wr_en(mw),.App_wr_addr(),.App_wr_din(),.App_wr_dm(),
        .write_clk(wclk),.write_req(1'b0),.write_req_ack(),.write_finish(),
        .write_addr_0(21'd0),.write_addr_1(21'd230400),.write_addr_2(21'd460800),
        .write_addr_3(21'd691200),.write_addr_4(21'd921600),.write_addr_5(21'd1152000),
        .write_addr_6(21'd1382400),.write_addr_7(21'd1612800),.write_addr_8(21'd1843200),
        .write_addr_index(4'd0),.write_len(21'd230400),.write_en(1'b0),.write_data(24'd0),
        .write_v_flip(1'b0),.write_overflow(),.read_underflow(underflow),.write_ready(),
        .slide_active(1'b0),.slide_offset(19'd0),.slide_bank(4'd0),
        .zoom_active(zoom),.zoom_size(size),.zoom_left(left),.zoom_top(top));
    video_delay delay(.video_clk(pclk),.rst(rst),.read_en(read_enable),.read_data(pixel),
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
                    expected=color(bank,sx,sy);
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
            sy=zoom ? ((reads/480)*480+size*3-1)/(size*3) : reads/480;
            expected_address=bank*230400+sy*480+reads%480;
            if(address!==expected_address || address>=2073600)
                $fatal(1,"source address size%0d word%0d @%0d expected%0d",size,reads,address,expected_address);
            reads=reads+1;
        end
        for(j=1;j<8;j=j+1) data_pipe[j]<=data_pipe[j-1];
    end
    function integer test_size(input integer idx);
        case(idx)
            0:test_size=40;1:test_size=41;2:test_size=63;3:test_size=83;4:test_size=99;
            5:test_size=113;6:test_size=125;7:test_size=134;8:test_size=142;9:test_size=148;
            10:test_size=152;11:test_size=156;12:test_size=158;13:test_size=159;default:test_size=160;
        endcase
    endfunction
    initial begin
        repeat(8) @(negedge pclk);rst=0;
        for(n=FIRST;n<=LAST;n=n+1) begin
            @(negedge pclk);re=0;size=test_size(n);zoom=n!=16;bank=(n%9);
            dim=n<4 ? n : 4;border=n<3 ? 3 : n<13 ? 2 : n<14 ? 1 : 0;
            // Place each size against an edge to catch count/crop errors.
            left=(n%3==0 ? 640-size*4 : n%3==1 ? (640-size*4)/2 : 0);
            top=(n%3==0 ? 480-size*3 : n%3==1 ? (480-size*3)/2 : 0);
            if(!zoom) begin left=0;top=0;end
            repeat(20) @(negedge pclk);reads=0;request=1;frame_vs=0;
            wait(ack);@(negedge pclk);request=0;wait(!ack);repeat(100) @(negedge pclk);frame_vs=1;
            repeat(1900) @(negedge pclk);
            for(y=0;y<480;y=y+1) begin
                for(x=0;x<640;x=x+1) begin
                    @(negedge pclk);re=1;
                end
                @(negedge pclk);re=0;repeat(159) @(negedge pclk);
            end
            if(underflow || reads!=(zoom ? size*3*480 : 230400)) $fatal(1,"frame size/count size%0d reads%0d",size,reads);
            $display("frame %0d size%0d bank%0d verified",n,size,bank);
        end
        if(checked!=(LAST-FIRST+1)*307200) $fatal(1,"raster pixel total %0d",checked);
        $display("PASS zoom frame: rasters %0d..%0d, exact SDRAM addresses, RGB888 pixels, grid dimming/shadow/borders, synchronized video, FIFO/refresh/backpressure, no underflow (%0d pixels)",FIRST,LAST,checked);$finish;
    end
    initial begin #400000000;$fatal(1,"zoom frame timeout");end
    initial begin
        #100000;$display("zoom raster progress: time%0t frame%0d xy%0d,%0d reads%0d reader_state%0d",$time,n,x,y,reads,dut.frame_fifo_read_m0.state);
        #900000;$display("zoom raster progress: time%0t frame%0d xy%0d,%0d reads%0d reader_state%0d",$time,n,x,y,reads,dut.frame_fifo_read_m0.state);
    end
endmodule

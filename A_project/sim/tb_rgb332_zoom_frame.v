`timescale 1ns/1ps
module tb_rgb332_zoom_frame;
    reg mc=0,pc=0,rst=1,req=0,re=0,slide=0;
    reg [10:0] width=256,height=192,left=90,top=538;
    reg [19:0] offset=0;
    wire ack,mr,under;
    wire [20:0] addr;
    wire [7:0] pixel;
    reg [7:0] vp=0;
    reg [31:0] data[0:7];
    reg [9:0] cycles=0;
    integer i,x,y,n,sx,sy,bank,idx,checked=0,reads=0;
    reg [7:0] expected;
    always #12.5 mc=~mc;
    always #7.6923075 pc=~pc;
    function [7:0] color(input integer b,input integer xx,input integer yy);
        color=(xx*17)^(yy*5)^(b*43);
    endfunction
    function [31:0] word_at(input integer a);
        integer b,j;
        begin b=a/196608;j=(a%196608)*4;
            word_at={color(b,j%1024,j/1024),color(b,(j+1)%1024,j/1024),color(b,(j+2)%1024,j/1024),color(b,(j+3)%1024,j/1024)};
        end
    endfunction
    frame_read_write #(.FRAME_WIDTH(1024),.FRAME_HEIGHT(768),.READ_DATA_BITS(8),.WRITE_DATA_BITS(8),
        .BURST_SIZE(128),.ZOOM_ENABLE(1),.EXPLICIT_ZOOM(1),.SLIDE_ENABLE(1)) dut(
        .rst(rst),.mem_clk(mc),.Sdr_init_done(!rst),.Sdr_init_ref_vld(cycles<12),.Sdr_busy(cycles>=1010),
        .App_rd_en(mr),.App_rd_addr(addr),.Sdr_rd_en(vp[7]),.Sdr_rd_dout(data[7]),
        .read_clk(pc),.read_req(req),.read_req_ack(ack),.read_finish(),
        .read_addr_0(21'd0),.read_addr_1(21'd196608),.read_addr_2(21'd393216),.read_addr_3(21'd589824),
        .read_addr_4(21'd786432),.read_addr_5(21'd983040),.read_addr_6(21'd1179648),
        .read_addr_7(21'd1376256),.read_addr_8(21'd1572864),.read_addr_index(4'd8),
        .read_len(21'd196608),.read_en(re),.read_data(pixel),
        .App_wr_en(),.App_wr_addr(),.App_wr_din(),.App_wr_dm(),.write_clk(pc),
        .write_req(1'b0),.write_req_ack(),.write_finish(),.write_addr_index(4'd0),
        .write_len(21'd196608),.write_en(1'b0),.write_data(8'd0),.write_v_flip(1'b0),
        .write_overflow(),.read_underflow(under),.write_ready(),
        .slide_active(slide),.slide_offset(offset),.slide_bank(4'd7),
        .zoom_active(1'b1),.zoom_size(8'd160),.zoom_left(left),.zoom_top(top),.zoom_width(width),.zoom_height(height));
    always @(posedge mc) begin
        if(rst) begin vp<=0;cycles<=0;end
        else begin vp<={vp[6:0],mr};cycles<=cycles+1'b1;end
        if(mr) begin
            if(addr>=1769472) $fatal(1,"native zoom memory bounds %0d",addr);
            data[0]<=word_at(addr);reads=reads+1;
        end
        for(i=1;i<8;i=i+1) data[i]<=data[i-1];
    end
    initial begin
        repeat(8) @(negedge pc);rst=0;
        for(n=0;n<5;n=n+1) begin
            case(n)
                0:begin width=256;height=192;left=90;top=538;slide=0;offset=0;end
                1:begin width=532;height=399;left=200;top=100;slide=1;offset=393216;end
                2:begin width=868;height=652;left=77;top=51;slide=1;offset=753664;end
                3:begin width=1016;height=764;left=2;top=2;slide=0;offset=0;end
                4:begin width=1024;height=768;left=0;top=0;slide=0;offset=0;end
            endcase
            @(negedge pc);req=1;re=0;wait(ack);@(negedge pc);req=0;wait(!ack);
            repeat(1800) @(negedge pc);
            for(y=0;y<768;y=y+1) begin
                for(x=0;x<1024;x=x+1) begin
                    @(negedge pc);re=1;@(posedge pc);#1;
                    if(x>=left && x<left+width && y>=top && y<top+height) begin
                        sx=((x-left)*1024+width-1)/width;sy=((y-top)*768+height-1)/height+offset/1024;
                        bank=sy>=768 ? 7 : 8;sy=sy%768;expected=color(bank,sx,sy);
                        if(pixel!==expected || under) $fatal(1,"native zoom %0dx%0d (%0d,%0d) got%h expected%h under%b",width,height,x,y,pixel,expected,under);
                        checked=checked+1;
                    end
                end
                @(negedge pc);re=0;repeat(319) @(negedge pc);
            end
            $display("checked native zoom %0dx%0d offset%0d",width,height,offset);
        end
        $display("PASS native RGB332 frame zoom: %0d golden pixels, 5 geometries through 1024x768, refresh/busy stalls, PIC9/PIC8 vertical slide seams",checked);$finish;
    end
    initial begin #120000000;$fatal(1,"native zoom timeout");end
endmodule

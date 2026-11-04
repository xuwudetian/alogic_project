`timescale 1ns/1ps
// Real reader/writer/FIFO RTL; SDRAM returns are a delayed address-color model.
module tb_slide_stream;
    reg mclk=0,pclk=0,wclk=0,rst=1,request=0,pop=0,sliding=0;
    reg [18:0] offset=0;reg [2:0] old_bank=1,target=5;
    wire ack,done,rd,wr,underflow,overflow,ready,wack;
    wire [20:0] address,waddr;wire [31:0] data,wdata;
    reg [7:0] rv=0;reg [31:0] colors[0:7];reg [9:0] cycle=0;
    reg write_req=0,produce=0,we=0;reg [31:0] din=0;
    integer i,xx,yy,stage,count=0,sent=0,stored=0,source_address,step,fd=0;
    reg [31:0] expected;
    always #12.5 mclk=~mclk;always #20 pclk=~pclk;always #10 wclk=~wclk;
    function [31:0] color_at;input integer a;integer bank,row,col;begin
        bank=a/307200;row=(a%307200)/640;col=a%640;
        color_at={8'(bank*36+32),8'(row/2),8'(col/3),8'h00};
    end endfunction
    frame_read_write #(.BURST_SIZE(128),.SLIDE_ENABLE(1),.WRITE_V_FLIP(0)) dut(
        .rst(rst),.mem_clk(mclk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(cycle<12),.Sdr_busy(1'b0),
        .App_rd_en(rd),.App_rd_addr(address),.Sdr_rd_en(rv[7]),.Sdr_rd_dout(colors[7]),
        .read_clk(pclk),.read_req(request),.read_req_ack(ack),.read_finish(done),
        .read_addr_0(21'd0),.read_addr_1(21'd307200),.read_addr_2(21'd614400),
        .read_addr_3(21'd921600),.read_addr_4(21'd1228800),.read_addr_5(21'd1536000),
        .read_addr_index(old_bank),.read_len(21'd307200),.read_en(pop),.read_data(data),
        .App_wr_en(wr),.App_wr_addr(waddr),.App_wr_din(wdata),.App_wr_dm(),
        .write_clk(wclk),.write_req(write_req),.write_req_ack(wack),.write_finish(),
        .write_addr_0(21'd0),.write_addr_1(21'd307200),.write_addr_2(21'd614400),
        .write_addr_3(21'd921600),.write_addr_4(21'd1228800),.write_addr_5(21'd1536000),
        .write_addr_index(3'd0),.write_len(21'd307200),.write_en(we),.write_data(din),
        .write_v_flip(1'b0),.write_overflow(overflow),.read_underflow(underflow),.write_ready(ready),
        .slide_active(sliding),.slide_offset(offset),.slide_bank(target));
    always @(posedge mclk) begin
        if(rst) begin rv<=0;cycle<=0;end
        else begin rv<={rv[6:0],rd};cycle<=cycle+1'b1;end
        colors[0]<=color_at(address);for(i=1;i<8;i=i+1) colors[i]<=colors[i-1];
        if(!rst && rd && wr) $fatal(1,"read/write collision");
        if(!rst && wr) begin
            if(waddr!==stored || wdata!==(32'habc00000+stored)) $fatal(1,"background write damaged");
            stored=stored+1;
        end
    end
    always @(negedge wclk) begin
        we=0;
        if(!rst && produce && ready && sent<307200) begin we=1;din=32'habc00000+sent;sent=sent+1;end
    end
    initial begin
        repeat(8) @(negedge pclk);rst=0;repeat(8) @(negedge pclk);
        write_req=1;wait(wack);@(negedge pclk);write_req=0;wait(!wack);produce=1;
        for(stage=0;stage<5;stage=stage+1) begin
            case(stage) 0:step=0;1:step=1;2:step=15;3:step=29;default:step=30;endcase
            sliding=step>0 && step<30;offset=sliding ? step*10240 : 0;old_bank=step==30 ? 5 : 1;
            repeat(40) @(negedge pclk);request=1;wait(ack);@(negedge pclk);request=0;wait(!ack);
            repeat(36000) @(negedge pclk);
            if(stage==2) begin fd=$fopen("../doc/validation/slide_mid.ppm","wb");$fwrite(fd,"P6\n640 480\n255\n");end
            for(yy=0;yy<480;yy=yy+1) begin
                for(xx=0;xx<640;xx=xx+1) begin
                    @(negedge pclk);pop=1;
                    source_address=(yy+step*16)<480 ? 307200+(yy+step*16)*640+xx :
                        1536000+(yy+step*16-480)*640+xx;
                    expected=color_at(source_address);
                    @(posedge pclk);#1;
                    if(underflow || overflow || data!==expected)
                        $fatal(1,"slide FIFO pixel stage%0d (%0d,%0d) got%h expected%h underflow%b",stage,xx,yy,data,expected,underflow);
                    if(fd) $fwrite(fd,"%c%c%c",data[31:24],data[23:16],data[15:8]);
                    count=count+1;
                end
                @(negedge pclk);pop=0;repeat(159) @(negedge pclk);
            end
            if(fd) begin $fclose(fd);fd=0;end
        end
        wait(stored==307200);
        if(count!=5*307200 || underflow || overflow) $fatal(1,"slide stream totals");
        $display("PASS slide stream: actual dual-clock FIFOs, 5 full rasters, exact seam/colors, no underflow, refresh, concurrent complete background write");$finish;
    end
    initial begin #200000000;$fatal(1,"slide stream timeout %0d %0d",count,stored);end
endmodule

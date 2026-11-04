`timescale 1ns/1ps
module tb_bmp;
    reg clk=0,rst_n=0,start=0,valid=0,finish=0;
    reg [31:0] size,offset;
    reg [7:0] data;
    wire accepted,pv,commit,done,topdown,scale;
    wire [23:0] rgb;
    wire [15:0] x,y;
    wire [7:0] error;
    reg [7:0] bytes[0:511];
    integer i,j,w,h,stride,count,mode,px,py,base;
    bmp24_decoder #(.EXPECTED_WIDTH(3),.EXPECTED_HEIGHT(2),.ALLOW_2X_SOURCE(1)) dut(
        .clk(clk),.rst_n(rst_n),.file_start(start),.file_size(size),.file_valid(valid),
        .file_byte(data),.file_byte_offset(offset),.file_end(finish),.upstream_error(8'd0),
        .header_accepted(accepted),.pixel_valid(pv),.pixel_rgb(rgb),.pixel_x(x),.pixel_y(y),
        .frame_commit(commit),.bmp_done(done),.bmp_error(error),.top_down(topdown),
        .source_scale_2x(scale),.pixel_ready(1'b1));
    always #5 clk=~clk;
    task u32;
        input integer pos,value;
        begin
            bytes[pos]=value;bytes[pos+1]=value>>8;bytes[pos+2]=value>>16;bytes[pos+3]=value>>24;
        end
    endtask
    task run_image;
        input integer twice,negative,bad;
        begin
            w=twice ? 6 : 3;h=twice ? 4 : 2;stride=((w*3+3)/4)*4;
            size=54+stride*h;
            for(i=0;i<512;i=i+1) bytes[i]=0;
            bytes[0]="B";bytes[1]="M";u32(2,size);u32(10,54);u32(14,40);
            u32(18,w);u32(22,negative ? -h : h);bytes[26]=1;bytes[28]=24;
            u32(30,bad);
            for(py=0;py<h;py=py+1) for(px=0;px<w;px=px+1) begin
                base=54+py*stride+px*3;
                bytes[base]=8'd20;bytes[base+1]=8'd80;bytes[base+2]=px+py*10;
            end
            @(negedge clk);start=1;count=0;
            @(negedge clk);start=0;
            for(j=0;j<size;j=j+1) begin
                valid=1;data=bytes[j];offset=j;
                @(posedge clk);#1;
                if(pv) begin
                    if(x!=count%3 || y!=(negative ? count/3 : 1-count/3)) $fatal(1,"orientation");
                    if(rgb[15:0]!==16'h5014) $fatal(1,"RGB channels/padding");
                    if(rgb[23:16]!=(twice ? (count%3)*2+(count/3)*20+6 : count%3+(count/3)*10))
                        $fatal(1,"box average %h",rgb);
                    count=count+1;
                end
                @(negedge clk);
            end
            valid=0;repeat(3) @(negedge clk);finish=1;
            repeat(2) @(posedge clk);#1;
            if(bad) begin if(error!=8'h35 || commit || count!=0) $fatal(1,"invalid compression");end
            else if(!commit || error!=0 || count!=6 || scale!=twice || topdown!=negative) $fatal(1,"frame integrity");
            @(negedge clk);finish=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        run_image(0,0,0);run_image(0,1,0);run_image(1,0,0);run_image(1,1,0);
        run_image(0,0,1);
        $display("PASS BMP: both orientations, RGB24, row padding, 2x2 box filtering, bad compression rejected");
        $finish;
    end
endmodule

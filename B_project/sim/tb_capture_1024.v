`timescale 1ns/1ps
// Byte-level DVP test. The golden mapper uses an independent integer formula,
// not the RTL's phase accumulator. Extra pixels/lines must never wrap around.
module tb_capture_1024;
    reg clk=0,rst_n=0,vs=0,href=0;
    reg [7:0] data=0;
    always #10 clk=~clk;
    wire raw_valid,raw_sof,valid,sof;
    wire [15:0] raw_rgb,rgb;
    wire [9:0] raw_x,raw_y,x;
    wire [8:0] y;
    ov5640_rgb565_capture #(.WAIT_FRAMES(0),.WIDTH(1024),.HEIGHT(768)) capture(
        .cam_pclk(clk),.rst_n(rst_n),.enable(1'b1),.cam_vsync(vs),.cam_href(href),.cam_data(data),
        .pixel_valid(raw_valid),.pixel_rgb565(raw_rgb),.pixel_x(raw_x),.pixel_y(raw_y),.frame_start(raw_sof));
    ov5640_resize_1024_to_640 resize(
        .clk(clk),.rst_n(rst_n),.input_frame_start(raw_sof),.input_valid(raw_valid),
        .input_rgb565(raw_rgb),.input_x(raw_x),.input_y(raw_y),
        .frame_start(sof),.pixel_valid(valid),.pixel_rgb565(rgb),.pixel_x(x),.pixel_y(y));
    integer raw_count=0,count=0,frames=0,tag=0,total_checked=0;
    integer px,py,sx,sy,i,j;
    reg [15:0] value;
    function [15:0] colour;
        input integer xx,yy,t;
        begin colour=((xx*73)^(yy*137)^(t*12345)) & 65535;end
    endfunction
    always @(posedge clk) begin
        #1;
        if(rst_n) begin
            if(raw_sof) raw_count=0;
            if(sof) begin count=0;frames=frames+1;end
            if(raw_valid) begin
                if(raw_x!==(raw_count%1024) || raw_y!==(raw_count/1024))
                    $fatal(1,"native coordinate mismatch %d,%d at %d",raw_x,raw_y,raw_count);
                if(raw_rgb!==colour(raw_count%1024,raw_count/1024,tag))
                    $fatal(1,"native RGB565 byte mismatch at %d",raw_count);
                raw_count=raw_count+1;
                if(raw_count>786432) $fatal(1,"native frame overran");
            end
            if(valid) begin
                px=count%640;py=count/640;
                sx=(px*8+4)/5;sy=(py*8+4)/5;
                if(x!==px || y!==py || rgb!==colour(sx,sy,tag))
                    $fatal(1,"normalized mismatch output=%d,%d source=%d,%d got=%h expected=%h",x,y,sx,sy,rgb,colour(sx,sy,tag));
                count=count+1;total_checked=total_checked+1;
                if(count>307200) $fatal(1,"normalized frame overran");
            end
            if(sof && valid) $fatal(1,"frame start and pixel overlapped");
        end
    end
    task begin_frame;
        input integer t;
        begin
            @(negedge clk);tag=t;href=0;vs=1;
            repeat(4) @(negedge clk);
            vs=0;repeat(4) @(negedge clk);
        end
    endtask
    task lines;
        input integer rows,extra;
        begin
            for(j=0;j<rows;j=j+1) begin
                for(i=0;i<1024+extra;i=i+1) begin
                    value=colour(i,j,tag);
                    href=1;data=value[15:8];@(negedge clk);
                    data=value[7:0];@(negedge clk);
                end
                // An unmatched trailing byte must not contaminate the next line.
                if(extra!=0) begin data=8'hbe;@(negedge clk);end
                href=0;repeat(3+(j%5)) @(negedge clk);
            end
            repeat(8) @(negedge clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        begin_frame(1);lines(770,3);
        if(raw_count!=786432 || count!=307200) $fatal(1,"full frame count mismatch");
        begin_frame(2);lines(11,0); // partial frame abandoned by a new VSYNC
        begin_frame(3);lines(768,0);
        if(raw_count!=786432 || count!=307200 || frames!=3) $fatal(1,"restart/count mismatch");
        $display("PASS CAPTURE_1024: 1024x768 DVP, all 640x480 RGB565 samples, excess pixels/lines, odd-byte tail, partial-frame restart (%0d checked)",total_checked);
        $finish;
    end
    initial begin #100000000;$fatal(1,"capture timeout");end
endmodule

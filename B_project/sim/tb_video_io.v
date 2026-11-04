`timescale 1ns/1ps
// Run with -DSIMULATION; exercises logic, not vendor electrical/timing models.
module tb_video_io;
    reg pixel_clk=0,serial_clk=0,camera_clk=0;
    always #20 pixel_clk=~pixel_clk;
    always #4 serial_clk=~serial_clk;
    always #5 camera_clk=~camera_clk;
    reg rst_n=0;
    integer errors=0;
    task check;input okay;input [255:0] message;
        begin if(okay!==1'b1) begin $display("FAIL: %0s",message);errors=errors+1;end end
    endtask
    initial begin #31;rst_n=1;end

    reg [7:0] encoder_data;
    reg encoder_de=0;
    reg [1:0] control=0;
    wire [9:0] encoded;
    tmds_encoder enc(.clk(pixel_clk),.rst_n(rst_n),.data(encoder_data),
        .de(encoder_de),.control(control),.symbol(encoded));
    function [7:0] decode;
        input [9:0] s;
        reg [7:0] q;
        integer j;
        begin
            q=s[9] ? ~s[7:0] : s[7:0];
            decode[0]=q[0];
            for(j=1;j<8;j=j+1) decode[j]=s[8] ? q[j]^q[j-1] : ~(q[j]^q[j-1]);
        end
    endfunction
    integer n,j,ones,rd;
    reg encoder_pass=0;
    initial begin
        wait(rst_n);
        // Drive after time zero so the combinational encoder sees the initial
        // all-zero byte in event-driven simulators before checking disparity.
        encoder_data=0;
        for(n=0;n<4;n=n+1) begin
            @(negedge pixel_clk);control=n;encoder_de=0;
            @(posedge pixel_clk);#1;
            case(n)
                0:check(encoded==10'b1101010100,"TMDS control 00");
                1:check(encoded==10'b0010101011,"TMDS control 01");
                2:check(encoded==10'b0101010100,"TMDS control 10");
                3:check(encoded==10'b1010101011,"TMDS control 11");
            endcase
        end
        rd=0;
        for(n=0;n<4096;n=n+1) begin
            @(negedge pixel_clk);encoder_de=1;encoder_data=(n*73)^(n>>4);
            @(posedge pixel_clk);#1;
            check(decode(encoded)==encoder_data,"TMDS all-byte roundtrip");
            ones=0;for(j=0;j<10;j=j+1) ones=ones+encoded[j];
            rd=rd+2*ones-10;
            check(rd>=-8 && rd<=8,"TMDS bounded wire disparity");
        end
        encoder_pass=1;
    end

    wire ser_data,ser_clock;
    tmds_serializer data_ser(.pixel_clk(pixel_clk),.serial_clk(serial_clk),.rst_n(rst_n),
        .symbol(10'b1011001010),.serial_out(ser_data));
    tmds_serializer clock_ser(.pixel_clk(pixel_clk),.serial_clk(serial_clk),.rst_n(rst_n),
        .symbol(10'b0000011111),.serial_out(ser_clock));
    reg old_ser_clock=0;
    integer serial_bit=0,serial_count=0;
    reg serial_locked=0;
    reg [9:0] expected_serial=10'b1011001010;
    always @(serial_clk) begin
        #1;
        if(rst_n && $time>200) begin
            if(ser_clock && !old_ser_clock) begin serial_bit=0;serial_locked=1;end
            if(serial_locked) begin
                check(ser_data==expected_serial[serial_bit],"DDR serializer LSB-first");
                serial_bit=(serial_bit+1)%10;serial_count=serial_count+1;
            end
            old_ser_clock=ser_clock;
        end
    end

    reg c_vsync=0,c_href=0;
    reg [7:0] c_data=0;
    wire c_valid,c_sof;
    wire [15:0] c_rgb;
    wire [9:0] c_x;
    wire [8:0] c_y;
    ov5640_rgb565_capture #(.WAIT_FRAMES(0)) capture(.cam_pclk(camera_clk),.rst_n(rst_n),
        .enable(1'b1),.cam_vsync(c_vsync),.cam_href(c_href),.cam_data(c_data),
        .pixel_valid(c_valid),.pixel_rgb565(c_rgb),.pixel_x(c_x),.pixel_y(c_y),.frame_start(c_sof));
    integer cap_seen=0;
    always @(posedge camera_clk) begin
        #1;
        if(c_valid) begin
            check(c_rgb==16'h1234+cap_seen,"OV5640 RGB565 byte order");
            check(c_x==cap_seen%3 && c_y==cap_seen/3,"OV5640 pixel coordinates");
            cap_seen=cap_seen+1;
        end
    end
    integer cy,cx;
    reg [15:0] value;
    reg capture_pass=0;
    initial begin
        wait(rst_n);
        @(negedge camera_clk);c_vsync=1;
        repeat(3) @(negedge camera_clk);
        c_vsync=0;
        repeat(3) @(negedge camera_clk);
        for(cy=0;cy<2;cy=cy+1) begin
            for(cx=0;cx<3;cx=cx+1) begin
                value=16'h1234+cy*3+cx;
                c_href=1;c_data=value[15:8];@(negedge camera_clk);
                c_data=value[7:0];@(negedge camera_clk);
            end
            c_href=0;repeat(4) @(negedge camera_clk);
        end
        check(cap_seen==6,"OV5640 two lines valid count");capture_pass=1;
    end

    // Full 320x240 RGB565 SDRAM preview is checked by tb_preview_sdram.

    reg sccb_start=0;
    wire sccb_busy,sccb_done,sccb_nack,sccb_scl;
    tri1 sccb_sda;
    reg slave_ack=0;
    assign sccb_sda=(slave_ack && sccb.state==3) ? 1'b0 : 1'bz;
    ov5640_sccb_write #(.QUARTER_CYCLES(2)) sccb(.clk(camera_clk),.rst_n(rst_n),
        .start(sccb_start),.register_data(24'h380802),.busy(sccb_busy),.done(sccb_done),
        .nack(sccb_nack),.scl(sccb_scl),.sda(sccb_sda));
    reg sccb_pass=0;
    initial begin
        wait(rst_n);@(negedge camera_clk);sccb_start=1;
        @(negedge camera_clk);sccb_start=0;
        wait(sccb_done);#1;check(sccb_nack,"SCCB detects missing camera ACK");
        @(negedge camera_clk);slave_ack=1;sccb_start=1;
        @(negedge camera_clk);sccb_start=0;
        wait(sccb_done);#1;check(!sccb_nack,"SCCB accepted register write");
        sccb_pass=1;
    end
    initial begin
        wait(encoder_pass && capture_pass && sccb_pass);
        check(serial_count>100,"serializer exercised");
        if(errors) $fatal(1,"VIDEO_IO failed: %0d errors",errors);
        $display("PASS VIDEO_IO: capture/SCCB/TMDS/DDR");
        $finish;
    end
    initial begin #60000000;$fatal(1,"VIDEO_IO timeout");end
endmodule

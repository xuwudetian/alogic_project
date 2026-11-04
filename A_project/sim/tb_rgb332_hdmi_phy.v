`timescale 1ns/1ps
module glbl; reg gsrn=1; endmodule
module tb_rgb332_hdmi_phy;
    reg pc=0,sc=0,rst=1;
    reg [9:0] ch0=10'h155,ch1=10'h24e,ch2=10'h3a1;
    wire [9:0] ck=10'b1111100000;
    wire [3:0] q;
    integer cycles=0,last_load=-1,loads=0,bits=0,position=0,received=0,epoch=0,lane;
    reg [39:0] expected[0:1023];
    reg [1:0] start_pipe=0;
    reg started=0;
    always #7.6923075 pc=~pc;
    always #1.5384615 sc=~sc;
    always @(negedge pc) if(!rst) begin
        ch0<={ch0[8:0],ch0[9]^ch0[6]};
        ch1<=ch1+10'h1a7;ch2<={ch2[0],ch2[9:1]};
    end
    hdmi_phy_wrapper dut(pc,sc,rst,ch0,ch1,ch2,ck,q[0],q[1],q[2],q[3]);
    always @(posedge sc) begin
        cycles=cycles+1;
        if(rst || dut.serial_reset_sync[2]) begin
            start_pipe=0;started=0;last_load=-1;loads=0;received=0;bits=0;
        end else begin
            if(start_pipe[1]) begin started=1;position=0;end
            start_pipe={start_pipe[0],dut.u0_lane_lvds_8_1.S_load_en_2d};
            if(dut.u0_lane_lvds_8_1.S_load_en_2d) begin
                if(last_load>=0 && cycles-last_load!=5) $fatal(1,"symbol cadence");
                last_load=cycles;expected[loads]={ck,ch2,ch1,ch0};loads=loads+1;
            end
            #0.5;
            if(started) begin
                for(lane=0;lane<4;lane=lane+1)
                    if(q[lane]!==expected[received][lane*10+position])
                        $fatal(1,"PHY pos epoch%0d word%0d bit%0d lane%0d",epoch,received,position,lane);
                position=position+1;bits=bits+4;
            end
        end
    end
    always @(negedge sc) begin
        #0.5;
        if(!rst && !dut.serial_reset_sync[2] && started) begin
            for(lane=0;lane<4;lane=lane+1)
                if(q[lane]!==expected[received][lane*10+position])
                    $fatal(1,"PHY neg epoch%0d word%0d bit%0d lane%0d",epoch,received,position,lane);
            position=position+1;bits=bits+4;
            if(position==10) begin
                started=0;received=received+1;
                if(received==256 && bits!=10240) $fatal(1,"PHY bit count");
            end
        end
    end
    initial begin
        #203;rst=0;
        wait(received==256);#0.3;rst=1;epoch=1;
        #78.3;rst=0;
        wait(received==256);
        $display("PASS actual four-lane HDMI PHY + vendor ODDR: 20480 exact bits, LSB-first channel/clock ordering, 65/325MHz, asynchronous reset and serial synchronous release");
        $finish;
    end
    initial begin #20000;$fatal(1,"PHY timeout");end
endmodule

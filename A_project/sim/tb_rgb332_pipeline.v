`timescale 1ns/1ps
module tb_rgb332_pipeline;
    reg clk=0;
    always #10 clk=~clk;
    tri1 scl,sda,mdio;
    top #(.BOOT_HOLD_CYCLES(100)) dut(.clk(clk),.rst_n(1'b1),.key1(1'b1),.key2(1'b1),.key3(1'b1),
        .sw(4'b1001),.sd_miso(1'b1),.sensor_scl(scl),.sensor_sda(sda),
        .eth_rx_clk(1'b0),.eth_rx_ctl(1'b0),.eth_rxd(4'd0),.eth_mdio(mdio));
    integer raw_x=0,raw_y=0,out_x=0,out_y=0,total=0,audios=0,acrs=0,clocks=0;
    integer last_audio=0;
    reg raw_de=0,out_de=0;
    reg [23:0] expected;
    function [23:0] expand(input [7:0] p);
        expand={p[7:5],p[7:5],p[7:6],p[4:2],p[4:2],p[4:3],{4{p[1:0]}}};
    endfunction
    initial begin
        force dut.display_valid=1;force dut.active_bank=0;force dut.gain=256;
        force dut.brightness=0;force dut.contrast=128;force dut.effect_mask_active=0;
        force dut.picture_layout=1;force dut.picture_zoom_size=160;
        force dut.picture_zoom_left=0;force dut.picture_zoom_top=0;
        force dut.picture_zoom_width=640;force dut.picture_zoom_height=480;
        force dut.picture_zoom_phase=20;force dut.ui.boot_active=0;force dut.ui.logo_pixel=0;
        force dut.alarm=0;force dut.directory=0;force dut.browse=0;
    end
    always @(negedge dut.video_clk) if(!dut.rst_video) begin
        clocks=clocks+1;
        if(dut.tone_valid) begin
            if(audios!=0 && clocks-last_audio!=1354 && clocks-last_audio!=1355) $fatal(1,"65MHz audio cadence");
            last_audio=clocks;audios=audios+1;
        end
        if(dut.acr_valid) acrs=acrs+1;
        if(dut.de) begin
            case(raw_x%4)
                0:expected=expand(8'h10);1:expected=expand(8'h20);2:expected=expand(8'h30);3:expected=0;
            endcase
            if(dut.raw_rgb!==expected || dut.underflow) $fatal(1,"native stream (%0d,%0d) %h expected%h under%b",raw_x,raw_y,dut.raw_rgb,expected,dut.underflow);
            raw_x=raw_x+1;
        end
        if(raw_de && !dut.de) begin
            if(raw_x!=1024) $fatal(1,"raw line width %0d",raw_x);raw_x=0;raw_y=raw_y+1;
        end
        raw_de=dut.de;
        if(dut.xga_de) begin
            // The exact byte pattern must reach HDMI without pixel replication
            // or a second RGB565 quantization, including the last pixel of rows.
            if(out_x>=200 && out_x<800 && out_y>=100 && out_y<600) begin
                case(out_x%4)
                    0:expected=expand(8'h10);1:expected=expand(8'h20);2:expected=expand(8'h30);3:expected=0;
                endcase
                if(dut.xga_rgb!==expected) $fatal(1,"RGB888 effects/UI passthrough (%0d,%0d) %h expected%h",out_x,out_y,dut.xga_rgb,expected);
            end
            out_x=out_x+1;total=total+1;
        end
        if(out_de && !dut.xga_de) begin
            if(out_x!=1024) $fatal(1,"HDMI width %0d",out_x);out_x=0;out_y=out_y+1;
            if(out_y==768) begin
                if(total!=786432 || raw_y!=768 || audios<760 || acrs<5) $fatal(1,"native frame/audio totals pixels%0d rawrows%0d audios%0d acrs%0d",total,raw_y,audios,acrs);
                $display("PASS native RGB332 actual top: 786432 independent pixels, SDRAM/FIFO/zoom/RGB888/UI/HDMI path, 65MHz tone cadence and no underflow");$finish;
            end
        end
        out_de=dut.xga_de;
    end
    initial begin #20000000;$fatal(1,"pipeline timeout");end
endmodule

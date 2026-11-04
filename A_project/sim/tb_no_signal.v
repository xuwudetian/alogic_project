`timescale 1ns/1ps
module tb_no_signal;
    reg clk=0,rst=1,hs=1,vs=1,de=0,absent=0,directory=0,alarm=0;
    reg [23:0] rgb=24'h123456;
    wire oh,ov,od,rh,rv,rd;
    wire [23:0] pixel,reference_pixel;
    integer xx,yy,n,fd,count=0,checked=0;
    reg [23:0] expected0,expected1;
    reg [2:0] sync0,sync1;
    player_ui_overlay #(.LOGO_ENABLE(1),.NO_SIGNAL_ENABLE(1),.DIRECTORY_ANIMATION_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .directory(directory),.selection(2'd0),.alarm(alarm),.directory_run(1'b0),.no_signal(absent),
        .out_hs(oh),.out_vs(ov),.out_de(od),.out_rgb(pixel));
    player_ui_overlay_before #(.LOGO_ENABLE(1),.NO_SIGNAL_ENABLE(0),.DIRECTORY_ANIMATION_ENABLE(1)) reference_ui(
        .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .directory(directory),.selection(2'd0),.alarm(alarm),.directory_run(1'b0),.no_signal(1'b0),
        .out_hs(rh),.out_vs(rv),.out_de(rd),.out_rgb(reference_pixel));
    always #5 clk=~clk;
    // Independent coordinate-based specification of the 640x480 test card.
    function [23:0] test_card;
        input integer px,py;
        integer column,level,segment;
        begin
            column=px*7/640;
            if(py<360) begin
                case(column)
                    0:test_card=24'hffffff;1:test_card=24'hffff00;
                    2:test_card=24'h00ffff;3:test_card=24'h00ff00;
                    4:test_card=24'hff00ff;5:test_card=24'hff0000;
                    default:test_card=24'h0000ff;
                endcase
            end else if(py<408) begin
                case(column)
                    0:test_card=24'h0000ff;1:test_card=24'hff00ff;
                    2:test_card=24'hffff00;3:test_card=24'hff0000;
                    4:test_card=24'h00ffff;5:test_card=24'h000000;
                    default:test_card=24'hffffff;
                endcase
            end else if(px<384) begin
                level=255-px*171/256;test_card={level[7:0],level[7:0],level[7:0]};
            end else begin
                segment=(px-384)/51;if(segment>4) segment=4;
                level=(px-384-segment*51)*5;
                case(segment)
                    0:test_card=24'hff0000+level*256;
                    1:test_card=24'hffff00-level*65536;
                    2:test_card=24'h00ff00+level;
                    3:test_card=24'h00ffff-level*256;
                    default:test_card=24'h0000ff+level*65536;
                endcase
            end
        end
    endfunction
    task frame_tick;begin
        @(negedge clk);vs=0;de=0;repeat(3) @(negedge clk);vs=1;
        repeat(3) @(negedge clk);
    end endtask
    task run_frame;
        input integer pattern;
        begin
            frame_tick;expected0=0;expected1=0;sync0=3'b110;sync1=3'b110;count=0;
            if(pattern) begin
                fd=$fopen("no_signal_preview.ppm","wb");
                if(!fd) $fatal(1,"cannot create preview");
                $fwrite(fd,"P6\n640 480\n255\n");
            end
            for(yy=0;yy<480;yy=yy+1) begin
                for(xx=0;xx<650;xx=xx+1) begin
                    @(negedge clk);de=xx<640;hs=!(xx>=642 && xx<646);
                    rgb={xx[7:0],yy[7:0],8'h5a};
                    expected1=expected0;expected0=de ? test_card(xx,yy) : 24'd0;
                    sync1=sync0;sync0={hs,vs,de};
                    @(posedge clk);#1;
                    if({oh,ov,od}!==sync1) $fatal(1,"sync/DE latency x%0d y%0d",xx,yy);
                    if(pattern) begin
                        if(pixel!==expected1) $fatal(1,"test card x%0d y%0d got %h expected %h",xx,yy,pixel,expected1);
                        if(od) begin $fwrite(fd,"%c%c%c",pixel[23:16],pixel[15:8],pixel[7:0]);count=count+1;end
                    end else if(pixel!==reference_pixel || {oh,ov,od}!=={rh,rv,rd})
                        $fatal(1,"normal/menu/alarm changed x%0d y%0d",xx,yy);
                    if(!od && pixel!==0) $fatal(1,"nonblack blanking");
                    checked=checked+1;
                end
            end
            @(negedge clk);de=0;hs=1;repeat(4) @(negedge clk);
            if(pattern) begin
                $fclose(fd);if(count!=307200) $fatal(1,"frame pixel count %0d",count);
            end
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        run_frame(0);
        absent=1;run_frame(1);
        directory=1;repeat(13) frame_tick;run_frame(0);
        directory=0;repeat(13) frame_tick;
        alarm=1;run_frame(0);alarm=0;
        run_frame(1);
        absent=0;run_frame(0);
        $display("PASS no signal: %0d raster clocks, full color bars/gray/rainbow, clean logo suppression, blanking and latency, menu/alarm priority, exact normal-output recovery",checked);
        $finish;
    end
    initial begin #30000000;$fatal(1,"no signal raster timeout");end
endmodule

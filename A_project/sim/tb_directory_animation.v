`timescale 1ns/1ps
// Compare every moving pixel with independently rendered stationary menus.
// The reference placement uses the quadratic formula rather than the RTL table.
module tb_directory_animation;
    parameter integer EXTERNAL_DIM=0;
    localparam integer LATENCY=EXTERNAL_DIM!=0 ? 7 : 2;
    reg clk=0,rst=1,hs=1,vs=1,de=0,directory=0,alarm=0;
    reg [23:0] rgb=0;
    wire oh,ov,od,active,plain_de,selected_de;
    wire [23:0] pixel,plain_pixel,selected_pixel;
    reg [23:0] background[0:307199];
    reg [23:0] plain_menu[0:307199],selected_menu[0:307199];
    reg [1023:0] background_path;
    reg [2:0] sync_pipe[0:LATENCY-1];
    reg [23:0] rgb_pipe[0:LATENCY-1];
    integer x_pipe[0:LATENCY-1],y_pipe[0:LATENCY-1];
    reg [2:0] sync1;
    reg [23:0] rgb1;
    integer x1=0,y1=0,input_x=0,input_y=0,j;
    integer xx=0,yy=0,step,phase,capture=0,pixels=0,offset,level;
    integer fd=0,frame_number=0,index,previous_offset,previous_delta,delta;
    reg [23:0] expected;
    reg [1023:0] filename;
    wire fh,fv,fde;
    wire [23:0] fx_rgb;
    wire [2:0] dim;
    reg [8:0] video_gain;
    always @* begin
        case(dim)
            1:video_gain=224;2:video_gain=192;3:video_gain=160;4:video_gain=128;
            default:video_gain=256;
        endcase
    end
    generate if(EXTERNAL_DIM!=0) begin:video_dimmer
        player_video video(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
            .brightness(9'sd0),.contrast(9'd128),.gain(video_gain),.display_valid(1'b1),
            .picture(4'd0),.scaled(1'b0),.auto_play(1'b1),.error_code(8'd0),
            .state_code(4'd8),.volume(4'd4),.interval_seconds(4'd3),.menu(3'd0),.modes(4'b0011),
            .audio_valid(1'b0),.audio_sample(24'd0),.out_hs(fh),.out_vs(fv),.out_de(fde),.out_rgb(fx_rgb));
    end else begin:no_video_dimmer
        assign fh=hs;assign fv=vs;assign fde=de;assign fx_rgb=rgb;
    end endgenerate
    always #20 clk=~clk;
    player_ui_overlay #(.DIRECTORY_ANIMATION_ENABLE(1),.DIRECTORY_EXTERNAL_DIM(EXTERNAL_DIM)) dut(
        .clk(clk),.rst(rst),.hs(fh),.vs(fv),.de(fde),.rgb(fx_rgb),
        .directory(directory),.selection(2'd0),.alarm(alarm),.directory_run(1'b0),
        .no_signal(1'b0),.boot_ready(1'b1),.directory_active(active),.background_dim(dim),
        .out_hs(oh),.out_vs(ov),.out_de(od),.out_rgb(pixel));
    player_ui_overlay plain(
        .clk(clk),.rst(rst),.hs(fh),.vs(fv),.de(fde),.rgb(fx_rgb),
        .directory(1'b1),.selection(2'd3),.alarm(1'b0),.directory_run(1'b0),
        .no_signal(1'b0),.boot_ready(1'b1),.out_de(plain_de),.out_rgb(plain_pixel));
    player_ui_overlay selected(
        .clk(clk),.rst(rst),.hs(fh),.vs(fv),.de(fde),.rgb(fx_rgb),
        .directory(1'b1),.selection(2'd0),.alarm(1'b0),.directory_run(1'b0),
        .no_signal(1'b0),.boot_ready(1'b1),.out_de(selected_de),.out_rgb(selected_pixel));
    function [7:0] shaded;
        input [7:0] c;input integer p;
        integer v;
        begin
            if(EXTERNAL_DIM!=0) v=(c*(p<4 ? 224 : p<8 ? 192 : p<12 ? 160 : 128))/256;
            else if(p<4) v=c-c/8;
            else if(p<8) v=c-c/4;
            else if(p<12) v=c/2+c/8;
            else v=c/2;
            shaded=v;
        end
    endfunction
    always @(posedge clk) begin
        sync_pipe[0]<={hs,vs,de};rgb_pipe[0]<=rgb;x_pipe[0]<=input_x;y_pipe[0]<=input_y;
        for(j=1;j<LATENCY;j=j+1) begin
            sync_pipe[j]<=sync_pipe[j-1];rgb_pipe[j]<=rgb_pipe[j-1];
            x_pipe[j]<=x_pipe[j-1];y_pipe[j]<=y_pipe[j-1];
        end
        #1;
        sync1=sync_pipe[LATENCY-1];rgb1=rgb_pipe[LATENCY-1];x1=x_pipe[LATENCY-1];y1=y_pipe[LATENCY-1];
        if(!rst && capture!=0) begin
            if({oh,ov,od}!==sync1) $fatal(1,"animation changed sync latency");
            if(!od && pixel!==0) $fatal(1,"non-black blanking");
            if(od) begin
                index=y1*640+x1;
                if(capture==1) begin
                    if(!plain_de || !selected_de) $fatal(1,"reference sync mismatch");
                    plain_menu[index]=plain_pixel;selected_menu[index]=selected_pixel;
                end
                if(phase==0) expected=rgb1;
                else if(x1<offset) expected={shaded(rgb1[23:16],phase),shaded(rgb1[15:8],phase),shaded(rgb1[7:0],phase)};
                else if(phase==13) expected=selected_menu[y1*640+x1-offset];
                else expected=plain_menu[y1*640+x1-offset];
                if(pixel!==expected)
                    $fatal(1,"directory raster frame=%0d phase=%0d x=%0d y=%0d offset=%0d got=%h expected=%h",
                        frame_number,phase,x1,y1,offset,pixel,expected);
                pixels=pixels+1;
                if(fd) $fwrite(fd,"%c%c%c",pixel[23:16],pixel[15:8],pixel[7:0]);
            end
        end
    end
    task frame;
        begin
            @(negedge clk);de=0;hs=1;vs=0;
            repeat(12) @(negedge clk);vs=1;repeat(12) @(negedge clk);
        end
    endtask
    task raster;
        input integer wanted_phase;input integer golden;
        begin
            phase=wanted_phase;offset=(640*(13-phase)*(13-phase)+84)/169;
            pixels=0;capture=golden ? 1 : 2;
            if($test$plusargs("preview") && !golden) begin
                $sformat(filename,"directory_frame_%02d.ppm",frame_number);
                fd=$fopen(filename,"wb");if(!fd) $fatal(1,"cannot write preview");
                $fwrite(fd,"P6\n640 480\n255\n");
            end
            for(yy=0;yy<480;yy=yy+1) begin
                for(xx=0;xx<650;xx=xx+1) begin
                    @(negedge clk);de=xx<640;hs=!(xx>=642 && xx<646);
                    input_x=xx;input_y=yy;
                    rgb=xx<640 ? background[yy*640+xx] : 24'd0;
                end
            end
            @(negedge clk);de=0;hs=1;repeat(LATENCY+3) @(negedge clk);
            capture=0;
            if(fd) begin $fclose(fd);fd=0;end
            if(pixels!=307200) $fatal(1,"missing pixels %0d",pixels);
            if(!golden) frame_number=frame_number+1;
        end
    endtask
    initial begin
        for(yy=0;yy<480;yy=yy+1)
            for(xx=0;xx<640;xx=xx+1)
                background[yy*640+xx]={xx[7:0],yy[7:0],xx[7:0]^yy[7:0]};
        if($value$plusargs("background=%s",background_path)) $readmemh(background_path,background);
        force plain.hint_scroll=0;force selected.hint_scroll=0;force dut.hint_scroll=0;
        xx=0;yy=0;repeat(5) @(negedge clk);rst=0;repeat(4) @(negedge clk);
        frame;raster(0,1);frame;raster(0,0);
        directory=1;
        repeat(12) @(negedge clk);
        if(!active || dut.directory_phase!=0) $fatal(1,"request changed pixels before a frame boundary");
        previous_offset=640;previous_delta=640;
        for(step=1;step<=13;step=step+1) begin
            frame;
            if(dut.directory_phase!=step || !active) $fatal(1,"entry duration/pause");
            delta=previous_offset-dut.directory_offset;
            if(delta<=0 || delta>previous_delta) $fatal(1,"entry is not decelerating");
            previous_offset=dut.directory_offset;previous_delta=delta;
            raster(step,0);
        end
        directory=0;repeat(12) @(negedge clk);
        if(!active || dut.directory_phase!=13) $fatal(1,"exit released the background early");
        for(step=12;step>=0;step=step-1) begin
            frame;
            if(dut.directory_phase!=step || active!==(step!=0)) $fatal(1,"exit duration/pause");
            raster(step,0);
        end
        // A reversed command continues from the current position without a jump.
        directory=1;repeat(5) frame;
        directory=0;repeat(3) @(negedge clk);
        if(dut.directory_phase!=5) $fatal(1,"mid-frame reverse moved the menu");
        frame;if(dut.directory_phase!=4) $fatal(1,"reverse skipped a phase");
        directory=1;frame;if(dut.directory_phase!=5) $fatal(1,"re-entry snapped to an endpoint");
        alarm=1;frame;
        if(dut.directory_phase!=13 || dut.base!==dut.alarm_background) $fatal(1,"alarm priority");
        alarm=0;frame;if(dut.directory_phase!=13) $fatal(1,"alarm return restarted animation");
        release dut.hint_scroll;
        frame;frame;if(dut.hint_scroll!=1) $fatal(1,"hint does not scroll after settling");
        directory=0;frame;if(dut.hint_scroll!=0) $fatal(1,"exit retained the scrolling origin");
        rst=1;repeat(3) @(negedge clk);
        if(dut.directory_phase!=0 || od || pixel!=0) $fatal(1,"reset during animation");
        $display("PASS directory: 28 complete rasters, quadratic right slide, stepped dimming, cursor only at rest, 13-frame reverse exit, pause tail, rapid reversals, alarm priority, hint resume, aligned sync, external video gain=%0d",EXTERNAL_DIM);
        $finish;
    end
    initial begin #500000000;$fatal(1,"directory animation timeout");end
endmodule

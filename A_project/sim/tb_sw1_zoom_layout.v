`timescale 1ns/1ps
module tb_sw1_zoom_layout;
    reg clk=0,rst=1,hs=1,vs=1,de=0;
    reg [23:0] rgb=0,tint=24'hffff00;
    reg [7:0] layout_size=136;
    wire [9:0] layout_left=320-layout_size*2;
    reg [8:0] layout_top=32;
    wire wh,wv,wd,oh,ov,od;wire [23:0] wrgb,out;
    reg [23:0] expected[0:5];reg [5:0] ds,hsq,vsq;
    integer mode,row,col,j,n,file,checked,bars,waves,frames,idx,distance,length;
    reg [23:0] target,base;reg hit;
    always #20 clk=~clk;
    player_video #(.WAVE_MUSIC_ENABLE(2),.AMBIENT_ENABLE(1),.AMBIENT_ZOOM_ENABLE(1)) wave_display(
        .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),.brightness(9'sd0),.contrast(9'd128),
        .gain(9'd256),.display_valid(1'b1),.picture(4'd0),.scaled(1'b0),.auto_play(1'b1),
        .error_code(8'd0),.state_code(4'd0),.volume(4'd8),.interval_seconds(4'd3),.menu(3'd0),.modes(4'd3),
        .audio_valid(1'b0),.audio_sample(24'd0),.out_hs(wh),.out_vs(wv),.out_de(wd),.out_rgb(wrgb),
        .debug_status(60'd0),.audio_status(8'd1),.image_valid(1'b1),.ui_directory(1'b0),.ui_status(1'b0),
        .ui_alarm(1'b0),.ui_browse(1'b0),.source_resolution(40'h0064000480),.run_mode(2'd2),
        .effect_mask_active(1'b0),.effect_mask_style(3'd0),.effect_mask_level(6'd0),.transition_mode(4'd0),
        .layout_size(layout_size),.layout_left(layout_left),.layout_top(layout_top),.audio_select(2'd0),.ambient_color(tint),.picture_layout(1'b1));
    audio_spectrum_overlay #(.AMBIENT_ENABLE(1)) spectrum_display(
        .clk(clk),.rst(rst),.enable(1'b0),.hs(wh),.vs(wv),.de(wd),.rgb_in(wrgb),
        .audio_valid(1'b0),.audio_sample(24'd0),.alarm(1'b0),.ambient_color(tint),.picture_layout(1'b1),
        .hs_out(oh),.vs_out(ov),.de_out(od),.rgb_out(out));
    function [23:0] background;input integer xx,yy;begin background={8'(xx),8'(yy),8'(xx^yy)};end endfunction
    function [23:0] blend;input [23:0] bg,fg;input integer alpha;integer r,g,b;begin
        r=(bg[23:16]*(8-alpha)+fg[23:16]*alpha)/8;
        g=(bg[15:8]*(8-alpha)+fg[15:8]*alpha)/8;
        b=(bg[7:0]*(8-alpha)+fg[7:0]*alpha)/8;blend={8'(r),8'(g),8'(b)};
    end endfunction
    function [23:0] reference;input integer xx,yy;integer index,delta,len;reg body,frame_box,glow_box;reg [23:0] bg;begin
        body=xx>=layout_left && xx<layout_left+layout_size*4 && yy>=layout_top && yy<layout_top+layout_size*3;
        reference=body ? background(xx,yy) : 24'h081014;
    end endfunction
    initial begin
        repeat(4) @(negedge clk);rst=0;repeat(80) @(negedge clk);
        // Deterministic flat PCM trace and 64 nonuniform FFT bins isolate geometry.
        for(n=0;n<512;n=n+1) wave_display.triggered_visual.scope.points[n]={7'd64,7'd64};
        for(mode=0;mode<4;mode=mode+1) begin
            layout_size=mode==0 ? 136 : mode==1 ? 144 : mode==2 ? 159 : 160;
            layout_top=mode==0 ? 32 : mode==1 ? 22 : mode==2 ? 1 : 0;
            de=0;vs=0;repeat(90) @(negedge clk);vs=1;repeat(12) @(negedge clk);
            wave_display.triggered_visual.scope.valid=1;
            for(n=0;n<64;n=n+1) spectrum_display.displayed[n]=10+n%51;
            for(n=0;n<6;n=n+1) expected[n]=0;
            ds=0;hsq=63;vsq=63;checked=0;bars=0;waves=0;frames=0;
            file=0;if(mode==0) begin file=$fopen("../doc/validation/ambient_layout.ppm","wb");$fwrite(file,"P6\n640 480\n255\n");end
            for(row=0;row<480;row=row+1) begin
                for(col=0;col<650;col=col+1) begin
                    @(negedge clk);de=col<640;hs=!(col>=642 && col<646);rgb=background(col,row);
                    target=de ? reference(col,row) : 24'd0;
                    @(posedge clk);
                    for(j=5;j>0;j=j-1) expected[j]=expected[j-1];
                    expected[0]=target;ds={ds[4:0],de};hsq={hsq[4:0],hs};vsq={vsq[4:0],vs};#1;
                    if(out!==expected[5] || od!==ds[5] || oh!==hsq[5] || ov!==vsq[5])
                        $fatal(1,"ambient raster mode%0d (%0d,%0d) rgb%h expected%h DE%b/%b",mode,col,row,out,expected[5],od,ds[5]);
                    if(od) begin checked=checked+1;if(file!=0) $fwrite(file,"%c%c%c",out[23:16],out[15:8],out[7:0]);end
                end
            end
            if(file!=0) $fclose(file);
            if(checked!=307200) $fatal(1,"incomplete ambient raster");
        end
        $display("PASS SW1 zoom raster: four full frames, changing 4:3 bounds, clean margins, no stale waveform/border/spectrum, pixel/sync alignment");$finish;
    end
    initial begin #50000000;$fatal(1,"ambient raster timeout");end
endmodule

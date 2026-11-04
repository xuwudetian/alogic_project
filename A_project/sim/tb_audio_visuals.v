`timescale 1ns/1ps
module tb_audio_visuals;
    reg clk=0,rst=1,hs=1,vs=1,de=0,av=0,hidden=0,browse=0,alarm=0;
    reg [23:0] rgb=0;
    reg signed [23:0] sample=0;
    wire wh,wv,wd,oh,ov,od;
    wire [23:0] wrgb,out;
    wire [3:0] modes={2'b00,!alarm && (hidden || browse),1'b1};
    integer n,j,row,col,mode,checked,wave_pixels,bar_pixels,file;
    reg [23:0] pixels[0:5];
    reg [5:0] ds,hsq,vsq;
    reg [63:0] seen_bars;
    reg [23:0] expected;
    always #20 clk=~clk;

    player_video #(.WAVE_TRIGGER_ENABLE(0),.WAVE_SMOOTH_ENABLE(0),.UI_ENABLE(1)) wave_display(
        .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .brightness(9'sd0),.contrast(9'd128),.gain(9'd256),.display_valid(1'b1),
        .picture(3'd0),.scaled(1'b0),.auto_play(1'b0),.error_code(8'd0),.state_code(4'd0),
        .volume(4'd8),.interval_seconds(4'd3),.transition_mode(4'd0),.menu(3'd0),.modes(modes),
        .audio_valid(av),.audio_sample(sample),.out_hs(wh),.out_vs(wv),.out_de(wd),.out_rgb(wrgb),
        .debug_status(60'd0),.audio_status(8'd0),.image_valid(1'b1),
        .ui_alarm(alarm),.ui_status(1'b0),.ui_directory(1'b0),.ui_browse(1'b0),
        .run_mode(2'd0),.source_resolution(40'h0064000480));
    audio_spectrum_overlay spectrum_display(
        .clk(clk),.rst(rst),.enable(alarm || (!hidden && !browse)),.alarm(alarm),
        .hs(wh),.vs(wv),.de(wd),.rgb_in(wrgb),.audio_valid(av),.audio_sample(sample),
        .hs_out(oh),.vs_out(ov),.de_out(od),.rgb_out(out));

    function integer point;
        input integer index;
        begin point=32+(index<64 ? index : 127-index);end
    endfunction
    function integer level;
        input integer index;
        begin level=index%4==0 ? 20 : index==63 ? 120 : 20+(index*7)%101;end
    endfunction
    function [23:0] background;
        input integer px,py;
        begin background={px[7:0],py[7:0],px[7:0]^py[7:0]};end
    endfunction
    function [23:0] color;
        input integer distance;
        begin
            case(distance/16)
                0:color=24'h2088c0;
                1:color=24'h2498c4;
                2:color=24'h28a8c4;
                3:color=24'h30b4bc;
                4:color=24'h38beb0;
                5:color=24'h40c4a0;
                6:color=24'h50c890;
                default:color=24'h68cc88;
            endcase
        end
    endfunction
    function [23:0] blend_half;
        input [23:0] foreground,background_rgb;
        integer r,g,b;
        begin
            r=foreground[23:16]+background_rgb[23:16];
            g=foreground[15:8]+background_rgb[15:8];
            b=foreground[7:0]+background_rgb[7:0];
            blend_half={r[8:1],g[8:1],b[8:1]};
        end
    endfunction
    function [23:0] reference_pixel;
        input integer px,py;
        integer index,phase,a,b,p0,p1;
        begin
            reference_pixel=alarm ? 24'd0 : background(px,py);
            if(alarm || (!hidden && !browse)) begin
                if(py>=216 && py<344 && px>=8 && px<632) begin
                    index=px/5;phase=px%5;
                    p0=point(index);p1=point(index==127 ? 127 : index+1);
                    a=((5-phase)*p0+phase*p1+2)/5;
                    b=((4-phase)*p0+(phase+1)*p1+2)/5;
                    if((py-216>=a && py-216<=b+1) || (py-216>=b && py-216<=a+1))
                        reference_pixel=alarm ? 24'hff2020 : 24'h1040b0;
                end
                if(py>=352 && py<476 && px>=8 && px<632) begin
                    index=((px-8)/39)*4+((px-8)%39)/10;
                    phase=((px-8)%39)%10;
                    if(phase>=1 && phase<8 && 475-py<(level(index)/2)*2)
                        reference_pixel=alarm ? 24'hff2020 : blend_half(color(475-py),background(px,py));
                end
            end
        end
    endfunction

    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(n=0;n<1024;n=n+1) begin
            sample=(64-point(n/8))*104858;av=1;
            @(negedge clk);av=0;repeat(2) @(negedge clk);
        end
        if(!wave_display.wave_ready) $fatal(1,"wave capture incomplete");
        for(mode=0;mode<4;mode=mode+1) begin
            hidden=(mode==1 || mode==3);browse=(mode==2);alarm=mode==3;de=0;hs=1;vs=0;
            repeat(80) @(negedge clk);vs=1;repeat(12) @(negedge clk);
            // Deterministic heights isolate geometry; real FFT is tested separately.
            for(n=0;n<64;n=n+1) spectrum_display.displayed[n]=level(n)/2;
            ds=0;hsq=6'b111111;vsq=6'b111111;
            for(n=0;n<6;n=n+1) pixels[n]=0;
            checked=0;wave_pixels=0;bar_pixels=0;seen_bars=0;
            file=0;
            if(mode==0) begin
                file=$fopen("../doc/validation/audio_layout.ppm","wb");
                $fwrite(file,"P6\n640 480\n255\n");
            end
            for(row=0;row<480;row=row+1) begin
                for(col=0;col<650;col=col+1) begin
                    @(negedge clk);
                    de=col<640;hs=!(col>=642 && col<646);rgb=background(col,row);
                    expected=de ? reference_pixel(col,row) : 24'd0;
                    if(de) begin
                        checked=checked+1;
                        if(mode==0 && expected!=background(col,row)) begin
                            if(row>=216 && row<344) wave_pixels=wave_pixels+1;
                            if(row>=352) begin bar_pixels=bar_pixels+1;seen_bars[((col-8)/39)*4+((col-8)%39)/10]=1;end
                        end
                    end
                    @(posedge clk);
                    for(j=5;j>0;j=j-1) pixels[j]=pixels[j-1];
                    pixels[0]=expected;ds={ds[4:0],de};hsq={hsq[4:0],hs};vsq={vsq[4:0],vs};
                    #1;
                    if(out!==pixels[5] || od!==ds[5] || oh!==hsq[5] || ov!==vsq[5])
                        $fatal(1,"dual overlay mode=%0d x=%0d y=%0d rgb=%h expected=%h de=%b expected=%b",
                            mode,col,row,out,pixels[5],od,ds[5]);
                    if(od && file!=0) $fwrite(file,"%c%c%c",out[23:16],out[15:8],out[7:0]);
                end
            end
            if(file!=0) $fclose(file);
            if(checked!=640*480) $fatal(1,"incomplete raster");
            if(mode==0 && (wave_pixels==0 || bar_pixels==0 || seen_bars!==64'hffffffffffffffff))
                $fatal(1,"missing waveform or spectrum bars");
        end
        $display("PASS dual visuals: full raster, 64 bars, gradient, transparent gap, waveform, sync alignment, hide and browse");
        $finish;
    end
    initial begin #130000000;$fatal(1,"dual visuals timeout");end
endmodule

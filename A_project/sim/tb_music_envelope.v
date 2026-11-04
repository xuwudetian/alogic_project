`timescale 1ns/1ps
module tb_music_envelope;
    reg clk=0,rst=1,hs=1,vs=1,de=0,av=0,hidden=0,alarm=0,panel=0;
    reg [23:0] rgb=0;
    reg signed [23:0] sample=0;
    wire wh,wv,wd,oh,ov,od;
    wire [23:0] wrgb,out;
    integer model_env=0,model_shape=0,model_head=0,model_count=0,last_height=0;
    integer heights[0:127];
    integer frame_number,n,j,row,col,mode,file,amp,old_head;
    integer checked,strokes,edges;
    reg [23:0] expected,pixels[0:5];
    reg [5:0] ds,hsq,vsq;
    always #20 clk=~clk;
    player_video #(.UI_ENABLE(1),.WAVE_MUSIC_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .brightness(9'sd0),.contrast(9'd128),.gain(9'd256),.display_valid(1'b1),
        .picture(3'd0),.scaled(1'b0),.auto_play(1'b0),.error_code(8'd0),.state_code(4'd0),
        .volume(4'd8),.interval_seconds(4'd3),.transition_mode(4'd0),.menu(3'd0),.modes({2'b00,hidden && !alarm,1'b1}),
        .audio_valid(av),.audio_sample(sample),.out_hs(wh),.out_vs(wv),.out_de(wd),.out_rgb(wrgb),
        .debug_status(60'd0),.audio_status(8'd0),.image_valid(1'b1),
        .ui_alarm(alarm),.ui_status(panel),.ui_directory(1'b0),.ui_browse(1'b0),
        .run_mode(2'd0),.source_resolution(40'h0064000480));
    audio_spectrum_overlay spectrum_display(
        .clk(clk),.rst(rst),.enable(alarm || !hidden),.alarm(alarm),
        .hs(wh),.vs(wv),.de(wd),.rgb_in(wrgb),.audio_valid(av),.audio_sample(sample),
        .hs_out(oh),.vs_out(ov),.de_out(od),.rgb_out(out));

    task commit_model;
        input integer peak;
        integer target,height;
        begin
            target=(peak>=14336 ? 56 : peak/256)*64;
            if(target>model_env) model_env=model_env+(target-model_env+1)/2;
            else model_env=model_env-(model_env-target+7)/8;
            if(model_env>model_shape) model_shape=model_shape+(model_env-model_shape+1)/2;
            else model_shape=model_shape-(model_shape-model_env+1)/2;
            height=(model_shape+32)/64;
            heights[model_head]=height;
            #1;
            if(dut.music_visual.envelope.history[model_head]!==((last_height<<6)|height))
                $fatal(1,"music history data frame=%0d",frame_number);
            last_height=height;model_head=(model_head+1)%128;
            if(model_count<128) model_count=model_count+1;
            if(dut.music_visual.envelope.envelope!==model_env || dut.music_visual.envelope.shape!==model_shape ||
               dut.music_visual.envelope.head!==model_head || dut.music_visual.envelope.history_count!==model_count)
                $fatal(1,"music envelope model mismatch");
        end
    endtask
    task boundary;
        input integer peak;
        begin
            @(negedge clk);de=0;vs=0;
            @(posedge clk);commit_model(peak);
            repeat(80) @(negedge clk);vs=1;repeat(12) @(negedge clk);
        end
    endtask
    task audio_frame;
        input integer magnitude;
        begin
            old_head=model_head;
            for(n=0;n<48;n=n+1) begin
                @(negedge clk);av=1;
                sample=(magnitude==32768 || n%2 ? -magnitude : magnitude)*256;
                @(negedge clk);av=0;repeat(2) @(negedge clk);
                if(dut.music_visual.envelope.head!==old_head) $fatal(1,"history moved in active audio");
            end
            boundary(magnitude);
        end
    endtask
    function integer history_point;
        input integer index;
        begin history_point=index<128-model_count ? 0 : heights[(model_head+index)%128];end
    endfunction
    function [23:0] background;
        input integer px,py;
        begin background={px[7:0],py[7:0],px[7:0]^py[7:0]};end
    endfunction
    function integer bar_level;
        input integer index;
        begin bar_level=20+(index*7)%101;end
    endfunction
    function [23:0] bar_color;
        input integer distance;
        begin
            case(distance/16)
                0:bar_color=24'h2088c0;1:bar_color=24'h2498c4;2:bar_color=24'h28a8c4;
                3:bar_color=24'h30b4bc;4:bar_color=24'h38beb0;5:bar_color=24'h40c4a0;
                6:bar_color=24'h50c890;default:bar_color=24'h68cc88;
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
        integer index,phase,p0,p1,a,b,lo,hi,distance;
        begin
            reference_pixel=alarm ? 0 : background(px,py);
            if(alarm || !hidden) begin
                if(px>=8 && px<632 && py>=216 && py<344) begin
                    index=px/5;phase=px%5;p0=history_point(index);
                    p1=history_point(index==127 ? 127 : index+1);
                    a=((5-phase)*p0+phase*p1+2)/5;b=((4-phase)*p0+(phase+1)*p1+2)/5;
                    lo=a<b ? a : b;hi=a>b ? a : b;distance=py>=280 ? py-280 : 280-py;
                    if(distance>=lo && distance<=hi+1) reference_pixel=alarm ? 24'hff2020 : 24'h1040b0;
                    else if(distance+1>=lo && distance<=hi+2) reference_pixel=alarm ? 24'hb01010 : 24'h3c94dc;
                end
                if(py>=352 && py<476 && px>=8 && px<632) begin
                    index=((px-8)/39)*4+((px-8)%39)/10;phase=((px-8)%39)%10;
                    if(phase>=1 && phase<8 && 475-py<(bar_level(index)/2)*2)
                        reference_pixel=alarm ? 24'hff2020 : blend_half(bar_color(475-py),background(px,py));
                end
            end
        end
    endfunction
    task raster;
        input integer test_mode;
        begin
            hidden=test_mode==1;alarm=test_mode==2;panel=test_mode==3;
            boundary(0);
            for(n=0;n<64;n=n+1) spectrum_display.displayed[n]=bar_level(n)/2;
            ds=0;hsq=6'b111111;vsq=6'b111111;
            for(n=0;n<6;n=n+1) pixels[n]=0;
            checked=0;strokes=0;edges=0;file=0;
            if(test_mode==0) begin
                file=$fopen("../doc/validation/music_envelope.ppm","wb");
                if(file==0) $fatal(1,"cannot create preview");
                $fwrite(file,"P6\n640 480\n255\n");
            end
            for(row=0;row<480;row=row+1) begin
                for(col=0;col<650;col=col+1) begin
                    @(negedge clk);de=col<640;hs=!(col>=642 && col<646);rgb=background(col,row);
                    expected=de ? reference_pixel(col,row) : 24'd0;
                    @(posedge clk);
                    // Status layer owns these pixels; check its exact priority in the composite.
                    if(test_mode==3 && dut.status_cover && dut.out_de) pixels[4]=dut.status_color;
                    for(j=5;j>0;j=j-1) pixels[j]=pixels[j-1];
                    pixels[0]=expected;ds={ds[4:0],de};hsq={hsq[4:0],hs};vsq={vsq[4:0],vs};
                    #1;
                    if(out!==pixels[5] || od!==ds[5] || oh!==hsq[5] || ov!==vsq[5])
                        $fatal(1,"music raster mode=%0d x=%0d y=%0d got=%h expected=%h",test_mode,col,row,out,pixels[5]);
                    if(od) begin
                        checked=checked+1;
                        if(out==24'h1040b0) strokes=strokes+1;
                        if(out==24'h3c94dc) edges=edges+1;
                        if(file!=0) $fwrite(file,"%c%c%c",out[23:16],out[15:8],out[7:0]);
                    end
                end
            end
            if(file!=0) $fclose(file);
            if(checked!=640*480) $fatal(1,"music incomplete raster");
            if(test_mode==0 && (strokes<1000 || edges<1000)) $fatal(1,"music missing strokes");
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        // Partial history must mask all unwritten RAM, including after a warm reset.
        for(frame_number=0;frame_number<3;frame_number=frame_number+1) audio_frame(4096);
        raster(0);
        for(frame_number=0;frame_number<160;frame_number=frame_number+1) begin
            amp=1024+((frame_number%37<18 ? frame_number%37 : 36-frame_number%37)*640);
            audio_frame(amp);
        end
        for(mode=0;mode<4;mode=mode+1) raster(mode);
        for(frame_number=0;frame_number<24;frame_number=frame_number+1) audio_frame(8192);
        if(last_height!=32) $fatal(1,"constant loudness is not steady");
        audio_frame(32768);
        audio_frame(32767);
        // A valid sample on the commit clock must belong to that frame, not disappear.
        @(negedge clk);sample=-24'sd8388608;av=1;vs=0;de=0;
        @(posedge clk);commit_model(32768);
        @(negedge clk);av=0;vs=1;repeat(4) @(negedge clk);
        for(frame_number=0;frame_number<200;frame_number=frame_number+1) boundary(0);
        if(model_env!=0 || model_shape!=0) $fatal(1,"music silence failed to settle");
        for(n=0;n<128;n=n+1) if(dut.music_visual.envelope.history[n]!==0) $fatal(1,"music stale history after silence");
        @(negedge clk);rst=1;repeat(4) @(negedge clk);rst=0;
        model_env=0;model_shape=0;model_head=0;model_count=0;last_height=0;
        raster(4);
        if(dut.wave_ready!==0 || dut.wave_valid!==0) $fatal(1,"legacy capture active in music build");
        $display("PASS music envelope: signed PCM, attack/release, ring wrap, blanking commit, partial history, silence, reset, full pixels, transparent blue/edge, alarm, status, spectrum and sync");
        $finish;
    end
    initial begin #150000000;$fatal(1,"music envelope timeout");end
endmodule

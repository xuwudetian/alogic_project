`timescale 1ns/1ps
module tb_video;
    reg clk=0,rst=1,hs=1,vs=1,de=0;
    reg [23:0] rgb=0;
    reg signed [8:0] brightness=0;
    reg [8:0] contrast=128,gain=256;
    reg audio_valid=0;
    reg signed [23:0] audio_sample=0;
    reg [3:0] modes=4'b0011;
    reg display_valid=1,image_valid=1,scaled=0;
    reg [7:0] error_code=0;
    reg [59:0] diagnostic={32'h1234abcd,10'd512,16'h55aa,2'd2};
    reg [183:0] expected_debug="L1234ABCD N200 H55AA R2";
    wire oh,ov,od;
    wire [23:0] out;
    integer i,line,seen=0;
    player_video #(.WAVE_DECIMATE_LOG2(1),.WAVE_GAIN_BOOST(0),.WAVE_TRIGGER_ENABLE(0),.WAVE_HALF_RATE(0),.WAVE_SMOOTH_ENABLE(0)) dut(
        .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .brightness(brightness),.contrast(contrast),.gain(gain),
        .display_valid(display_valid),.picture(3'd0),.scaled(scaled),
        .auto_play(1'b0),.error_code(error_code),.state_code(4'd0),
        .volume(4'd8),.interval_seconds(4'd3),.transition_mode(4'd0),.menu(3'd0),.modes(modes),
        .audio_valid(audio_valid),.audio_sample(audio_sample),
        .out_hs(oh),.out_vs(ov),.out_de(od),.out_rgb(out),
        .debug_status(diagnostic),.audio_status(8'd0),.image_valid(image_valid));
    always #5 clk=~clk;
    task check;
        input [23:0] input_rgb,expected;
        begin
            @(negedge clk);rgb=input_rgb;de=1;
            repeat(6) @(negedge clk);
            if(out!==expected || !od) $fatal(1,"color got %h expected %h",out,expected);
        end
    endtask
    function [34:0] reference_glyph;
        input [7:0] c;
        begin
            case(c)
                "O":reference_glyph=35'b01110_10001_10001_10001_10001_10001_01110;
                "T":reference_glyph=35'b11111_00100_00100_00100_00100_00100_00100;
                "U":reference_glyph=35'b10001_10001_10001_10001_10001_10001_01110;
                "S":reference_glyph=35'b01111_10000_10000_01110_00001_00001_11110;
                "R":reference_glyph=35'b11110_10001_10001_11110_10100_10010_10001;
                "C":reference_glyph=35'b01111_10000_10000_10000_10000_10000_01111;
                "X":reference_glyph=35'b10001_10001_01010_00100_01010_10001_10001;
                "0":reference_glyph=35'b01110_10001_10011_10101_11001_10001_01110;
                "1":reference_glyph=35'b00100_01100_00100_00100_00100_00100_01110;
                "2":reference_glyph=35'b01110_10001_00001_00010_00100_01000_11111;
                "4":reference_glyph=35'b00010_00110_01010_10010_11111_00010_00010;
                "6":reference_glyph=35'b01110_10000_10000_11110_10001_10001_01110;
                "8":reference_glyph=35'b01110_10001_10001_01110_10001_10001_01110;
                "9":reference_glyph=35'b01110_10001_10001_01111_00001_00001_01110;
                "-":reference_glyph=35'b00000_00000_00000_11111_00000_00000_00000;
                default:reference_glyph=0;
            endcase
        end
    endfunction
    task check_resolution;
        input valid_image,source_2x,visible_background,hide_text;
        input [7:0] error;
        input [95:0] expected_text;
        integer row,column,checked,dot_row,dot_col;
        reg [7:0] expected_char;
        reg [34:0] expected_dots;
        reg [23:0] expected_rgb;
        begin
            @(negedge clk);rst=1;de=0;vs=1;hs=1;
            rgb=24'h4080c0;brightness=0;contrast=128;gain=256;
            image_valid=valid_image;scaled=source_2x;display_valid=visible_background;
            modes=hide_text ? 4'b0011 : 4'b0010;error_code=error;
            repeat(3) @(negedge clk);rst=0;checked=0;
            for(row=0;row<60;row=row+1) begin
                for(column=0;column<650;column=column+1) begin
                    de=column<640;
                    @(negedge clk);
                    if(od && dut.yp[4]>=36 && dut.yp[4]<60) begin
                        expected_rgb=visible_background ? 24'h4080c0 : 24'd0;
                        if(!hide_text && dut.yp[4]>=40 && dut.yp[4]<56 && dut.xp[4]<96) begin
                            expected_char=expected_text[95-(dut.xp[4]/8)*8 -: 8];
                            if(dut.character!==expected_char)
                                $fatal(1,"resolution char x=%0d y=%0d got=%h expected=%h",
                                    dut.xp[4],dut.yp[4],dut.character,expected_char);
                            expected_dots=reference_glyph(expected_char);
                            dot_row=(dut.yp[4]-40)/2;dot_col=dut.xp[4]%8;
                            expected_rgb=visible_background ? 24'h204060 : 24'd0;
                            if(dot_row<7 && dot_col<5 && expected_dots[34-dot_row*5-dot_col])
                                expected_rgb=error!=0 ? 24'hff7070 : 24'hf0f8ff;
                        end
                        if(out!==expected_rgb)
                            $fatal(1,"resolution pixel x=%0d y=%0d got=%h expected=%h",
                                dut.xp[4],dut.yp[4],out,expected_rgb);
                        checked=checked+1;
                    end
                    if(!od && out!==0) $fatal(1,"resolution blanking");
                end
            end
            if(checked!=24*640) $fatal(1,"resolution coverage: %0d",checked);
        end
    endtask
    function integer wave_reference;
        input integer pattern,index;
        begin
            case(pattern)
                0:wave_reference=16+index*3/4;
                1:wave_reference=(index%2)==0 ? 12 : 116; // steep rising/falling segments
                default:wave_reference=64;
            endcase
        end
    endfunction
    function [23:0] background;
        input integer px,py;
        begin background={px[7:0],py[7:0],(px[7:0]^py[7:0])};end
    endfunction
    task frame_boundary;
        begin
            de=0;vs=0;repeat(2) @(negedge clk);vs=1;
            repeat(6) @(negedge clk);
        end
    endtask
    task feed_wave;
        input integer pattern;
        integer n;
        begin
            for(n=0;n<256;n=n+1) begin
                audio_valid=1;audio_sample=(64-wave_reference(pattern,n/2))*149797;
                @(negedge clk);audio_valid=0;audio_sample=24'h7fffff;
                repeat(2) @(negedge clk); // invalid samples must not enter the average
            end
            if(!dut.wave_ready) $fatal(1,"wave block not completed");
            for(n=0;n<128;n=n+1)
                if(dut.wave[{dut.capture_bank,7'd0}+n][6:0]!==wave_reference(pattern,n))
                    $fatal(1,"wave capture point %0d pattern %0d",n,pattern);
        end
    endtask
    task scan_wave_frame;
        input integer pattern;
        input visible;
        integer row,column,wx,wy,idx,p0,p1,phase,a,b,checked,line_pixels;
        reg [23:0] expected_pixel;
        begin
            checked=0;line_pixels=0;
            for(row=0;row<480;row=row+1) begin
                for(column=0;column<650;column=column+1) begin
                    de=column<640;rgb=background(column,row);
                    @(negedge clk);
                    if(od) begin
                        wx=dut.xp[4];wy=dut.yp[4];expected_pixel=background(wx,wy);
                        if(wx<640 && wy>=216 && wy<344) begin
                            idx=wx/5;phase=wx%5;
                            p0=wave_reference(pattern,idx);
                            p1=wave_reference(pattern,idx==127 ? 127 : idx+1);
                            a=((5-phase)*p0+phase*p1+2)/5;
                            b=((4-phase)*p0+(phase+1)*p1+2)/5;
                            if(visible && wx>=8 && wx<632 &&
                               ((wy-216>=a && wy-216<=b+1) || (wy-216>=b && wy-216<=a+1))) begin
                                expected_pixel=24'h1040b0;line_pixels=line_pixels+1;
                            end
                            checked=checked+1;
                        end
                        if(out!==expected_pixel)
                            $fatal(1,"wave pixel pattern=%0d x=%0d y=%0d got=%h expected=%h",pattern,wx,wy,out,expected_pixel);
                    end else if(out!==0) $fatal(1,"wave blanking");
                end
            end
            if(checked!=640*128) $fatal(1,"wave region coverage %0d",checked);
            $display("wave frame pattern=%0d visible=%0d curve_pixels=%0d",pattern,visible,line_pixels);
        end
    endtask
    task check_wave_overlay;
        input integer pattern;
        reg saved_bank;
        begin
            @(negedge clk);rst=1;de=0;vs=1;audio_valid=0;
            brightness=0;contrast=128;gain=256;display_valid=1;modes=4'b0001;
            repeat(3) @(negedge clk);rst=0;
            feed_wave(pattern);
            if(dut.wave_valid) $fatal(1,"premature waveform swap");
            frame_boundary;saved_bank=dut.display_bank;
            feed_wave(2); // next bank holds silence while the current frame is unchanged
            if(dut.display_bank!==saved_bank) $fatal(1,"wave changed outside frame boundary");
            scan_wave_frame(pattern,1);
            frame_boundary;
            if(dut.display_bank===saved_bank) $fatal(1,"wave swap missing");
            scan_wave_frame(2,1); // old ramp/steep lines must leave no pixels behind
            modes=4'b0011;frame_boundary;scan_wave_frame(2,0);
            modes=4'b0001;
            repeat(1250002) @(negedge clk);
            if(dut.wave_valid || dut.wave_ready || dut.sample_index!=0 || dut.decimation!=0)
                $fatal(1,"stopped audio left stale waveform/capture");
            frame_boundary;scan_wave_frame(2,0);
            feed_wave(2);frame_boundary;
            if(!dut.wave_valid) $fatal(1,"audio restart did not recover waveform");
        end
    endtask
    task check_pair_average;
        integer n;
        reg signed [23:0] first_sample,second_sample;
        reg [6:0] expected_height;
        begin
            @(negedge clk);rst=1;de=0;vs=1;audio_valid=0;
            repeat(3) @(negedge clk);rst=0;
            for(n=0;n<5;n=n+1) begin
                case(n)
                    0:begin first_sample=24'h7fffff;second_sample=24'h7fffff;expected_height=8;end
                    1:begin first_sample=24'h800000;second_sample=24'h800000;expected_height=120;end
                    2:begin first_sample=24'h200000;second_sample=-24'sh200000;expected_height=64;end
                    3:begin first_sample=24'h200000;second_sample=0;expected_height=57;end
                    4:begin first_sample=-24'sh200000;second_sample=0;expected_height=71;end
                endcase
                audio_valid=1;audio_sample=first_sample;@(negedge clk);
                audio_valid=0;repeat(4) @(negedge clk);
                audio_valid=1;audio_sample=second_sample;@(negedge clk);audio_valid=0;
                @(negedge clk); // Registered visualization input.
                if(dut.wave[{dut.capture_bank,7'd0}+n][6:0]!==expected_height)
                    $fatal(1,"pair average/clamp %0d got=%0d expected=%0d",n,dut.wave[{dut.capture_bank,7'd0}+n][6:0],expected_height);
            end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        check(24'h0080ff,24'h0080ff);
        brightness=96;check(24'h0080ff,24'h60e0ff);
        brightness=-96;check(24'h0080ff,24'h00209f);
        brightness=0;contrast=256;check(24'h4080c0,24'h0080ff);
        // Expanded range: clipping, fine steps, neutral center, and 3x contrast.
        contrast=128;brightness=240;check(24'h0080ff,24'hf0ffff);
        brightness=-240;check(24'h0080ff,24'h00000f);
        brightness=4;check(24'h4070a0,24'h4474a4);
        brightness=-4;check(24'h4070a0,24'h3c6c9c);
        brightness=0;contrast=0;check(24'h0080ff,24'h808080);
        contrast=384;check(24'h6080a0,24'h2080e0);
        check(24'h0080ff,24'h0080ff);
        contrast=132;check(24'h6080a0,24'h5f80a1);
        brightness=255;contrast=384;check(24'h0080ff,24'hffffff);
        brightness=-255;check(24'h0080ff,24'h000000);
        contrast=0;brightness=255;check(24'h0080ff,24'hffffff);
        brightness=-255;check(24'h0080ff,24'h000000);
        brightness=0;
        contrast=128;gain=128;check(24'h4080fe,24'h20407f);
        @(negedge clk);de=0;
        repeat(6) @(negedge clk);
        if(od || out!==0) $fatal(1,"blanking alignment");
        // Same PCM samples as the HDMI input; a positive signal moves up.
        audio_sample=24'sh200000;audio_valid=1;
        repeat(256) @(negedge clk);
        audio_valid=0;repeat(2) @(negedge clk);vs=0;repeat(2) @(negedge clk);vs=1;
        if(!dut.wave_valid || dut.wave[{dut.display_bank,7'd0}][6:0]!==7'd50)
            $fatal(1,"waveform is not derived from signed PCM");
        @(negedge clk);rst=1;
        repeat(3) @(negedge clk);rst=0;modes=4'b0010;
        for(line=0;line<20;line=line+1) begin
            de=1;repeat(640) @(negedge clk);
            de=0;repeat(10) @(negedge clk);
        end
        de=1;
        repeat(646) begin
            @(negedge clk);
            if(od && dut.yp[4]==20 && dut.xp[4]>=384 && dut.xp[4]<568) begin
                if(dut.character!==expected_debug[183-(dut.xp[4]/8-48)*8 -: 8])
                    $fatal(1,"diagnostic OSD character at x=%0d",dut.xp[4]);
                if(dut.character!=" " && dut.dots==0) $fatal(1,"missing diagnostic glyph");
                seen=seen+1;
            end
        end
        if(seen!=184) $fatal(1,"diagnostic field bounds: %0d pixels",seen);
        check_resolution(1,0,1,0,8'h00,"OUT  640X480");
        check_resolution(1,1,1,0,8'h00,"OUT  640X480");
        check_resolution(0,0,0,0,8'h20,"OUT ----X---");
        // Browsing can expose video before the first full-screen image is committed.
        check_resolution(0,1,1,0,8'h00,"OUT ----X---");
        check_resolution(1,1,1,1,8'h00,"OUT  640X480");
        check_resolution(1,0,1,0,8'h37,"OUT  640X480");
        check_wave_overlay(0);
        check_wave_overlay(1);
        check_pair_average;
        $display("PASS video: color/OSD, 128-point capture, blue pixel interpolation, changing-background alignment, no stale pixels after swap, idle/restart, signed averaging and clipping");
        $finish;
    end
endmodule

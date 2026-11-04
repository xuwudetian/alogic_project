`timescale 1ns/1ps
// Physical key gestures, committed settings, alarm ownership, and OSD raster.
module tb_audio_selection;
    reg clk=0,rst=1,tick=0,key2=1,key3=1,key4=1;
    reg network_alarm=0,sensor_alarm=0,sensor_clear=0;
    reg [9:0] x=0;reg [8:0] y=0;
    wire [1:0] audio_select,run_mode;
    wire [2:0] menu;wire [3:0] modes,volume,interval_seconds,transition_mode;
    wire signed [8:0] brightness;wire [8:0] contrast;
    wire directory,status_panel,alarm,browse,next_toggle,auto_toggle;
    wire cover_on;wire [23:0] color;
    reg [23:0] raster[0:286719];
    integer track,n,xx,yy,cell_x,file,index,expected;
    reg [23:0] pixel;
    always #5 clk=~clk;
    player_control #(.NETWORK_ENABLE(1),.SENSOR_ENABLE(1),
        .DEBOUNCE_CYCLES(2),.LONG_CYCLES(40)) controls(
        .clk(clk),.rst(rst),.frame_tick(tick),.key_next(key2),.key_menu(key3),.key_auto(key4),
        .switches(4'd0),.available(6'h3f),.thumbnail_valid(6'h3f),.auto_active(1'b1),
        .sensor_alarm(sensor_alarm),.sensor_alarm_clear(sensor_clear),.network_alarm(network_alarm),
        .playback_fault(1'b0),.remote_valid(1'b0),.remote_command(8'd0),.remote_argument(24'd0),
        .audio_select(audio_select),.run_mode(run_mode),.menu(menu),.modes(modes),
        .brightness(brightness),.contrast(contrast),.volume(volume),.interval_seconds(interval_seconds),
        .transition_mode(transition_mode),.directory(directory),.status_panel(status_panel),
        .alarm(alarm),.browse(browse),.next_toggle(next_toggle),.auto_toggle(auto_toggle));
    player_status_osd osd(.clk(clk),.rst(rst),.x(x),.y(y),.brightness(brightness),
        .bright_digits(12'h000),.contrast_digits(12'h128),.picture(3'd5),.scaled(1'b1),
        .auto_play(1'b1),.run_mode(run_mode),.error_code(8'd0),.audio_status(8'd1),.state_code(4'd8),
        .volume(volume),.interval_seconds(interval_seconds),.menu(menu),.modes(modes),
        .audio_select(audio_select),.transition_mode(transition_mode),.directory(directory),
        .status_panel(status_panel),.alarm(alarm),.browse(browse),.image_valid(1'b1),
        .source_resolution(40'h0192001080),.debug_status(60'd0),.time_digits(24'd0),
        .background_rgb(24'h304050),.cover_on(cover_on),.color(color));
    task press;input integer key,cycles;begin
        @(negedge clk);case(key) 2:key2=0;3:key3=0;4:key4=0;endcase
        repeat(cycles) @(negedge clk);key2=1;key3=1;key4=1;repeat(8) @(negedge clk);
    end endtask
    task frame;begin
        @(negedge clk);tick=1;@(negedge clk);tick=0;repeat(2) @(negedge clk);
    end endtask
    task check_audio;input integer wanted;begin
        if(audio_select!==wanted || menu!==6 || !status_panel || directory || alarm ||
           brightness!==0 || contrast!==128 || volume!==4 || interval_seconds!==3 ||
           transition_mode!==0 || run_mode!==2 || browse || next_toggle || auto_toggle)
            $fatal(1,"audio edit changed unrelated state or selection expected=%0d got=%0d",wanted,audio_select);
        for(cell_x=0;cell_x<32;cell_x=cell_x+1) begin
            @(negedge clk);x=184+cell_x;y=296;#1;
            if(osd.code!==(cell_x<16 ? 111 : 158) || osd.column!==(cell_x%16) ||
               !osd.text_on || osd.base!==24'ha5dfd9)
                $fatal(1,"audio Chinese glyph or highlight");
        end
        for(cell_x=0;cell_x<24;cell_x=cell_x+1) begin
            @(negedge clk);x=432+cell_x;y=296;#1;
            expected=cell_x<8 ? 17+wanted : cell_x<16 ? 15 : 20;
            if(osd.code!==expected || osd.column!==(cell_x%8) || !osd.text_on)
                $fatal(1,"audio fraction label expected=%0d got=%0d",expected,osd.code);
        end
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;frame;
        if(audio_select!==0) $fatal(1,"default audio must be 1/4");
        press(3,55);frame;
        for(n=1;n<=6;n=n+1) begin
            press(3,8);if(menu!==n-1) $fatal(1,"menu changed before frame");
            frame;if(menu!==n) $fatal(1,"seven-item settings order");
        end
        for(track=0;track<4;track=track+1) begin
            if(track!=0) begin
                press(2,8);if(audio_select!==track-1) $fatal(1,"audio changed before frame");frame;
            end
            check_audio(track);
            // Four 320x224 panels form a single 640x448 visual QA artifact.
            for(n=0;n<71684;n=n+1) begin
                @(negedge clk);
                if(n<71680) begin x=160+n%320;y=128+n/320;end
                else begin x=0;y=400;end
                @(posedge clk);#1;
                if(n>=4) begin
                    if(!cover_on) $fatal(1,"panel pipeline lost raster pixel");
                    raster[track*71680+n-4]=color;
                end
            end
        end
        file=$fopen("../doc/validation/audio_selection.ppm","wb");
        if(!file) $fatal(1,"cannot open audio selection raster");
        $fwrite(file,"P6\n640 448\n255\n");
        for(yy=0;yy<448;yy=yy+1) for(xx=0;xx<640;xx=xx+1) begin
            index=(yy/224*2+xx/320)*71680+(yy%224)*320+xx%320;
            pixel=raster[index];$fwrite(file,"%c%c%c",pixel[23:16],pixel[15:8],pixel[7:0]);
        end
        $fclose(file);
        press(2,8);if(audio_select!==3) $fatal(1,"forward wrap not frame atomic");frame;check_audio(0);
        for(track=3;track>=0;track=track-1) begin
            press(4,8);frame;check_audio(track);
        end
        // Consecutive key edits coalesce at the next display-frame boundary.
        press(2,8);press(2,8);if(audio_select!==0) $fatal(1,"pending audio edits leaked");frame;check_audio(2);
        network_alarm=1;frame;if(!alarm || audio_select!==2) $fatal(1,"network alarm entry");
        press(2,8);press(3,8);press(4,8);frame;
        if(!alarm || audio_select!==2 || menu!==6) $fatal(1,"network alarm keys changed audio");
        network_alarm=0;frame;check_audio(2);
        sensor_alarm=1;@(negedge clk);sensor_alarm=0;frame;
        if(!alarm) $fatal(1,"sensor alarm entry");
        sensor_clear=1;@(negedge clk);sensor_clear=0;frame;check_audio(2);
        press(3,55);frame;if(!directory || status_panel || audio_select!==2) $fatal(1,"settings return lost audio");
        press(2,8);frame;press(4,8);frame;if(!alarm) $fatal(1,"manual alarm entry");
        press(4,8);frame;if(alarm || audio_select!==2) $fatal(1,"alarm KEY4 edited audio");
        press(3,55);frame;check_audio(2);
        press(3,8);frame;if(menu!==0 || audio_select!==2) $fatal(1,"seven-field wrap lost selection");
        @(negedge clk);rst=1;@(negedge clk);
        if(audio_select!==0 || menu!==0) $fatal(1,"audio reset");
        $display("PASS audio selection: 1/4 default, all four labels, both key wraps, seven-item menu, frame commits, sensor/network/manual alarm restore, retained settings, OSD raster");
        $finish;
    end
    initial begin #10000000;$fatal(1,"audio selection timeout");end
endmodule

`timescale 1ns/1ps
module tb_edit_ui;
    reg clk=0,rst=1,kn=1,ka=1,km=1,tick=0,hs=1,vs=1,de=0;
    reg [3:0] sw=9;
    wire [2:0] menu;
    wire [3:0] volume,interval_seconds,modes,transition_mode;
    wire signed [8:0] brightness,manual_brightness;
    reg light_valid=0,light_online=0;
    reg [15:0] light_raw=320;
    wire [8:0] contrast;
    wire browse,directory,alarm,status_panel;
    integer x,y,seen=0;
    always #5 clk=~clk;
    player_control #(.DEBOUNCE_CYCLES(3),.LONG_CYCLES(30)) control(
        .clk(clk),.rst(rst),.frame_tick(tick),.key_next(kn),.key_auto(ka),.key_menu(km),.switches(sw),
        .brightness(manual_brightness),.contrast(contrast),.volume(volume),.interval_seconds(interval_seconds),
        .transition_mode(transition_mode),.menu(menu),.modes(modes),.available(6'h3f),.thumbnail_valid(6'h3f),.auto_active(1'b0),
        .browse(browse),.directory(directory),.alarm(alarm),.status_panel(status_panel));
    player_sensor_policy sensor_policy(.clk(clk),.rst(rst),.frame_tick(tick),
        .light_valid(light_valid),.light_online(light_online),.light_raw(light_raw),
        .manual_brightness(manual_brightness),.edit_mode(modes[3]),.alarm(alarm),
        .sample_valid(1'b0),.sample(12'd2048),.brightness(brightness));
    player_video #(.UI_ENABLE(1)) video(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(24'h123456),
        .brightness(brightness),.contrast(contrast),.volume(volume),.interval_seconds(interval_seconds),
        .transition_mode(transition_mode),.menu(menu),.modes(modes),.gain(9'd256),.display_valid(1'b1),.picture(3'd0),.scaled(1'b0),
        .auto_play(1'b0),.error_code(8'd0),.state_code(4'd8),.audio_valid(1'b0),.audio_sample(24'd0),
        .debug_status(60'd0),.audio_status(8'd0),.image_valid(1'b1),.ui_directory(directory),
        .ui_status(status_panel),.ui_alarm(alarm),.ui_browse(browse));
    task press(input integer key);
        begin
            @(negedge clk);case(key) 2:kn=0;3:km=0;4:ka=0;endcase
            repeat(10) @(negedge clk);kn=1;km=1;ka=1;repeat(10) @(negedge clk);
        end
    endtask
    task hold_menu;begin
        @(negedge clk);km=0;repeat(40) @(negedge clk);km=1;repeat(10) @(negedge clk);
    end endtask
    task frame;begin tick=1;@(negedge clk);tick=0;@(negedge clk);end endtask
    task check_parameter_text;
        input [39:0] expected_brightness;
        input [31:0] expected_contrast;
        integer row,col,checked;
        begin
            checked=0;vs=0;repeat(10) @(negedge clk);vs=1;
            for(row=0;row<208;row=row+1) begin
                for(col=0;col<650;col=col+1) begin
                    @(negedge clk);de=col<640;
                    @(posedge clk);#1;
                    if(de && video.x[2:0]==0) begin
                        if(video.y==4 && video.x>=48 && video.x<80) begin
                            if(video.chinese_osd.status.code!==0)
                                $fatal(1,"removed top brightness still visible");
                            checked=checked+1;
                        end
                        if(video.y==176 && video.x>=424 && video.x<456) begin
                            if(video.chinese_osd.status.code+32!==expected_brightness[31-((video.x-424)/8)*8 -: 8])
                                $fatal(1,"panel brightness digits");
                            checked=checked+1;
                        end
                        if(video.y==4 && video.x>=224 && video.x<248) begin
                            if(video.chinese_osd.status.code!==0)
                                $fatal(1,"removed top contrast still visible");
                            checked=checked+1;
                        end
                        if(video.y==196 && video.x>=432 && video.x<456) begin
                            if(video.chinese_osd.status.code+32!==expected_contrast[23-((video.x-432)/8)*8 -: 8])
                                $fatal(1,"panel contrast digits");
                            checked=checked+1;
                        end
                    end
                end
            end
            @(negedge clk);de=0;repeat(10) @(negedge clk);
            if(checked!=14) $fatal(1,"missing parameter text coverage %0d",checked);
        end
    endtask
    always @(negedge clk) if(!rst && menu==2 && video.x==184 && video.y==216 && de) begin
        if(video.chinese_osd.status.code!=111 || video.chinese_osd.status.base!=24'ha5dfd9) $fatal(1,"selected edit field not visible");
        seen=seen+1;
    end
    initial begin
        repeat(3) @(negedge clk);rst=0;repeat(5) @(negedge clk);
        hold_menu;press(3);press(3);press(2);
        if(menu!=0 || volume!=4 || contrast!=128) $fatal(1,"menu/value changed before frame");
        frame;
        if(menu!=2 || volume!=5 || !video.panel_active || !status_panel || !modes[0])
            $fatal(1,"same-frame edit routing or automatic panel failed");
        vs=0;repeat(10) @(negedge clk);vs=1;
        for(y=0;y<250;y=y+1) begin
            for(x=0;x<650;x=x+1) begin @(negedge clk);de=x<640;end
        end
        de=0;repeat(10) @(negedge clk);
        if(seen!=1) $fatal(1,"missing selected field pixels");
        sw=8;repeat(5) @(negedge clk);frame;
        repeat(5) press(3);repeat(64) press(2);
        press(3);repeat(64) press(2);frame;
        frame;check_parameter_text("B+255","C384");
        repeat(6) press(3);repeat(128) press(4);
        press(3);repeat(96) press(4);frame;
        frame;check_parameter_text("B-255","C000");
        sw=1;repeat(5) @(negedge clk);hold_menu;press(2);frame;
        if(video.panel_active) $fatal(1,"automatic panel failed to close");
        press(4);frame;if(!alarm || video.panel_active) $fatal(1,"alarm display priority");
        // Real sensor policy -> video decimal conversion -> Chinese settings OSD.
        // Reproduce changing illumination while the settings window stays open.
        @(negedge clk);rst=1;kn=1;ka=1;km=1;sw=0;
        repeat(3) @(negedge clk);rst=0;repeat(5) @(negedge clk);
        hold_menu;frame;frame;
        if(!status_panel || !modes[3]) $fatal(1,"light/settings setup failed");
        check_parameter_text("B+000","C128");
        @(negedge clk);light_online=1;light_valid=1;light_raw=64;
        @(negedge clk);light_valid=0;
        repeat(32) frame;
        if(brightness!=32 || manual_brightness!=0) $fatal(1,"settings suppressed automatic ramp or rewrote manual baseline");
        check_parameter_text("B+032","C128");
        repeat(32) frame;check_parameter_text("B+064","C128");
        press(2);frame;frame;
        if(manual_brightness!=4 || brightness!=68) $fatal(1,"manual edit lost automatic boost");
        check_parameter_text("B+068","C128");
        @(negedge clk);light_valid=1;light_raw=320;
        @(negedge clk);light_valid=0;
        repeat(64) frame;
        if(brightness!=4 || manual_brightness!=4 || !status_panel) $fatal(1,"light recovery failed while settings open");
        check_parameter_text("B+004","C128");
        $display("PASS edit UI: live light-driven settings digits 000->032->064->068->004, manual baseline preserved, atomic edits, hidden-SW1 settings and alarm priority");$finish;
    end
    initial begin #20000000;$fatal(1,"edit UI timeout");end
endmodule

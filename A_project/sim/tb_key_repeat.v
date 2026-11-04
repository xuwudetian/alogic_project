`timescale 1ns/1ps
module tb_key_repeat;
    reg clk=0,rst=1,tick=0,kn=1,ka=1,km=1,network_alarm=0;
    wire signed [8:0] bright;
    wire [8:0] contrast;
    wire [3:0] volume,interval_seconds,transition_mode;
    wire [1:0] run_mode,audio_select;
    wire [2:0] menu;
    wire directory,status_panel,alarm,next_toggle;
    integer field;
    always #5 clk=~clk;
    player_control #(.NETWORK_ENABLE(1),.DEBOUNCE_CYCLES(3),.LONG_CYCLES(30)) dut(
        .clk(clk),.rst(rst),.frame_tick(tick),.key_next(kn),.key_auto(ka),.key_menu(km),
        .switches(4'd0),.available(9'h1ff),.thumbnail_valid(9'h1ff),.auto_active(1'b0),
        .sensor_alarm(1'b0),.sensor_alarm_clear(1'b0),.playback_fault(1'b0),
        .remote_valid(1'b0),.remote_command(8'd0),.remote_argument(24'd0),
        .network_alarm(network_alarm),.current_picture(4'd0),.brightness(bright),
        .contrast(contrast),.volume(volume),.interval_seconds(interval_seconds),.menu(menu),
        .directory(directory),.status_panel(status_panel),.alarm(alarm),
        .next_toggle(next_toggle),.transition_mode(transition_mode),.run_mode(run_mode),
        .audio_select(audio_select));

    task down(input integer key);
        begin
            @(negedge clk);
            case(key) 2:kn=0;3:km=0;4:ka=0;endcase
            repeat(10) @(negedge clk);
        end
    endtask
    task release_keys;
        begin @(negedge clk);kn=1;ka=1;km=1;repeat(10) @(negedge clk);end
    endtask
    task press(input integer key);
        begin down(key);release_keys;end
    endtask
    task hold_menu;
        begin down(3);repeat(30) @(negedge clk);release_keys;end
    endtask
    task frame;
        begin
            @(negedge clk);tick=1;@(negedge clk);tick=0;
            repeat(8) @(negedge clk);
        end
    endtask
    task check_other(input integer key);
        begin
            down(key);repeat(200) frame;
            case(menu)
                2: if(volume!=(key==2 ? 5 : 4)) $fatal(1,"volume repeated");
                3: if(interval_seconds!=(key==2 ? 4 : 3)) $fatal(1,"interval repeated");
                4: if(transition_mode!=(key==2 ? 1 : 0)) $fatal(1,"transition repeated");
                5: if(run_mode!=(key==2 ? 1 : 2)) $fatal(1,"run mode repeated");
                6: if(audio_select!=(key==2 ? 1 : 0)) $fatal(1,"audio selection repeated");
            endcase
            release_keys;frame;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;repeat(5) @(negedge clk);
        // A sub-debounce bounce still cannot open the directory.
        @(negedge clk);kn=0;@(negedge clk);kn=1;repeat(10) @(negedge clk);frame;
        if(directory) $fatal(1,"bounce accepted");
        hold_menu;frame;
        if(!status_panel || menu!=0) $fatal(1,"settings entry");

        down(2);
        if(bright!=0) $fatal(1,"press published before frame");
        repeat(48) frame;
        if(bright!=4) $fatal(1,"first brightness hold delay: %0d",bright);
        frame;if(bright!=8) $fatal(1,"brightness first repeat step");
        repeat(11) frame;if(bright!=8) $fatal(1,"repeat interval too short");
        frame;if(bright!=12) $fatal(1,"brightness repeat step");
        release_keys;repeat(100) frame;
        if(bright!=12) $fatal(1,"brightness changed after release");
        press(4);frame;if(bright!=8) $fatal(1,"short decrease changed");
        down(4);repeat(48) frame;
        if(bright!=4) $fatal(1,"decrease initial step/delay");
        frame;if(bright!=0) $fatal(1,"brightness hold decrease");
        repeat(1800) frame;if(bright!=-255) $fatal(1,"brightness lower saturation");
        release_keys;frame;
        down(2);repeat(1800) frame;
        if(bright!=255) $fatal(1,"brightness upper saturation");
        release_keys;frame;

        press(3);frame;if(menu!=1) $fatal(1,"contrast selection");
        down(2);repeat(48) frame;
        if(contrast!=132) $fatal(1,"contrast initial step/delay");
        frame;if(contrast!=136) $fatal(1,"contrast hold increase");
        repeat(1000) frame;if(contrast!=384) $fatal(1,"contrast upper saturation");
        release_keys;frame;
        down(4);repeat(48) frame;
        if(contrast!=380) $fatal(1,"contrast decrease initial step/delay");
        frame;if(contrast!=376) $fatal(1,"contrast hold decrease");
        repeat(1300) frame;if(contrast!=0) $fatal(1,"contrast lower saturation");
        release_keys;repeat(100) frame;
        if(contrast!=0) $fatal(1,"contrast changed after release");
        press(2);frame;if(contrast!=4) $fatal(1,"contrast short step changed");

        // All five other settings retain one action per physical press.
        for(field=2;field<=6;field=field+1) begin
            press(3);frame;if(menu!=field) $fatal(1,"menu navigation");
            check_other(2);check_other(4);
        end
        press(3);frame;
        // A network alarm still overrides settings; KEY4 cannot clear it.
        network_alarm=1;frame;down(4);repeat(100) frame;
        if(!alarm || bright!=255 || contrast!=4) $fatal(1,"network alarm isolation");
        release_keys;network_alarm=0;frame;
        if(alarm || !status_panel) $fatal(1,"network alarm recovery");
        // Exit settings while KEY2 is still held: repeats cannot navigate.
        down(2);repeat(50) frame;down(3);repeat(30) @(negedge clk);
        @(negedge clk);km=1;repeat(10) @(negedge clk);frame;
        if(!directory || status_panel) $fatal(1,"settings exit");
        repeat(200) frame;
        if(!directory || status_panel || alarm) $fatal(1,"repeat navigated after settings exit");
        release_keys;
        down(2);repeat(200) frame;
        if(directory || status_panel || alarm || next_toggle) $fatal(1,"held key leaked into playback");
        release_keys;down(4);repeat(200) frame;
        if(!alarm) $fatal(1,"held alarm key repeated its clear action");
        release_keys;press(4);frame;if(alarm) $fatal(1,"alarm clear changed");
        $display("PASS key_repeat: 48-frame hold, 12-frame repeat, +/-4 steps, both fields/directions, saturation, release, other settings, playback and network-alarm isolation");
        $finish;
    end
    initial begin #5000000;$fatal(1,"key repeat timeout");end
endmodule

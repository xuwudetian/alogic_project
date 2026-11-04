`timescale 1ns/1ps
module tb_sensor_alarm;
    reg clk=0,rst=1,frame_tick=0,sensor=0,sensor_clear=0,key2=1,key3=1,key4=1;
    reg [3:0] switches=4'b1000;
    wire alarm,browse,directory,directory_run,status_panel,next_toggle,auto_toggle,select_toggle;
    wire [1:0] directory_focus,run_mode;wire [2:0] menu;
    wire [2:0] focus,select_index;
    wire signed [8:0] brightness;
    wire [8:0] contrast;
    wire [3:0] volume,interval_seconds;
    wire [63:0] context_state={browse,directory,directory_run,status_panel,focus,directory_focus,run_mode,
        menu,brightness,contrast,volume,interval_seconds,next_toggle,auto_toggle,select_toggle,select_index};
    reg [63:0] saved_state;
    always #5 clk=~clk;
    player_control #(.SENSOR_ENABLE(1),.DEBOUNCE_CYCLES(2),.LONG_CYCLES(100)) dut(
        .clk(clk),.rst(rst),.frame_tick(frame_tick),.sensor_alarm(sensor),.sensor_alarm_clear(sensor_clear),
        .key_next(key2),.key_menu(key3),.key_auto(key4),.switches(switches),
        .available(6'h3f),.thumbnail_valid(6'h3f),.auto_active(1'b0),.alarm(alarm),
        .browse(browse),.directory(directory),.directory_run(directory_run),.status_panel(status_panel),
        .focus(focus),.directory_focus(directory_focus),.run_mode(run_mode),.menu(menu),
        .brightness(brightness),.contrast(contrast),.volume(volume),.interval_seconds(interval_seconds),
        .next_toggle(next_toggle),.auto_toggle(auto_toggle),.select_toggle(select_toggle),.select_index(select_index));
    task frame;
        begin frame_tick=1;@(negedge clk);frame_tick=0;@(negedge clk);end
    endtask
    task press(input integer key);
        begin
            case(key) 2:key2=0;3:key3=0;4:key4=0;endcase
            repeat(10) @(negedge clk);key2=1;key3=1;key4=1;
            repeat(10) @(negedge clk);frame;
        end
    endtask
    task hold_menu;
        begin
            key3=0;repeat(120) @(negedge clk);key3=1;
            repeat(10) @(negedge clk);frame;
        end
    endtask
    task trip;
        begin
            sensor=1;@(negedge clk);sensor=0;@(negedge clk);
            if(alarm) $fatal(1,"sensor alarm changed mid-frame");
            frame;if(!alarm) $fatal(1,"sensor failed to enter warning");
        end
    endtask
    task clear_pulse;
        begin sensor_clear=1;@(negedge clk);sensor_clear=0;@(negedge clk);end
    endtask
    task round_trip;
        begin
            saved_state=context_state;trip;
            // Other menu keys must not change the saved context while alarmed.
            press(2);press(3);clear_pulse;
            if(!alarm) $fatal(1,"automatic exit changed mid-frame");
            frame;
            if(alarm || context_state!==saved_state) $fatal(1,"automatic exit lost previous screen/parameters");
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;repeat(10) @(negedge clk);frame;
        if(run_mode!=2 || status_panel) $fatal(1,"AUTO boot or reserved SW4 incorrect");
        hold_menu;
        press(2);if(brightness!=4) $fatal(1,"edit setup failed");
        round_trip; // Edit mode and modified brightness survive automatic return.
        trip;press(4);
        if(alarm || dut.bright_edit!=4) $fatal(1,"KEY4 also edited brightness when exiting");
        switches=0;repeat(4) @(negedge clk);frame;
        if(!status_panel) $fatal(1,"SW4 changed settings state");
        hold_menu;press(2);round_trip;
        press(4);if(!alarm || dut.alarm_from_sensor) $fatal(1,"manual alarm source incorrect");
        sensor=1;@(negedge clk);sensor=0;clear_pulse;frame;
        if(!alarm) $fatal(1,"quiet detector closed a manual alarm");
        press(4);if(alarm) $fatal(1,"KEY4 failed to exit manual alarm");
        clear_pulse;frame;if(alarm) $fatal(1,"stale clear re-entered alarm");
        press(2);round_trip;
        press(4);if(!browse) $fatal(1,"preview setup failed");
        repeat(5) press(3);if(focus!=5) $fatal(1,"sixth preview setup failed");round_trip;
        press(2);press(3);press(4);
        if(directory_run || directory || browse || run_mode!=2) $fatal(1,"continue playback changed AUTO or opened submenu");
        round_trip;
        hold_menu;repeat(5) press(3);press(2);
        if(run_mode!=1) $fatal(1,"manual mode setup failed");round_trip;
        press(4);if(run_mode!=2) $fatal(1,"automatic mode setup failed");round_trip;
        if(!status_panel) $fatal(1,"status panel setup failed");round_trip;
        trip;key4=0;
        while(!dut.auto_press) @(negedge clk);
        sensor_clear=1;@(negedge clk);sensor_clear=0;key4=1;
        repeat(10) @(negedge clk);frame;
        if(alarm || context_state!==saved_state) $fatal(1,"concurrent KEY4/auto-exit corrupted context");
        $display("PASS sensor alarm: manual/source isolation, frame-boundary return, KEY4 priority, settings/preview/directory/MAN/AUTO preservation, SW4 reserved");$finish;
    end
    initial begin #1000000;$fatal(1,"sensor alarm timeout");end
endmodule

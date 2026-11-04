`timescale 1ns/1ps
module tb_ui_controls;
    reg clk=0,rst=1,tick=0,kn=1,ka=1,km=1,auto_active=0;
    reg [3:0] sw=0;
    reg [8:0] ready=15,available=6'b001101;
    integer slot;
    wire nt,at,browse,sel,directory,status_panel,alarm;
    wire signed [8:0] bright;
    wire [8:0] contrast;
    wire [3:0] volume,interval_seconds,modes;
    wire [2:0] menu;wire [1:0] choice;
    wire [3:0] focus,index;
    wire submenu;
    wire [1:0] run_mode;
    reg previous_auto;
    always #5 clk=~clk;
    player_control #(.DEBOUNCE_CYCLES(3),.LONG_CYCLES(30)) dut(
        .clk(clk),.rst(rst),.frame_tick(tick),.key_next(kn),.key_auto(ka),.key_menu(km),.switches(sw),
        .next_toggle(nt),.auto_toggle(at),.brightness(bright),.contrast(contrast),.volume(volume),
        .interval_seconds(interval_seconds),.menu(menu),.modes(modes),.available(available),
        .thumbnail_valid(ready),.browse(browse),.focus(focus),.select_toggle(sel),.select_index(index),
        .directory(directory),.directory_focus(choice),.status_panel(status_panel),.alarm(alarm),.auto_active(auto_active),
        .directory_run(submenu),.run_mode(run_mode));
    task press;
        input integer key,cycles;
        begin
            @(negedge clk);case(key) 2:kn=0;3:km=0;4:ka=0;endcase
            repeat(cycles) @(negedge clk);kn=1;ka=1;km=1;repeat(10) @(negedge clk);
        end
    endtask
    task frame;begin tick=1;@(negedge clk);tick=0;@(negedge clk);end endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        frame;if(run_mode!=2 || submenu || modes[3]) $fatal(1,"boot must select AUTO without settings");
        press(3,10);frame;if(nt || menu!=0 || run_mode!=2) $fatal(1,"AUTO short KEY3");
        sw=10;repeat(5) @(negedge clk);frame;
        if(modes[3] || modes[1] || run_mode!=2) $fatal(1,"reserved SW2/SW4 changed mode or editing");
        press(2,1);frame;if(directory) $fatal(1,"bounce opened directory");
        press(2,10);if(directory) $fatal(1,"directory not frame atomic");frame;
        if(!directory || choice!=0) $fatal(1,"KEY2 directory");
        press(4,10);frame;
        if(!browse || alarm || directory || run_mode!=2) $fatal(1,"preview changed AUTO");
        press(3,10);frame;if(focus!=2) $fatal(1,"sparse preview navigation");
        ready=1;press(3,40);frame;if(!browse || sel) $fatal(1,"unready accepted");
        ready=15;press(3,40);if(sel) $fatal(1,"selection not atomic");frame;
        if(browse || !sel || index!=2 || run_mode!=2) $fatal(1,"preview confirmation changed playback mode");
        // Continue playback is a single action, never a mode submenu.
        press(2,10);frame;press(3,10);frame;press(4,10);frame;
        if(directory || submenu || alarm || nt || at || run_mode!=2) $fatal(1,"continue playback opened submenu or advanced picture");
        // Enter settings through the third first-level item.
        press(2,10);frame;press(3,10);frame;press(4,10);frame;
        if(!status_panel || !modes[3] || directory || menu!=0) $fatal(1,"settings menu entry");
        sw=0;repeat(5) @(negedge clk);frame;
        if(!status_panel || !modes[3]) $fatal(1,"SW4 closed settings");
        press(2,10);if(bright!=0) $fatal(1,"parameter not atomic");frame;
        if(bright!=4 || directory) $fatal(1,"edit priority");
        press(4,10);frame;if(bright!=0 || alarm) $fatal(1,"edit decrease");
        press(3,10);press(2,10);frame;if(contrast!=132) $fatal(1,"contrast");
        press(3,10);press(4,10);frame;if(volume!=3) $fatal(1,"volume");
        press(3,10);press(2,10);frame;if(interval_seconds!=4) $fatal(1,"interval");
        press(3,10);frame;if(menu!=4) $fatal(1,"transition entry");
        press(3,10);frame;if(menu!=5) $fatal(1,"playback entry");
        previous_auto=at;press(2,10);
        if(run_mode!=2 || at!=previous_auto) $fatal(1,"mode changed before frame");
        frame;if(run_mode!=1 || at==previous_auto || nt || alarm) $fatal(1,"KEY2 selects MAN");
        press(4,10);frame;if(run_mode!=2 || alarm) $fatal(1,"KEY4 selects AUTO");
        press(4,10);frame;if(run_mode!=1 || alarm) $fatal(1,"two-option wrap");
        press(3,10);frame;if(menu!=6) $fatal(1,"audio entry");
        press(3,10);frame;if(menu!=0) $fatal(1,"seven-field wrap");
        press(3,40);frame;if(!directory || status_panel || modes[3] || submenu) $fatal(1,"settings hold return");
        press(2,10);frame;if(directory || run_mode!=1) $fatal(1,"directory back");
        press(3,10);frame;if(!nt) $fatal(1,"MAN next picture");
        press(4,10);frame;if(!alarm) $fatal(1,"manual alarm entry");
        press(4,10);frame;if(alarm || run_mode!=1) $fatal(1,"alarm preserved MAN");
        // Long KEY3 opens settings without changing the selected field or mode.
        press(3,40);frame;if(!status_panel || menu!=0 || run_mode!=1 || !nt) $fatal(1,"settings shortcut leaked next picture");
        press(3,40);frame;press(2,10);frame;
        // Exercise all nine preview slots and sparse navigation in AUTO.
        @(negedge clk);rst=1;sw=0;available=511;ready=511;
        repeat(4) @(negedge clk);rst=0;repeat(4) @(negedge clk);
        press(2,10);frame;press(4,10);frame;
        if(!browse || focus!=0 || run_mode!=2) $fatal(1,"nine-slot preview entry");
        for(slot=1;slot<=9;slot=slot+1) begin
            press(3,10);frame;
            if(focus!=(slot%9)) $fatal(1,"nine-slot focus/wrap %0d",slot);
        end
        available=9'b100000001;repeat(6) @(negedge clk);
        press(3,10);frame;if(focus!=8) $fatal(1,"sparse PIC9 focus");
        ready=1;press(3,40);frame;if(!browse || sel) $fatal(1,"unready PIC9 accepted");
        ready=511;press(3,40);frame;
        if(browse || !sel || index!=8 || run_mode!=2) $fatal(1,"PIC9 confirmation");
        $display("PASS controls: AUTO boot, reserved SW2/SW4, no submenu, settings entry/exit, seven fields, AUTO/MAN frame commit, playback/preview/alarm isolation, nine-slot navigation");$finish;
    end
    initial begin #1000000;$fatal(1,"control timeout");end
endmodule

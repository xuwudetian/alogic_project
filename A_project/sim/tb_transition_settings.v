`timescale 1ns/1ps
module tb_transition_settings;
    reg clk=0,rst=1,tick=0,key2=1,key3=1,key4=1,req=0,pause=0;
    reg [3:0] switches=8;
    reg [2:0] bank=0;
    wire [2:0] menu,active,picture,slide_bank,style;
    wire [3:0] mode,modes,volume,interval_seconds;
    wire signed [8:0] brightness;
    wire [8:0] contrast,gain;
    wire alarm,directory,ack,valid,sliding,mask;
    wire [18:0] offset;wire [5:0] level;
    wire [39:0] resolution;
    wire [3:0] physical_switches;
    integer i,n,old_bank,old_level;reg old_ack;
    reg [9:0] osd_x=0;reg [8:0] osd_y=256;reg [39:0] expected_label;
    integer label_slot;
    always #5 clk=~clk;
    player_control #(.DEBOUNCE_CYCLES(2),.LONG_CYCLES(50)) controls(
        .clk(clk),.rst(rst),.frame_tick(tick),.key_next(key2),.key_menu(key3),.key_auto(key4),
        .switches(switches),.menu(menu),.modes(modes),.transition_mode(mode),
        .physical_switches(physical_switches),
        .brightness(brightness),.contrast(contrast),.volume(volume),.interval_seconds(interval_seconds),
        .available(6'h3f),.thumbnail_valid(6'h3f),.auto_active(1'b0),
        .sensor_alarm(1'b0),.sensor_alarm_clear(1'b0),.alarm(alarm),.directory(directory));
    player_transition #(.SLIDE_ENABLE(1),.MULTI_EFFECT_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.frame_tick(tick),.request_toggle(req),.pending_bank(bank),
        .pending_picture(bank),.pending_scaled(1'b1),.pending_resolution({16'd1920,16'd1080}),
        .ack_toggle(ack),.active_bank(active),.active_picture(picture),.active_resolution(resolution),
        .display_valid(valid),.gain(gain),.transition_mode(mode),.effect_pause(pause),
        .effects_disabled(physical_switches[1]),
        .slide_active(sliding),.slide_offset(offset),.slide_bank(slide_bank),
        .mask_active(mask),.mask_style(style),.mask_level(level));
    player_status_osd panel(.clk(clk),.rst(rst),.x(osd_x),.y(osd_y),.menu(menu),
        .modes(modes),.transition_mode(mode),.status_panel(1'b0),.directory(1'b0),.alarm(1'b0),
        .brightness(9'sd0),.bright_digits(12'd0),.contrast_digits(12'h128),
        .picture(3'd0),.scaled(1'b0),.auto_play(1'b0),.run_mode(2'd0),.browse(1'b0),
        .error_code(8'd0),.audio_status(8'd0),.state_code(4'd0),.volume(4'd4),.interval_seconds(4'd3),
        .image_valid(1'b1),.source_resolution(40'h0064000480),.debug_status(60'd0),
        .time_digits(24'd0),.background_rgb(24'd0));
    task press;input integer key;begin
        @(negedge clk);case(key) 2:key2=0;3:key3=0;4:key4=0;endcase
        repeat(8) @(negedge clk);key2=1;key3=1;key4=1;repeat(8) @(negedge clk);
    end endtask
    task hold_menu;begin
        @(negedge clk);key3=0;repeat(65) @(negedge clk);key3=1;repeat(8) @(negedge clk);
    end endtask
    task frame;begin
        @(negedge clk);tick=1;@(negedge clk);tick=0;repeat(5) @(negedge clk);
    end endtask
    task request_image;begin
        old_ack=ack;old_bank=active;bank=(bank+1)%6;req=!req;
        repeat(45) @(negedge clk);frame;
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;repeat(5) @(negedge clk);frame;
        if(mode!==0 || menu!==0) $fatal(1,"reset settings");
        hold_menu;repeat(4) press(3);
        if(menu!==0) $fatal(1,"menu changed inside frame");
        frame;if(menu!==4) $fatal(1,"missing fifth setting");
        press(4);if(mode!==0) $fatal(1,"setting changed inside frame");
        frame;if(mode!==8 || alarm) $fatal(1,"KEY4 backwards wrap / alarm leakage");
        // Even a selected new effect must retain the cold-start fade.
        request_image;if(mask || sliding || !valid || gain!=0) $fatal(1,"cold fade");
        repeat(20) frame;
        press(2);frame;if(mode!==0) $fatal(1,"KEY2 forwards wrap");
        for(i=0;i<9;i=i+1) begin
            if(mode!==i) $fatal(1,"mode order %0d got %0d",i,mode);
            case(i)
                0:expected_label={8'd0,8'd170,8'd171,8'd170,8'd172};
                1:expected_label={8'd0,8'd173,8'd174,8'd175,8'd149};
                2:expected_label={8'd0,8'd176,8'd177,8'd178,8'd107};
                3:expected_label={8'd0,8'd179,8'd176,8'd180,8'd181};
                4:expected_label={8'd0,8'd0,8'd98,8'd122,8'd182};
                5:expected_label={8'd183,8'd184,8'd185,8'd186,8'd187};
                6:expected_label={8'd0,8'd169,8'd188,8'd189,8'd190};
                7:expected_label={8'd0,8'd0,8'd0,8'd191,8'd167};
                8:expected_label={8'd0,8'd192,8'd193,8'd194,8'd195};
            endcase
            for(label_slot=0;label_slot<10;label_slot=label_slot+1) begin
                osd_x=376+label_slot*8;#1;
                if(panel.code!==expected_label[39-(label_slot/2)*8 -: 8] ||
                   !panel.cover0 || !panel.text_on || panel.base!==24'ha5dfd9)
                    $fatal(1,"transition label/cursor mode=%0d slot=%0d",i,label_slot);
                if(panel.code>=96 && panel.column[3]!==label_slot[0]) $fatal(1,"Chinese glyph halves");
            end
            switches=10;repeat(5) @(negedge clk);frame;
            if(mode!==i || alarm || directory) $fatal(1,"SW2 changed settings");
            switches=8;repeat(5) @(negedge clk);frame;
            request_image;
            if(i>=3 && (!mask || style!=i-2 || sliding || level!=0)) $fatal(1,"fixed mask %0d",i);
            if((i==1 || i==2) && (!sliding || mask || offset!=0)) $fatal(1,"slide selection");
            // Edit during the transaction; selected style must remain latched.
            press(2);frame;
            if(mode!==(i==8 ? 0 : i+1)) $fatal(1,"KEY2 selection");
            if(i>=3 && (style!=i-2 || level!=2)) $fatal(1,"mid-effect style changed");
            if(i==0 && (mask || sliding || gain!=240)) $fatal(1,"fade selection");
            press(4);frame;if(mode!==i || alarm) $fatal(1,"KEY4 selection");
            if(i>=3) begin
                pause=1;old_level=level;repeat(3) frame;
                if(level!=old_level || ack!=old_ack || active!=old_bank) $fatal(1,"paused mask ownership");
                pause=0;
                while(level<32) begin
                    frame;
                    if(ack!=old_ack || active!=old_bank) $fatal(1,"bank released before blackout");
                end
                frame;if(active!=old_bank) $fatal(1,"missing full old black frame");
                frame;
                if(active!=bank || picture!=bank || resolution!==40'h0192001080 || ack!=old_ack)
                    $fatal(1,"atomic metadata / early ACK");
                frame;if(ack!=req || level!=32) $fatal(1,"new black frame before ACK");
                repeat(17) frame;
            end else repeat(40) frame;
            if(ack!=req || active!=bank || gain!=256 || sliding || mask) $fatal(1,"effect completion %0d",i);
            // Fixed effects must not advance the original four-effect carousel.
            if(i>=2 && dut.next_effect!=1) $fatal(1,"fixed mode modified carousel index");
            press(2);frame;
        end
        if(mode!=0 || menu!=4 || brightness!=0 || contrast!=128 || volume!=4 || interval_seconds!=3)
            $fatal(1,"transition keys changed other settings");
        press(3);frame;if(menu!=5) $fatal(1,"sixth playback field");
        press(3);frame;if(menu!=6) $fatal(1,"seventh audio field");
        press(3);frame;if(menu!=0) $fatal(1,"seven-field wrap");
        repeat(4) press(3);frame;press(4);frame;
        switches=0;repeat(5) @(negedge clk);frame;
        if(!modes[3]) $fatal(1,"SW4 closed settings");
        hold_menu;frame;press(2);frame;hold_menu;frame;
        if(mode!=8 || menu!=4) $fatal(1,"setting not retained after leaving edit");
        @(negedge clk);rst=1;@(negedge clk);
        if(mode || menu || mask || sliding || valid) $fatal(1,"reset");
        $display("PASS transition settings: seven menu items, all nine choices, wrap, atomic keys, SW2 preserves selection, latched modes, pause, bank/ACK ordering, carousel retention");
        $finish;
    end
    initial begin #2000000;$fatal(1,"settings timeout");end
endmodule

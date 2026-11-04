`timescale 1ns/1ps
module tb_transition_switch;
    reg clk=0,rst=1,tick=0,req=0,pause=0,network_alarm=0;
    reg [3:0] switches=2;
    reg [2:0] bank=0;
    reg remote_valid=0;
    reg [23:0] argument=0;
    wire [3:0] physical,mode,modes;
    wire ack,valid,scaled,sliding,mask,alarm;
    wire [2:0] active,picture,slide_bank,style;
    wire [8:0] gain;
    wire [18:0] offset;
    wire [5:0] level;
    wire [39:0] dimensions;
    integer i,j,old_bank,old_effect;
    reg old_ack;
    always #5 clk=~clk;
    player_control #(.REMOTE_ENABLE(1),.NETWORK_ENABLE(1)) controls(
        .clk(clk),.rst(rst),.frame_tick(tick),.key_next(1'b1),.key_menu(1'b1),.key_auto(1'b1),
        .switches(switches),.physical_switches(physical),.modes(modes),.transition_mode(mode),
        .available(6'h3f),.thumbnail_valid(6'h3f),.auto_active(1'b1),
        .sensor_alarm(1'b0),.sensor_alarm_clear(1'b0),.playback_fault(1'b0),
        .remote_valid(remote_valid),.remote_command(8'h11),.remote_argument(argument),
        .network_alarm(network_alarm),.alarm(alarm));
    player_transition #(.SLIDE_ENABLE(1),.MULTI_EFFECT_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.frame_tick(tick),.request_toggle(req),
        .pending_bank(bank),.pending_picture(bank),.pending_scaled(bank[0]),
        .pending_resolution({16'd1920,16'd1080}),.active_resolution(dimensions),
        .ack_toggle(ack),.active_bank(active),.active_picture(picture),.active_scaled(scaled),
        .display_valid(valid),.gain(gain),.transition_mode(mode),.effect_pause(pause),
        .effects_disabled(physical[1]),.slide_active(sliding),.slide_offset(offset),
        .slide_bank(slide_bank),.mask_active(mask),.mask_style(style),.mask_level(level));
    task frame;begin
        @(negedge clk);tick=1;@(negedge clk);tick=0;repeat(5) @(negedge clk);
    end endtask
    task set_switch;input value;begin
        @(negedge clk);switches[1]=value;repeat(5) @(negedge clk);
        if(physical[1]!==value || modes[1]!==0) $fatal(1,"SW2 synchronization/visual isolation");
    end endtask
    task select_mode;input [3:0] value;begin
        @(negedge clk);argument={12'd0,value,8'd4};remote_valid=1;
        @(negedge clk);remote_valid=0;frame;
        if(mode!==value) $fatal(1,"saved transition setting");
    end endtask
    task request_image;begin
        old_ack=ack;old_bank=active;bank=(bank+1)%6;
        @(negedge clk);req=!req;repeat(45) @(negedge clk);
        if(active!=old_bank || ack!=old_ack) $fatal(1,"image changed outside frame boundary");
        frame;
    end endtask
    task check_cut;begin
        old_effect=dut.next_effect;request_image;
        if(!valid || active!=bank || picture!=bank || scaled!==bank[0] ||
           dimensions!==40'h0192001080 || gain!=256 || sliding || mask || ack!=old_ack)
            $fatal(1,"SW2=1 must cut atomically at full gain without early ACK, mode=%0d",mode);
        repeat(20) @(negedge clk);
        if(ack!=old_ack) $fatal(1,"old bank released before a full new frame");
        frame;
        if(ack!=req || gain!=256 || dut.next_effect!=old_effect)
            $fatal(1,"cut acknowledgement or carousel retention");
        frame;
        if(gain!=256 || sliding || mask) $fatal(1,"cut started a delayed effect");
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;repeat(5) @(negedge clk);
        check_cut; // SW2 also suppresses the cold-start image fade.
        for(i=0;i<9;i=i+1) begin
            select_mode(i);check_cut;
            set_switch(0);request_image;
            if(i==0 && (mask || sliding || gain!=256 || active!=old_bank)) $fatal(1,"fade not restored");
            if((i==1 || i==2) && (!sliding || mask || offset!=0)) $fatal(1,"slide not restored");
            if(i>=3 && (!mask || sliding || style!=i-2 || level!=0)) $fatal(1,"mask not restored");
            set_switch(1); // Do not tear down an in-flight transaction.
            if(mode!=i || active!=old_bank || ack!=old_ack) $fatal(1,"switch changed settings or ownership");
            if(i>0) begin
                pause=1;repeat(3) frame;
                if(active!=old_bank || ack!=old_ack || offset!=0 || level!=0 || !(mask || sliding))
                    $fatal(1,"SW2 bypassed an effect paused by the UI/alarm");
                pause=0;
            end
            repeat(45) frame;
            if(active!=bank || ack!=req || gain!=256 || sliding || mask || mode!=i)
                $fatal(1,"in-flight effect did not complete safely");
            check_cut; // The changed switch now applies to the next picture.
        end
        select_mode(1);set_switch(0);request_image;
        if(!mask || style!=1) $fatal(1,"bypass advanced carousel sequence");
        set_switch(1);repeat(45) frame;
        // Re-enable during a cut: ACK still follows the full new frame, no fade.
        request_image;set_switch(0);
        if(gain!=256 || ack!=old_ack || mask || sliding) $fatal(1,"switch interrupted direct cut");
        frame;if(ack!=req || gain!=256 || mask || sliding) $fatal(1,"cut restart on re-enable");
        for(j=0;j<2;j=j+1) begin
            set_switch(j);network_alarm=1;frame;
            if(!alarm) $fatal(1,"SW2 blocked network WARNING");
            network_alarm=0;frame;if(alarm) $fatal(1,"SW2 blocked network clear");
        end
        $display("PASS SW2: 0=effects, 1=direct cut, nine modes, cold start, frame/ACK ordering, mid-effect switch, pause, carousel, network WARNING isolation");
        $finish;
    end
    initial begin #2000000;$fatal(1,"SW2 timeout");end
endmodule

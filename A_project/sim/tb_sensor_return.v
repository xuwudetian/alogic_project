`timescale 1ns/1ps
module tb_sensor_return;
    reg clk=0,rst=1,frame_tick=0,sv=0,key2=1,key3=1,key4=1;
    reg [11:0] sample=2048;
    wire alarm,request,clear_request,browse;
    wire [2:0] focus;
    integer clears=0;
    always #5 clk=~clk;
    always @(posedge clk) if(clear_request) clears=clears+1;
    player_sensor_policy #(.WINDOW_LOG2(3),.QUIET_WINDOWS(2),.COOLDOWN_WINDOWS(3),
        .EXIT_QUIET_WINDOWS(3),.SAMPLE_TIMEOUT_CYCLES(32)) policy(
        .clk(clk),.rst(rst),.frame_tick(frame_tick),.light_valid(1'b0),.light_online(1'b0),
        .light_raw(16'd0),.manual_brightness(9'sd0),.edit_mode(1'b0),.alarm(alarm),
        .sample_valid(sv),.sample(sample),.alarm_request(request),.alarm_clear_request(clear_request));
    player_control #(.SENSOR_ENABLE(1),.DEBOUNCE_CYCLES(2),.LONG_CYCLES(100)) control(
        .clk(clk),.rst(rst),.frame_tick(frame_tick),.sensor_alarm(request),.sensor_alarm_clear(clear_request),
        .key_next(key2),.key_menu(key3),.key_auto(key4),.switches(4'd0),
        .available(6'h3f),.thumbnail_valid(6'h3f),.auto_active(1'b0),.alarm(alarm),.browse(browse),.focus(focus));
    task frame;
        begin frame_tick=1;@(negedge clk);frame_tick=0;repeat(2) @(negedge clk);end
    endtask
    task press(input integer key);
        begin
            case(key) 2:key2=0;3:key3=0;4:key4=0;endcase
            repeat(10) @(negedge clk);key2=1;key3=1;key4=1;
            repeat(10) @(negedge clk);frame;
        end
    endtask
    task window(input integer low,input integer high);
        integer k;
        begin
            for(k=0;k<8;k=k+1) begin
                @(negedge clk);sv=1;sample=k%2==0 ? low : high;
                @(negedge clk);sv=0;
            end
            repeat(4) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;repeat(4) @(negedge clk);
        press(2);press(4);repeat(5) press(3);
        if(!browse || focus!=5) $fatal(1,"preview context setup failed");
        repeat(2) window(2000,2100);repeat(3) window(1000,3000);
        frame;if(!alarm) $fatal(1,"connected sensor did not enter warning");
        repeat(2) window(2000,2100);frame;
        if(!alarm || clears!=0) $fatal(1,"connected exit occurred early");
        repeat(40) @(negedge clk);frame;
        if(!alarm) $fatal(1,"missing ADC samples closed warning");
        repeat(2) window(2000,2100);frame;
        if(!alarm || clears!=0) $fatal(1,"missing ADC samples failed to reset duration");
        window(2000,2100);
        if(!alarm || clears!=1) $fatal(1,"exit request did not wait for frame boundary");
        frame;if(alarm || !browse || focus!=5) $fatal(1,"connected return lost preview state");
        repeat(3) window(2000,2100);repeat(4) window(1000,3000);frame;
        if(alarm) $fatal(1,"alarm retriggered without quiet re-arm");
        press(4);if(!alarm) $fatal(1,"manual warning setup failed");
        repeat(3) window(2000,2100);frame;
        if(!alarm || clears!=2) $fatal(1,"manual warning accepted automatic quiet exit");
        press(4);if(alarm || !browse || focus!=5) $fatal(1,"manual return failed");
        $display("PASS sensor return: connected ADC windows, automatic entry/return, frame commit, dropout restart, cooldown, manual isolation, preview restore");$finish;
    end
    initial begin #1000000;$fatal(1,"sensor return timeout");end
endmodule

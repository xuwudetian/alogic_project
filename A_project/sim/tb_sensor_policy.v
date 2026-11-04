`timescale 1ns/1ps
module tb_sensor_policy;
    reg clk=0,rst=1,frame_tick=0,lv=0,online=0,edit=0,alarm=0,sv=0;
    reg [15:0] raw=0;
    reg [11:0] sample=2048;
    reg signed [8:0] manual=0;
    wire signed [8:0] brightness;
    wire request,dark,clear_request;
    wire [11:0] level;
    integer requests=0,clears=0,n;
    always #5 clk=~clk;
    player_sensor_policy #(.WINDOW_LOG2(3),.QUIET_WINDOWS(2),.COOLDOWN_WINDOWS(3),.SAMPLE_TIMEOUT_CYCLES(32)) dut(
        .clk(clk),.rst(rst),.frame_tick(frame_tick),.light_valid(lv),.light_online(online),.light_raw(raw),
        .manual_brightness(manual),.edit_mode(edit),.alarm(alarm),.sample_valid(sv),.sample(sample),
        .brightness(brightness),.alarm_request(request),.dark(dark),.sound_level(level),.alarm_clear_request(clear_request));
    always @(posedge clk) if(request) requests=requests+1;
    always @(posedge clk) if(clear_request) clears=clears+1;
    task light(input integer value);
        begin @(negedge clk);raw=value;lv=1;@(negedge clk);lv=0;@(negedge clk);end
    endtask
    task frame;
        begin @(negedge clk);frame_tick=1;@(negedge clk);frame_tick=0;@(negedge clk);end
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
        repeat(3) @(negedge clk);rst=0;
        light(0);frame;if(dark || brightness!=0) $fatal(1,"absent light sensor affected brightness");
        online=1;light(100);light(100);
        if(dark) $fatal(1,"darkness accepted too early");
        light(100);if(!dark || brightness!=0) $fatal(1,"dark confirmation or atomic brightness failed");
        frame;if(brightness!=1) $fatal(1,"darkness must increase brightness one code per frame");
        repeat(70) frame;if(brightness!=55) $fatal(1,"darkness compensation target wrong");
        repeat(5) light(250);if(!dark) $fatal(1,"hysteresis lost");
        edit=1;frame;if(brightness!=54) $fatal(1,"opening settings cleared compensation");
        repeat(50) frame;if(brightness!=17) $fatal(1,"settings stopped automatic compensation");
        manual=100;frame;if(brightness!=117) $fatal(1,"manual editing lost compensation or immediate response");
        light(128);frame;if(brightness!=118) $fatal(1,"automatic compensation stopped while editing");
        edit=0;frame;if(brightness!=119) $fatal(1,"closing settings interrupted compensation");
        online=0;repeat(2) @(negedge clk);frame;
        if(dark || brightness!=118) $fatal(1,"disconnect did not ramp toward manual target");
        repeat(20) frame;if(brightness!=100) $fatal(1,"disconnect failed to restore manual target");
        online=1;raw=0;repeat(5) frame;
        if(brightness!=100) $fatal(1,"reconnection used stale sample");
        manual=0;edit=1;frame;edit=0;
        light(320);repeat(70) frame;if(brightness!=0) $fatal(1,"bright boundary");
        light(319);repeat(70) frame;if(brightness!=0) $fatal(1,"quantization boundary");
        light(316);repeat(70) frame;if(brightness!=1) $fatal(1,"first compensation step");
        light(256);repeat(70) frame;if(brightness!=16) $fatal(1,"quarter dark compensation");
        light(128);repeat(70) frame;if(brightness!=48) $fatal(1,"mid dark compensation");
        raw=0;repeat(70) frame;if(brightness!=48) $fatal(1,"invalid reading changed compensation");
        light(64);repeat(70) frame;if(brightness!=64) $fatal(1,"maximum compensation boundary");
        light(0);repeat(70) frame;if(brightness!=64) $fatal(1,"compensation exceeded limit");
        manual=240;edit=1;frame;
        if(brightness!=255) $fatal(1,"editing failed to clamp combined target");
        edit=0;repeat(70) frame;
        if(brightness!=255) $fatal(1,"positive saturation wrapped");
        manual=-255;edit=1;frame;
        if(brightness!=-191) $fatal(1,"editing failed to preserve signed baseline and compensation");
        edit=0;repeat(70) frame;
        if(brightness!=-191) $fatal(1,"negative manual sign extension");
        manual=0;edit=1;frame;edit=0;light(0);repeat(70) frame;
        light(65535);frame;if(brightness!=63) $fatal(1,"brightening must decrease compensation smoothly");
        repeat(70) frame;if(brightness!=0) $fatal(1,"high raw underflow");
        light(0);repeat(70) frame;online=0;frame;
        if(brightness!=63) $fatal(1,"disconnect must ramp rather than jump");
        repeat(70) frame;if(brightness!=0 || dark) $fatal(1,"disconnect did not restore baseline");
        repeat(3) window(1000,3000);
        if(requests!=0) $fatal(1,"alarm armed before quiet qualification");
        repeat(2) window(2000,2100);repeat(2) window(1000,3000);
        if(requests!=0) $fatal(1,"alarm lacks persistence");
        window(1000,3000);if(requests!=1) $fatal(1,"loud sound did not request alarm");
        alarm=1;repeat(4) window(1000,3000);alarm=0;
        repeat(3) window(2000,2100);repeat(4) window(1000,3000);
        if(requests!=1) $fatal(1,"self alarm retriggered during recovery");
        repeat(2) window(2000,2100);window(0,4095);
        repeat(3) window(1000,3000);
        if(requests!=1) $fatal(1,"invalid ADC range did not disarm");
        repeat(2) window(2000,2100);repeat(3) window(1000,3000);
        if(requests!=2 || level!=2000) $fatal(1,"sound re-arm or peak-to-peak wrong");
        // A partial pre-alarm window must not contribute to the quiet interval.
        @(negedge clk);sv=1;sample=2048;repeat(7) @(negedge clk);sv=0;
        alarm=1;repeat(3) @(negedge clk);
        if(dut.window_count!=0) $fatal(1,"pre-alarm partial window survived");
        repeat(71) window(2000,2100);
        if(clears!=0) $fatal(1,"quiet exit occurred before 72 full windows");
        window(2000,2350); // Exact low threshold is not below threshold.
        repeat(71) window(2000,2100);
        if(clears!=0) $fatal(1,"threshold equality did not restart quiet duration");
        window(2000,2400); // Even the hysteresis band must restart quiet time.
        repeat(71) window(2000,2100);
        if(clears!=0) $fatal(1,"non-quiet hysteresis band failed to restart");
        window(1000,3000);
        repeat(71) window(2000,2100);
        if(clears!=0) $fatal(1,"loud interruption failed to restart");
        window(0,0); // Invalid flatline has zero amplitude but is not quiet.
        repeat(71) window(2000,2100);
        if(clears!=0) $fatal(1,"invalid ADC sample accepted as quiet");
        repeat(80) @(negedge clk);
        if(clears!=0 || dut.exit_quiet_count!=0) $fatal(1,"ADC silence used stale level");
        repeat(71) window(2000,2100);
        if(clears!=0) $fatal(1,"sample gap did not restart quiet duration");
        window(2000,2100);
        if(clears!=1) $fatal(1,"72 quiet windows did not request exit");
        repeat(80) window(2000,2100);
        if(clears!=1) $fatal(1,"quiet exit request must be one-shot");
        alarm=0;repeat(3) @(negedge clk);
        repeat(3) window(2000,2100);repeat(4) window(1000,3000);
        if(requests!=2) $fatal(1,"auto-exit lost cooldown and quiet re-arm");
        repeat(2) window(2000,2100);repeat(3) window(1000,3000);
        if(requests!=3) $fatal(1,"auto-exit failed to re-arm later");
        alarm=1;repeat(3) @(negedge clk);repeat(72) window(2000,2100);
        if(clears!=2) $fatal(1,"next alarm retained old exit one-shot");
        rst=1;@(negedge clk);rst=0;alarm=0;repeat(3) @(negedge clk);
        if(clear_request || dut.exit_sent || dut.exit_quiet_count!=0) $fatal(1,"reset retained auto-exit state");
        $display("PASS sensor policy: settings retain live compensation, immediate combined manual target, signed/saturated brightness, light hysteresis/ramp, sound arming/cooldown, quiet exit and reset");$finish;
    end
    initial begin #1000000;$fatal(1,"sensor policy timeout");end
endmodule

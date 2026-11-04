`timescale 1ns/1ps
module tb_no_signal_top;
    reg clk=0,absent=0,frame_vs=1,alarm_request=0;
    tri1 sensor_scl,sensor_sda,eth_mdio;
    wire alarm_valid;
    wire [23:0] alarm_pcm;
    integer samples=0,repeat_mount;
    reg check_alarm=0;
    always #10 clk=~clk;
    top #(.BOOT_HOLD_CYCLES(100)) dut(.clk(clk),.rst_n(1'b1),
        .key1(1'b1),.key2(1'b1),.key3(1'b1),.sw(4'd0),.sd_miso(1'b1),
        .sensor_scl(sensor_scl),.sensor_sda(sensor_sda),.uart_rx(1'b1),
        .eth_rx_clk(1'b0),.eth_rx_ctl(1'b0),.eth_rxd(4'd0),.eth_mdio(eth_mdio));
    player_alarm_audio alarm_reference(.clk(dut.video_clk),.rst(dut.rst_video),
        .enable(alarm_request),.tick(dut.tone_valid),.mute(1'b0),.volume(4'd4),
        .media_valid(1'b0),.media_pcm(24'd0),.valid(alarm_valid),.pcm(alarm_pcm));
    always @(posedge dut.video_clk) begin
        #1;
        if(check_alarm) begin
            if(dut.audio_valid!==alarm_valid || (alarm_valid && dut.audio_left!==alarm_pcm))
                $fatal(1,"missing-card tone changed alarm priority or PCM");
            if(alarm_valid) samples=samples+1;
        end
    end
    task frame_boundary;begin
        @(negedge dut.video_clk);frame_vs=0;
        repeat(4) @(negedge dut.video_clk);frame_vs=1;
        repeat(4) @(negedge dut.video_clk);
    end endtask
    initial begin
        wait(!dut.rst_video);
        force dut.vs0=frame_vs;force dut.no_signal_sd=absent;
        force dut.alarm=alarm_request;force dut.volume=4'd4;force dut.modes=4'd0;
        force dut.active_picture=4'd4;
        force dut.ui.boot_active=0;
        repeat(8) @(negedge dut.video_clk);frame_boundary;
        for(repeat_mount=0;repeat_mount<3;repeat_mount=repeat_mount+1) begin
            absent=1;repeat(8) @(negedge dut.video_clk);
            if(dut.no_signal_frame || dut.ui.no_signal_visible) $fatal(1,"removal changed active frame");
            frame_boundary;
            if(!dut.no_signal_frame || !dut.ui.no_signal_visible || dut.audio.picture!=15)
                $fatal(1,"removal did not reach both video and fixed-tone source");
            if(repeat_mount==1) begin
                alarm_request=1;repeat(8) @(negedge dut.video_clk);
                if(dut.ui.no_signal_visible) $fatal(1,"test card covered alarm");
                check_alarm=1;wait(samples>=24);@(negedge dut.video_clk);check_alarm=0;
                alarm_request=0;repeat(8) @(negedge dut.video_clk);
                if(!dut.ui.no_signal_visible) $fatal(1,"test card not restored after alarm");
            end
            absent=0;repeat(8) @(negedge dut.video_clk);
            if(!dut.no_signal_frame || !dut.ui.no_signal_visible) $fatal(1,"reinsertion changed active frame");
            frame_boundary;
            if(dut.no_signal_frame || dut.ui.no_signal_visible || dut.audio.picture!=4)
                $fatal(1,"reinsertion did not restore normal picture/audio source");
        end
        $display("PASS no signal top: synchronized status, frame-boundary enter/exit, three removal/recovery cycles, preserved alarm audio and video priority");
        $finish;
    end
    initial begin #5000000;$fatal(1,"no-signal top timeout");end
endmodule

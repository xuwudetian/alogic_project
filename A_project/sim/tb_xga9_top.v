`timescale 1ns/1ps
// Real top/RTL with behavioural PLL, SDRAM and HDMI boundary models.
// Does not validate encrypted IP internals or physical HDMI/SDRAM timing.
module tb_xga9_top;
    reg clk=0;
    reg [3:0] switches=4'b1000;
    wire [5:0] seg_sel;
    wire [7:0] seg_data;
    wire buzzer_n;
    tri1 sensor_scl,sensor_sda;
    tri1 eth_mdio;
    reg eth_rx_clk=0;
    always #20 eth_rx_clk=~eth_rx_clk;
    integer startup_clocks=0;
    integer switch_state;
    always #10 clk=~clk;
    top #(.BOOT_HOLD_CYCLES(100)) dut(.clk(clk),.rst_n(1'b1),.key1(1'b1),.key2(1'b1),.key3(1'b1),
        .sw(switches),.seg_sel(seg_sel),.seg_data(seg_data),.sd_miso(1'b1),.buzzer_n(buzzer_n),
        .sensor_scl(sensor_scl),.sensor_sda(sensor_sda),
        .eth_rx_clk(eth_rx_clk),.eth_rx_ctl(1'b0),.eth_rxd(4'd0),.eth_mdio(eth_mdio));
    // Accelerate the existing 3 s network-display release hold in simulation.
    defparam dut.alarm_hold.MS_CYCLES=2,dut.alarm_hold.HOLD_MS=3;
    always @(posedge clk) if(dut.lock_sync[1] && dut.boot_reset) startup_clocks=startup_clocks+1;
    initial begin
        repeat(5) @(negedge clk);
        if(dut.rst_board!==1 || seg_sel!==6'b111111 || seg_data!==8'hff || buzzer_n!==1)
            $fatal(1,"top cold start failed with KEY1 never pressed");
        wait(!dut.rst_video && !dut.rst_board && !dut.rst_sd && !dut.rst_mem);
        repeat(20) @(negedge clk);
        if($bits(dut.write_data)!=16 || $bits(dut.read_pixel565)!=16 || $bits(dut.read_data)!=24 || $bits(dut.active_picture)!=4 ||
           $bits(dut.available_frame)!=9 || dut.frame_read_write_m0.READ_DATA_BITS!=16 ||
           dut.frame_read_write_m0.read_addr_8!=1228800 || dut.frame_read_write_m0.read_len!=153600)
            $fatal(1,"packed RGB565 / nine-bank top wiring");
        force dut.active_picture=4'd8;force dut.focus=4'd8;
        force dut.available_frame=9'h100;force dut.ready_frame=9'h100;force dut.failed_frame=9'h100;
        #1;
        if(dut.effects.picture!=8) $fatal(1,"PIC9 OSD truncated");
        force dut.frame_tick=1;repeat(2) @(negedge dut.video_clk);release dut.frame_tick;
        repeat(15) @(negedge clk);
        if(dut.seg_snapshot[11:8]!=8) $fatal(1,"PIC9 diagnostic CDC truncated");
        release dut.active_picture;release dut.focus;
        release dut.available_frame;release dut.ready_frame;release dut.failed_frame;
        if(dut.VIDEO_HZ!=32500000 || dut.FRAME_HZ!=60 || dut.audio.CLK_HZ!=32500000 ||
           dut.controls.DEBOUNCE_CYCLES!=650000 || dut.controls.LONG_CYCLES!=26000000 || dut.controls.KEY_LONG_FRAMES!=48 || dut.controls.KEY_REPEAT_FRAMES!=12 ||
           dut.microphone.CLK_HZ!=32500000 || dut.light_sensor.QUARTER_CYCLES!=163 || dut.storage.FRAME_WIDTH!=640 || dut.storage.FRAME_HEIGHT!=480 || dut.storage.MODE_576!=0 ||
           dut.axis.WIDTH!=1024 || dut.effects.MODE_576!=0 || dut.previews.MODE_576!=0 || dut.ui.MODE_576!=0 || dut.spectrum_display.MODE_576!=0 ||
           dut.u_hdmi_1_4b_transmitter_core_wrapper.HTOTAL!=1344 || dut.u_hdmi_1_4b_transmitter_core_wrapper.VTOTAL!=806 ||
           dut.u_hdmi_1_4b_transmitter_core_wrapper.HACTIVE!=1024 || dut.u_hdmi_1_4b_transmitter_core_wrapper.VACTIVE!=768 ||
           dut.u_hdmi_1_4b_transmitter_core_wrapper.VIDEO_VIC!=0 || dut.u_hdmi_1_4b_transmitter_core_wrapper.IIC_SCL_DIV!=650)
            $fatal(1,"XGA9 native top raster/storage/control/audio rate wiring");
        if(dut.ui.BOOT_ENABLE!=1 || !dut.ui.boot_active) $fatal(1,"boot overlay not enabled by top");
        if(dut.ui.BOOT_FRAMES!=210) $fatal(1,"top startup duration must be approximately 3.5 seconds");
        if(startup_clocks<100 || (^seg_sel)===1'bx || (^seg_data)===1'bx)
            $fatal(1,"PLL settling or scanner reset bypassed");
        force dut.frame_tick=1;repeat(4) @(negedge dut.video_clk);release dut.frame_tick;
        if(dut.run_mode!==2 || dut.modes[3]!==0 || dut.status_panel!==0 || dut.directory_run!==0)
            $fatal(1,"AUTO boot or SW4 audio selector changed boot controls");
        if(dut.audio_select!==0 || dut.storage.AUDIO_SELECT_ENABLE!=1 ||
           dut.storage.audio_select!==0 || dut.effects.audio_select!==0)
            $fatal(1,"four-track audio default or top wiring failed");
        force dut.audio_select=2'd3;#1;
        if(dut.storage.audio_select!==3 || dut.effects.audio_select!==3)
            $fatal(1,"audio selection must reach storage and settings OSD together");
        release dut.audio_select;
        switches=0;repeat(8) @(negedge dut.video_clk);
        force dut.frame_tick=1;@(negedge dut.video_clk);release dut.frame_tick;
        if(dut.run_mode!==2 || dut.modes[3]!==0 || dut.status_panel!==0)
            $fatal(1,"SW4 changed settings/playback mode");
        force dut.display_valid=1;force dut.underflow=1;force dut.error_sd=8'h37;
        #1;if(dut.ui.boot_ready!==1) $fatal(1,"first-picture readiness not wired");
        repeat(5) @(negedge dut.video_clk);
        force dut.frame_tick=1;@(negedge dut.video_clk);release dut.frame_tick;
        repeat(15) @(negedge clk);
        if(dut.error_frame!==8'h41 || dut.seg_snapshot[7:0]!==8'h41)
            $fatal(1,"screen and seven segment disagree on E41");
        force dut.underflow=0;repeat(5) @(negedge dut.video_clk);
        force dut.frame_tick=1;@(negedge dut.video_clk);release dut.frame_tick;
        repeat(15) @(negedge clk);
        if(dut.error_frame!==8'h37 || dut.seg_snapshot[7:0]!==8'h37)
            $fatal(1,"stored SD error lost after underflow clears");
        release dut.display_valid;release dut.underflow;release dut.error_sd;
        if(buzzer_n!==1) $fatal(1,"normal mode buzzer not silent");
        force dut.alarm=1;#1;
        if(buzzer_n!==0) $fatal(1,"alarm not connected to buzzer output");
        force dut.modes=4'b0100;#1;
        if(buzzer_n!==1) $fatal(1,"SW3 not connected to buzzer mute");
        release dut.modes;release dut.alarm;
        force dut.alarm=0;force dut.browse=0;force dut.directory=0;
        force dut.modes=4'b0001;#1;
        if(dut.hide_audio_visuals!==1 || dut.effects.modes[0]!==0 || dut.spectrum_display.enable!==0)
            $fatal(1,"SW1 must preserve header while hiding waveform and spectrum");
        release dut.modes;switches=2;repeat(8) @(negedge dut.video_clk);
        force dut.frame_tick=1;@(negedge dut.video_clk);release dut.frame_tick;
        if(dut.transition.effects_disabled!==1 || dut.modes[1]!==0)
            $fatal(1,"physical SW2 must disable transitions without hiding visual overlays");
        if(dut.transition.transition_mode!==4'd0 || dut.frame_read_write_m0.SLIDE_ENABLE!=1)
            $fatal(1,"SW2 must leave transition selection unchanged");
        if(dut.hide_audio_visuals!==0 || dut.effects.modes[0]!==0 || dut.spectrum_display.enable!==1)
            $fatal(1,"SW2 must not duplicate visual hide control");
        force dut.transition_mode=4'd7;#1;
        if(dut.transition.transition_mode!==4'd7 || dut.effects.transition_mode!==4'd7)
            $fatal(1,"setting must drive transition engine and OSD");
        switches=0;repeat(8) @(negedge dut.video_clk);
        if(dut.transition.effects_disabled!==0) $fatal(1,"physical SW2 did not re-enable effects");
        if(dut.transition.transition_mode!==4'd7) $fatal(1,"SW2 changed selected effect");
        release dut.transition_mode;
        force dut.modes=4'b0001;force dut.alarm=1;#1;
        if(dut.hide_audio_visuals!==0 || dut.spectrum_display.enable!==1)
            $fatal(1,"alarm must override SW1 visual hide");
        force dut.alarm=0;force dut.display_valid=1;force dut.preview_visible=0;force dut.directory_active=0;
        repeat(18) begin
            force dut.frame_tick=1;@(negedge dut.video_clk);release dut.frame_tick;
            repeat(3) @(negedge dut.video_clk);
        end
        if(dut.picture_zoom_size!==160 || dut.picture_zoom_left!==0 || dut.picture_zoom_top!==0 ||
           dut.picture_layout!==1 || dut.effects.modes[0]!==0 || dut.effects.chinese_osd.status.top_active!==1)
            $fatal(1,"SW1 must fill 720xXGA9 with the permanent header overlaid");
        if(dut.picture_zoom_width!=640 || dut.picture_zoom_height!=480 || dut.frame_read_write_m0.zoom_width!=640 || dut.frame_read_write_m0.zoom_height!=480)
            $fatal(1,"native full dimensions not propagated");
        if(dut.frame_read_write_m0.zoom_size!==160 || dut.frame_read_write_m0.zoom_left!==0 ||
           dut.frame_read_write_m0.zoom_top!==0) $fatal(1,"SW1 memory/display geometry mismatch");
        force dut.modes=4'b0000;
        repeat(18) begin
            force dut.frame_tick=1;@(negedge dut.video_clk);release dut.frame_tick;
            repeat(3) @(negedge dut.video_clk);
        end
        if(dut.picture_zoom_size!==136 || dut.picture_zoom_left!==48 || dut.picture_zoom_top!==32 ||
           dut.hide_audio_visuals!==0 || dut.effects.modes[0]!==0 || dut.effects.chinese_osd.status.top_active!==1)
            $fatal(1,"SW1 framed picture/header restoration");
        if(dut.picture_zoom_width!=544 || dut.picture_zoom_height!=408 || dut.frame_read_write_m0.zoom_width!=544 || dut.frame_read_write_m0.zoom_height!=408)
            $fatal(1,"native compact dimensions not propagated");
        release dut.display_valid;release dut.preview_visible;release dut.directory_active;
        release dut.modes;release dut.alarm;release dut.browse;release dut.directory;
        repeat(3) @(negedge clk);
        if(buzzer_n!==1) $fatal(1,"buzzer remained on after alarm exit");
        force dut.network.session.remote_alarm=1;
        repeat(4) @(negedge dut.video_clk);
        force dut.frame_tick=1;repeat(2) @(negedge dut.video_clk);release dut.frame_tick;
        if(!dut.alarm) $fatal(1,"network alarm not wired through synchronizer/control");
        force dut.network.session.remote_alarm=0;
        repeat(4) @(negedge dut.video_clk);
        if(!dut.network_alarm_display) $fatal(1,"network display hold released too soon");
        wait(!dut.network_alarm_display);
        repeat(3) @(negedge dut.video_clk);
        force dut.frame_tick=1;repeat(2) @(negedge dut.video_clk);release dut.frame_tick;
        if(dut.alarm) $fatal(1,"network clear failed after UART reset");
        release dut.network.session.remote_alarm;
        // SW4 selects audio only: the shared pins always follow diagnostic scanning,
        // even with active WAV audio, mute, alarm or missing media.
        force dut.media_pcm=24'h800000;
        force dut.alarm=0;force dut.modes=0;force dut.no_signal_frame=0;
        for(switch_state=0;switch_state<4;switch_state=switch_state+1) begin
            switches=(switch_state[0] ? 4'd8 : 4'd0);
            force dut.alarm=switch_state[1];
            repeat(8) @(negedge dut.video_clk);
            repeat(40) begin
                @(negedge clk);
                if(seg_sel!==dut.diagnostic_sel || seg_data!==dut.diagnostic_data || dut.seg_sel_extra!==2'b11)
                    $fatal(1,"SW4 audio selector must preserve diagnostic scanner in both positions");
            end
            force dut.frame_tick=1;@(negedge dut.video_clk);release dut.frame_tick;
            if(dut.run_mode!==2 || dut.modes[3]!==0 || dut.status_panel!==0)
                $fatal(1,"SW4 audio selector changed playback/settings");
        end
        force dut.alarm=0;force dut.modes=4'b0100;#1;
        if(seg_sel!==dut.diagnostic_sel || seg_data!==dut.diagnostic_data || dut.seg_sel_extra!==2'b11)
            $fatal(1,"mute changed diagnostic output routing");
        force dut.modes=0;force dut.no_signal_frame=1;#1;
        if(seg_sel!==dut.diagnostic_sel || seg_data!==dut.diagnostic_data || dut.seg_sel_extra!==2'b11)
            $fatal(1,"missing media changed diagnostic output routing");
        force dut.network_link=1;force dut.network_online=1;force dut.network_valid=1;#1;
        if(dut.net_led_n!==0) $fatal(1,"network valid indicators changed");
        force dut.network_valid=0;#1;
        if(dut.net_led_n!==2'b10) $fatal(1,"network fault indicator changed");
        release dut.network_link;release dut.network_online;release dut.network_valid;
        release dut.alarm;release dut.modes;release dut.no_signal_frame;release dut.media_pcm;
        switches=0;repeat(8) @(negedge dut.video_clk);
        force dut.sys_lock=0;force dut.sd_card_clk=0;#1;
        if(!dut.rst_board || !dut.rst_video || !dut.rst_mem || !dut.rst_sd) $fatal(1,"PLL loss did not reset all domains");
        if(!dut.boot_reset || dut.boot_count!=0 || dut.lock_sync!=0) $fatal(1,"stopped PLL clock did not asynchronously restart boot hold");
        repeat(5) @(negedge clk);release dut.sd_card_clk;release dut.sys_lock;
        wait(!dut.rst_board && !dut.rst_video);repeat(15) @(negedge clk);
        if((^seg_data)===1'bx || dut.seg_snapshot!==0) $fatal(1,"top restart did not clear diagnostics");
        $display("PASS nativeXGA9 top startup/rates/banks/SW1: KEY1 high throughout, lock/settling/domain resets, E41 agreement, SD error restoration, SW4 audio/scanner isolation, network LEDs, PLL loss/restart (vendor boundaries modelled)");$finish;
    end
    initial begin #100000;$fatal(1,"top startup timeout");end
endmodule


`timescale 1ns/1ps
module top #(
    parameter integer BOOT_HOLD_CYCLES=1000000
)(
    input clk,input rst_n,input key1,input key2,input key3,input [3:0] sw,
    output [5:0] seg_sel,output [7:0] seg_data,output buzzer_n,
    output HDMI_CLK_P,output HDMI_D2_P,output HDMI_D1_P,output HDMI_D0_P,
    output HDMI_DDC_SCL,inout HDMI_DDC_SDA,
    output sd_ncs,output sd_dclk,output sd_mosi,input sd_miso,
    inout sensor_scl,inout sensor_sda,
    input uart_rx,output uart_tx,
    input eth_rx_clk,input eth_rx_ctl,input [3:0] eth_rxd,
    output eth_tx_clk,output eth_tx_ctl,output [3:0] eth_txd,
    output eth_mdc,inout eth_mdio,output [1:0] net_led_n,
    output [1:0] seg_sel_extra
);
    // 1024x768 RGB332 nine-image cache; 65 MHz scene, 65/325 MHz XGA HDMI.
    localparam integer VIDEO_HZ=65000000, FRAME_HZ=60;
    wire sd_card_clk,ext_mem_clk,ext_mem_clk_sft,video_clk,hdmi_5x_clk;
    wire sys_lock,video_lock;
    reg [1:0] lock_sync=0;
    reg [19:0] boot_count=0;
    reg boot_reset=1;
    wire clock_reset=!rst_n || !sys_lock || !video_lock;
    wire reset_async=clock_reset || boot_reset;
    wire pixel_clk=video_clk;
    wire rst_pixel=rst_video;
    wire rst_uart;
    wire system_reset_async=reset_async;
    wire rst_sd,rst_mem,rst_video,rst_board;
    sys_pll sys_pll_m0(.refclk(clk),.reset(1'b0),.clk0_out(sd_card_clk),
        .clk1_out(ext_mem_clk),.clk2_out(ext_mem_clk_sft),.locked(sys_lock));
    video_pll video_pll_m0(.refclk(clk),.reset(1'b0),
        .clk0_out(video_clk),.clk1_out(hdmi_5x_clk),.clk2_out(),.locked(video_lock));
    // Release the boot hold from the PLL's 50 MHz clock tree. The raw reference
    // clock arrives later than related PLL clocks and left little recovery
    // margin at the 40 MHz domain reset synchronizer. Lock loss resets this
    // counter asynchronously, including when the PLL output has stopped.
    always @(posedge sd_card_clk or posedge clock_reset) begin
        if(clock_reset) begin lock_sync<=0;boot_count<=0;boot_reset<=1;end
        else begin
            lock_sync<={lock_sync[0],sys_lock && video_lock};
            if(!lock_sync[1]) begin boot_count<=0;boot_reset<=1;end
            else if(boot_count<BOOT_HOLD_CYCLES) begin boot_count<=boot_count+1'b1;boot_reset<=1;end
            else boot_reset<=0;
        end
    end
    player_reset reset_sd(sd_card_clk,system_reset_async,rst_sd);
    player_reset reset_mem(ext_mem_clk,system_reset_async,rst_mem);
    player_reset #(.FALLING_RELEASE(1)) reset_video(video_clk,system_reset_async,rst_video);
    player_reset reset_board(sd_card_clk,system_reset_async,rst_board);
    // Telemetry reset follows the existing board reset source.
    player_reset reset_serial(video_clk,reset_async,rst_uart);

    wire init_done,refresh,busy;
    wire rd_en,rd_valid,wr_en;
    wire [20:0] rd_addr,wr_addr;
    wire [31:0] rd_data,wr_data;
    wire [3:0] wr_mask;
    wire frame_req,frame_ack,read_en;
    wire [7:0] read_pixel332;
    // Preserve the existing RGB888 effects/UI/HDMI interface and its latency.
    // Bit replication maps the full RGB332 range back to 0..255 per channel.
    wire [23:0] read_data={read_pixel332[7:5],read_pixel332[7:5],read_pixel332[7:6],
                          read_pixel332[4:2],read_pixel332[4:2],read_pixel332[4:3],
                          {4{read_pixel332[1:0]}}};
    wire write_req,write_ack,write_en,write_finish,write_flip,overflow,underflow,write_ready;
    wire [7:0] write_data;
    wire [3:0] write_bank,pending_bank,pending_picture,active_bank,active_picture;
    wire pending_scaled,active_scaled,commit_request,commit_ack;
    wire commit_auto,music_beat;
    wire [23:0] ambient_color;
    wire wav_sample_valid;
    reg wav_seen,wav_active,picture_layout;
    wire [4:0] picture_zoom_phase;
    wire picture_zoom_moving;
    wire [7:0] picture_zoom_size;
    wire [9:0] picture_zoom_left;
    wire [9:0] picture_zoom_top;
    wire [9:0] picture_zoom_width,picture_zoom_height;
    wire [43:0] expand_native_rect,picture_native_rect;
    wire [31:0] pending_resolution;
    // The storage payload stays fixed until commit_ack. Publish its picture
    // ID before the synchronized request reaches the thumbnail animation.
    (* async_reg="true" *) reg [2:0] preview_request_sync;
    reg [3:0] preview_picture_meta,preview_picture_sync;
    always @(posedge video_clk or posedge rst_video) begin
        if(rst_video) begin preview_request_sync<=0;preview_picture_meta<=0;preview_picture_sync<=0;end
        else begin
            preview_request_sync<={preview_request_sync[1:0],commit_request};
            preview_picture_meta<=pending_picture;preview_picture_sync<=preview_picture_meta;
        end
    end
    wire [39:0] active_resolution;
    wire display_valid;
    wire slide_active;
    wire effect_mask_active;
    wire [2:0] effect_mask_style;
    wire [5:0] effect_mask_level;
    wire [19:0] slide_offset;
    wire [3:0] slide_bank;
    wire [8:0] gain,contrast;
    wire signed [8:0] brightness;
    wire signed [8:0] manual_brightness;
    wire light_valid,light_online,mic_valid,sensor_alarm,sensor_alarm_clear;
    wire [15:0] light_raw;
    wire [11:0] mic_sample;
    wire sensor_dark;
    wire [11:0] sensor_sound_level;
    wire [3:0] physical_switches;
    wire [127:0] uart_status;
    wire next_toggle,auto_toggle,auto_play;
    wire [3:0] interval_seconds,volume,modes;
    wire [8:0] available;
    wire [2:0] menu;
    wire [3:0] transition_mode;
    wire browse,select_toggle;
    wire expand_active,expand_moving;
    wire [3:0] expand_target;
    wire [4:0] expand_phase;
    wire [7:0] expand_size;
    wire [9:0] expand_left;
    wire [9:0] expand_top;
    wire [9:0] expand_width,expand_height;
    wire [1:0] expand_border;
    wire [2:0] expand_dim;
    wire preview_visible=browse || expand_active;
    wire directory,status_panel,alarm,sound_alarm;
    wire directory_active;
    wire [2:0] directory_dim;
    wire directory_run;
    wire [1:0] run_mode;
    wire [1:0] audio_select;
    wire [1:0] directory_focus;
    wire [3:0] focus,select_index,thumbnail_slot;
    wire [8:0] thumbnail_valid,thumbnail_failed;
    reg [8:0] failed_meta,failed_sync,failed_frame;
    wire thumbnail_write;
    wire [15:0] thumbnail_x,thumbnail_y;
    wire [23:0] thumbnail_rgb;
    reg [8:0] ready_meta,ready_sync,ready_frame,available_meta,available_sync,available_frame;
    wire audio_valid,tone_valid,acr_valid;
    wire [23:0] audio_left,audio_right,tone_left,tone_right;
    wire media_valid;
    wire [23:0] media_pcm;
    wire [7:0] audio_status;
    wire fixed_visual_audio=physical_switches[3] || !wav_active;
    reg [7:0] audio_meta,audio_sync,audio_frame;
    wire [7:0] error_sd;
    wire no_signal_sd;
    (* async_reg="true" *) reg [1:0] no_signal_sync;
    reg no_signal_frame;
    wire [3:0] state_sd;
    wire [59:0] debug_sd;
    wire debug_toggle_sd;
    reg [59:0] debug_meta,debug_sync,debug_latest,debug_frame;
    reg [2:0] debug_toggle_sync;
    reg [7:0] error_meta,error_sync,error_frame;
    reg [3:0] state_meta,state_sync,state_frame;
    reg [1:0] auto_sync;
    reg auto_frame;
    wire hs0,vs0,de0,hs,vs,de;
    wire [23:0] raw_rgb;
    reg last_vs;
    wire frame_tick=last_vs && !vs0;
    player_picture_zoom #(.MODE_576(0),.NATIVE_RECT_ENABLE(1)) picture_zoom(.clk(video_clk),.rst(rst_video),.frame_tick(frame_tick),
        .fullscreen(modes[0]),.pause(!display_valid || preview_visible || directory_active || alarm),
        .phase(picture_zoom_phase),.moving(picture_zoom_moving),
        .size(picture_zoom_size),.left(picture_zoom_left),.top(picture_zoom_top),
        .width(picture_zoom_width),.height(picture_zoom_height),.native_rect(picture_native_rect));
    always @(posedge video_clk or posedge rst_video) begin
        if(rst_video) begin
            last_vs<=1;error_meta<=0;error_sync<=0;error_frame<=0;
            state_meta<=0;state_sync<=0;state_frame<=0;auto_sync<=0;auto_frame<=0;
            debug_meta<=0;debug_sync<=0;debug_latest<=0;debug_frame<=0;debug_toggle_sync<=0;
            ready_meta<=0;ready_sync<=0;ready_frame<=0;
            failed_meta<=0;failed_sync<=0;failed_frame<=0;
            available_meta<=0;available_sync<=0;available_frame<=0;
            audio_meta<=0;audio_sync<=0;audio_frame<=0;
            no_signal_sync<=0;no_signal_frame<=0;
        end else begin
            last_vs<=vs0;error_meta<=error_sd;error_sync<=error_meta;
            state_meta<=state_sd;state_sync<=state_meta;auto_sync<={auto_sync[0],auto_play};
            debug_meta<=debug_sd;debug_sync<=debug_meta;
            debug_toggle_sync<={debug_toggle_sync[1:0],debug_toggle_sd};
            ready_meta<=thumbnail_valid;ready_sync<=ready_meta;
            failed_meta<=thumbnail_failed;failed_sync<=failed_meta;
            available_meta<=available;available_sync<=available_meta;
            audio_meta<=audio_status;audio_sync<=audio_meta;
            no_signal_sync<={no_signal_sync[0],no_signal_sd};
            if(debug_toggle_sync[2]!=debug_toggle_sync[1]) debug_latest<=debug_sync;
            if(frame_tick) begin
                error_frame<=display_valid && underflow ? 8'h41 : error_sync;
                state_frame<=state_sync;auto_frame<=auto_sync[1];
                debug_frame<=debug_latest;
                ready_frame<=ready_sync;available_frame<=available_sync;audio_frame<=audio_sync;
                failed_frame<=failed_sync;
                no_signal_frame<=no_signal_sync[1];
            end
        end
    end
    reg [8:0] write_drain;
    reg write_finish_toggle;
    always @(posedge ext_mem_clk or posedge rst_mem) begin
        if(rst_mem) begin write_drain<=0;write_finish_toggle<=0;end
        else if(write_ack) write_drain<=0;
        else if(write_finish) write_drain<=256;
        else if(write_drain!=0) begin
            write_drain<=write_drain-1'b1;
            if(write_drain==1) write_finish_toggle<=!write_finish_toggle;
        end
    end
    player_light_sensor #(.QUARTER_CYCLES(326),.POLL_FRAMES(16)) light_sensor(.clk(video_clk),.rst(rst_video),.frame_tick(frame_tick),
        .scl(sensor_scl),.sda(sensor_sda),.valid(light_valid),.online(light_online),.raw(light_raw));
    player_microphone_adc #(.CLK_HZ(VIDEO_HZ)) microphone(.clk(video_clk),.rst(rst_video),.valid(mic_valid),.sample(mic_sample));
    // 65 MHz: normal ADC EOC gaps are 332..336 clocks; allow 1024 before timeout.
    player_sensor_policy #(.SAMPLE_TIMEOUT_CYCLES(1024)) sensors(.clk(video_clk),.rst(rst_video),.frame_tick(frame_tick),
        .light_valid(light_valid),.light_online(light_online),.light_raw(light_raw),
        .manual_brightness(manual_brightness),.edit_mode(modes[3]),.alarm(alarm),
        .sample_valid(mic_valid),.sample(mic_sample),.brightness(brightness),.alarm_request(sensor_alarm),
        .dark(sensor_dark),.sound_level(sensor_sound_level),.alarm_clear_request(sensor_alarm_clear));
    // Network state resets on physical reset/PLL loss.
    // restarts the endpoint; a disconnected peer cannot release its warning.
    wire network_alarm,network_online,network_valid,network_link;
    net_endpoint #(.IS_B(0)) network(.clk(clk),.rst(reset_async),.local_flags(8'd0),
        .eth_rx_clk(eth_rx_clk),.eth_rx_ctl(eth_rx_ctl),.eth_rxd(eth_rxd),
        .eth_tx_clk(eth_tx_clk),.eth_tx_ctl(eth_tx_ctl),.eth_txd(eth_txd),
        .eth_mdc(eth_mdc),.eth_mdio(eth_mdio),.remote_alarm(network_alarm),
        .online(network_online),.remote_valid(network_valid),.link_ok(network_link));
    assign net_led_n={!(network_online && network_valid),!network_link};
    (* async_reg="true" *) reg [1:0] network_alarm_sync;
    always @(posedge video_clk or posedge rst_video)
        if(rst_video) network_alarm_sync<=0;
        else network_alarm_sync<={network_alarm_sync[0],network_alarm};
    wire network_alarm_display;
    net_alarm_hold #(.MS_CYCLES(VIDEO_HZ/1000),.HOLD_MS(3000)) alarm_hold(
        .clk(video_clk),.rst(rst_video),
        .upstream_alarm(network_alarm_sync[1]),.display_alarm(network_alarm_display));
    // UART is telemetry-only in the production image; all local, network and
    // sensor controls keep their original behavior and priority.
    player_control #(.SENSOR_ENABLE(1),.REMOTE_ENABLE(0),.NETWORK_ENABLE(1),.CURRENT_PICTURE_FOCUS_ENABLE(1),
        .DEBOUNCE_CYCLES(1300000),.LONG_CYCLES(52000000),
        .KEY_LONG_FRAMES(48),.KEY_REPEAT_FRAMES(12)) controls(
        .clk(video_clk),.rst(rst_video),.frame_tick(frame_tick),
        .key_next(key1),.key_auto(key2),.key_menu(key3),.switches(sw),
        .next_toggle(next_toggle),.auto_toggle(auto_toggle),.brightness(manual_brightness),
        .contrast(contrast),.volume(volume),.interval_seconds(interval_seconds),.menu(menu),.modes(modes),
        .available(available_frame),.thumbnail_valid(ready_frame),.browse(browse),.focus(focus),
        .select_toggle(select_toggle),.select_index(select_index),
        .directory(directory),.directory_focus(directory_focus),.status_panel(status_panel),
        .alarm(alarm),.auto_active(auto_frame),.directory_run(directory_run),.run_mode(run_mode),.audio_select(audio_select),
        .sensor_alarm(sensor_alarm),.sensor_alarm_clear(sensor_alarm_clear),.sound_alarm(sound_alarm),.transition_mode(transition_mode),
        .network_alarm(network_alarm_display),
        .playback_fault(state_frame==4'd9 || state_frame==4'd10),
        .remote_valid(1'b0),.remote_command(8'd0),.remote_argument(24'd0),
        .remote_done(),.remote_result(),
        .remote_switch_mask(),.remote_switch_value(),
        .physical_switches(physical_switches),.current_picture(active_picture));
    // Version-2 telemetry: captured atomically by the UART on each request.
    assign uart_status[0 +: 24]=24'h024142; // "BA", protocol 2
    assign uart_status[24 +: 8]={sensor_dark,light_online,sound_alarm,alarm,status_panel,directory,browse,display_valid};
    assign uart_status[32 +: 16]=light_raw;
    assign uart_status[48 +: 16]={4'd0,sensor_sound_level};
    assign uart_status[64 +: 8]={4'd0,active_picture};
    assign uart_status[72 +: 8]={modes,physical_switches};
    assign uart_status[80 +: 8]={4'd0,state_frame};
    assign uart_status[88 +: 8]=error_frame;
    assign uart_status[96 +: 8]=audio_frame;
    assign uart_status[104 +: 8]={volume,interval_seconds};
    assign uart_status[112 +: 16]={{7{brightness[8]}},brightness};
    player_uart_status #(.CLK_HZ(VIDEO_HZ)) serial_control(.clk(video_clk),.rst(rst_uart),.rx(uart_rx),.tx(uart_tx),
        .status_payload(uart_status));
    sd_card_bmp #(.FRAME_WIDTH(1024),.FRAME_HEIGHT(768),.MODE_576(0),.WRITE_DATA_BITS(8),.UI_PAUSE_ENABLE(1),.FRAME_CACHE_ENABLE(1),.GENERAL_SCALE(1),.RUN_MODE_CONTROL(1),.HOTPLUG_ENABLE(1),.AUDIO_SELECT_ENABLE(1)) storage(
        .clk(sd_card_clk),.rst(rst_sd),.next_toggle(next_toggle),.auto_toggle(auto_toggle),
        .interval_seconds(interval_seconds),.commit_ack_toggle(commit_ack),
        .write_finish_toggle(write_finish_toggle),.write_overflow(overflow),.write_ready(write_ready),
        .commit_toggle(commit_request),.commit_auto(commit_auto),.write_buf_idx(write_bank),.disp_buf_idx(pending_bank),
        .picture_id(pending_picture),.state_code(state_sd),.error_code(error_sd),
        .auto_play(auto_play),.scaled_image(pending_scaled),.available_images(available),
        .write_req(write_req),.write_req_ack(write_ack),.write_en(write_en),
        .write_data(write_data),.write_v_flip(write_flip),
        .SD_nCS(sd_ncs),.SD_DCLK(sd_dclk),.SD_MOSI(sd_mosi),.SD_MISO(sd_miso),
        .debug_status(debug_sd),.debug_toggle(debug_toggle_sd),
        .audio_clk(video_clk),.audio_rst(rst_video),.audio_tick(tone_valid),.tone(tone_left),
        .volume(volume),.mute(modes[2]),.audio_valid(media_valid),.audio_pcm(media_pcm),.audio_status(audio_status),
        .audio_wav_sample_valid(wav_sample_valid),.audio_select(audio_select),
        .ui_pause(directory_active || alarm),
        .browse(preview_visible),.select_toggle(select_toggle),.select_index(select_index),.thumbnail_valid(thumbnail_valid),
        .thumbnail_failed(thumbnail_failed),
        .thumbnail_write(thumbnail_write),.thumbnail_slot(thumbnail_slot),
        .thumbnail_x(thumbnail_x),.thumbnail_y(thumbnail_y),.thumbnail_rgb(thumbnail_rgb),
        .run_auto(run_mode==2),.source_resolution(pending_resolution),.no_signal(no_signal_sd));
    thumbnail_expand #(.MODE_576(0),.FRAME_HZ(FRAME_HZ),.NATIVE_RECT_ENABLE(1)) expand_card(.clk(video_clk),.rst(rst_video),.frame_tick(frame_tick),
        .browse(browse),.select_toggle(select_toggle),.select_index(select_index),.ready(ready_frame),
        .active_picture(active_picture),.pending_picture(preview_picture_sync),.display_valid(display_valid),
        .request_toggle(preview_request_sync[2]),.ack_toggle(commit_ack),
        .directory(directory),.status_panel(status_panel),.alarm(alarm),.effects_disabled(physical_switches[1]),
        .active(expand_active),.moving(expand_moving),.target(expand_target),.phase(expand_phase),
        .size(expand_size),.left(expand_left),.top(expand_top),.border_size(expand_border),.dim(expand_dim),
        .width(expand_width),.height(expand_height),.native_rect(expand_native_rect));
    player_transition #(.FRAME_WIDTH(1024),.FRAME_HEIGHT(768),.BEAT_WAIT_FRAMES(30),.SLIDE_ENABLE(1),.MULTI_EFFECT_ENABLE(1),.DIRECTORY_HOLD_ENABLE(1),.THUMBNAIL_SELECT_ENABLE(1),.BEAT_SYNC_ENABLE(1)) transition(
        .clk(video_clk),.rst(rst_video),.frame_tick(frame_tick),
        .request_toggle(commit_request),.pending_bank(pending_bank),.pending_picture(pending_picture),
        .pending_scaled(pending_scaled),.ack_toggle(commit_ack),.active_bank(active_bank),
        .active_picture(active_picture),.active_scaled(active_scaled),.display_valid(display_valid),.gain(gain),
        .pending_resolution(pending_resolution),.active_resolution(active_resolution),
        .transition_mode(transition_mode),.effect_pause(alarm || directory_active || preview_visible),
        .directory_hold(directory_active || (expand_active && alarm)),.thumbnail_select(expand_active),
        .effects_disabled(physical_switches[1]),
        .request_auto(commit_auto),.music_active(!fixed_visual_audio && !modes[2] && !no_signal_frame),.music_beat(music_beat),
        .slide_active(slide_active),.slide_offset(slide_offset),.slide_bank(slide_bank),
        .mask_active(effect_mask_active),.mask_style(effect_mask_style),.mask_level(effect_mask_level));

    // Word-align each zoom row; no display enlargement RAM is required.
    wire [10:0] native_left,native_top,native_width,native_height;
    assign {native_left,native_top,native_width,native_height}=
        expand_moving ? expand_native_rect : picture_native_rect;
    wire render_frame_toggle;
    player_xga_native_timing video_timing_data_m0(.clk(video_clk),.rst(rst_video),
        .request(frame_req),.ack(frame_ack),.hs(hs0),.vs(vs0),.de(de0),.frame_toggle(render_frame_toggle));
    video_delay video_delay_m0(.video_clk(video_clk),.rst(rst_video),
        .read_en(read_en),.read_data(read_data),.hs(hs0),.vs(vs0),.de(de0),
        .hs_r(hs),.vs_r(vs),.de_r(de),.vout_data(raw_rgb));
    frame_read_write #(.FRAME_WIDTH(1024),.FRAME_HEIGHT(768),.EXPLICIT_ZOOM(1),.READ_DATA_BITS(8),.WRITE_DATA_BITS(8),.BURST_SIZE(128),.WRITE_V_FLIP(0),.SLIDE_ENABLE(1),.ZOOM_ENABLE(1)) frame_read_write_m0(
        .rst(rst_mem),.mem_clk(ext_mem_clk),.Sdr_init_done(init_done),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),
        .App_rd_en(rd_en),.App_rd_addr(rd_addr),.Sdr_rd_en(rd_valid),.Sdr_rd_dout(rd_data),
        .read_clk(video_clk),.read_req(frame_req),.read_req_ack(frame_ack),.read_finish(),
        .read_addr_0(21'd0),.read_addr_1(21'd196608),.read_addr_2(21'd393216),.read_addr_3(21'd589824),
        .read_addr_4(21'd786432),.read_addr_5(21'd983040),
        .read_addr_6(21'd1179648),.read_addr_7(21'd1376256),.read_addr_8(21'd1572864),
        .read_addr_index(active_bank),.read_len(21'd196608),.read_en(read_en),.read_data(read_pixel332),
        .App_wr_en(wr_en),.App_wr_addr(wr_addr),.App_wr_din(wr_data),.App_wr_dm(wr_mask),
        .write_clk(sd_card_clk),.write_req(write_req),.write_req_ack(write_ack),.write_finish(write_finish),
        .write_addr_0(21'd0),.write_addr_1(21'd196608),.write_addr_2(21'd393216),.write_addr_3(21'd589824),
        .write_addr_4(21'd786432),.write_addr_5(21'd983040),
        .write_addr_6(21'd1179648),.write_addr_7(21'd1376256),.write_addr_8(21'd1572864),
        .write_addr_index(write_bank),.write_len(21'd196608),.write_en(write_en),.write_data(write_data),
        .write_v_flip(write_flip),.write_overflow(overflow),.read_underflow(underflow),.write_ready(write_ready),
        .slide_active(slide_active),.slide_offset(slide_offset),.slide_bank(slide_bank),
        .zoom_active(expand_moving || picture_layout),.zoom_size(expand_moving ? expand_size : picture_zoom_size),
        .zoom_left(native_left),.zoom_top(native_top),
        .zoom_width(native_width),
        .zoom_height(native_height));
    sdram U3(.Clk(ext_mem_clk),.Clk_sft(ext_mem_clk_sft),.Rst(rst_mem),
        .Sdr_init_done(init_done),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),
        .App_wr_en(wr_en),.App_wr_addr(wr_addr),.App_wr_dm(wr_mask),.App_wr_din(wr_data),
        .App_rd_en(rd_en),.App_rd_addr(rd_addr),.Sdr_rd_en(rd_valid),.Sdr_rd_dout(rd_data));

    wire [19:0] acr_cts,acr_n;
    player_audio #(.NO_SIGNAL_TONE_ENABLE(1),.CLK_HZ(VIDEO_HZ)) audio(.clk(video_clk),.rst(rst_video),
        .picture(no_signal_frame ? 4'd15 : active_picture),
        .volume(volume),.mute(modes[2]),.valid(tone_valid),.left(tone_left),.right(tone_right),
        .acr_valid(acr_valid),.acr_cts(acr_cts),.acr_n(acr_n));
    assign audio_right=audio_left;
    // Physical SW4 selects audio: 0 = WAV (or its existing tone fallback),
    // 1 = the current picture's built-in tone. Both sources share the 48 kHz
    // cadence; alarm_audio samples this mux on media_valid. WAV playback keeps
    // advancing, so changing SW4 neither resets storage nor restarts a track.
    // Keep the missing-card tone running while the SD/WAV FIFO is held in
    // reset for automatic remount. Match the existing media_valid latency so
    // switching to/from this source keeps the same 48 kHz sample boundaries.
    reg tone_valid_delayed;
    always @(posedge video_clk or posedge rst_video)
        if(rst_video) tone_valid_delayed<=0;
        else tone_valid_delayed<=tone_valid;
    wire selected_media_valid=no_signal_frame ? tone_valid_delayed : media_valid;
    wire [23:0] selected_media_pcm=(no_signal_frame || physical_switches[3]) ? tone_left : media_pcm;
    player_alarm_audio alarm_audio(.clk(video_clk),.rst(rst_video),.enable(alarm),
        .tick(tone_valid),.mute(modes[2]),.volume(volume),.media_valid(selected_media_valid),.media_pcm(selected_media_pcm),
        .valid(audio_valid),.pcm(audio_left));
    player_buzzer buzzer(.clk(video_clk),.rst(rst_video),.enable(alarm),
        .mute(modes[2]),.tick(tone_valid),.buzzer_n(buzzer_n));
    wire thumb_hs,thumb_vs,thumb_de;
    wire [23:0] thumb_rgb;
    thumbnail_scene #(.MODE_576(0),.MODE_XGA(1),.PRECOMPUTED_GEOMETRY(1)) previews(
        .write_clk(sd_card_clk),.write_enable(thumbnail_write),.write_slot(thumbnail_slot),
        .pixel_x(thumbnail_x),.pixel_y(thumbnail_y),.pixel_rgb(thumbnail_rgb),
        .clk(video_clk),.rst(rst_video),.hs(hs),.vs(vs),.de(de),.rgb(raw_rgb),
        .browse(browse),.focus(focus),.ready(ready_frame),.available(available_frame),
        .failed(failed_frame),
        .active(expand_active),.moving(expand_moving),.target(expand_target),
        .left(expand_left),.top(expand_top),.size(expand_size),.border_size(expand_border),.dim(expand_dim),
        .explicit_width(expand_width),.explicit_height(expand_height),.native_rect(expand_native_rect),
        .out_hs(thumb_hs),.out_vs(thumb_vs),.out_de(thumb_de),.out_rgb(thumb_rgb));
    wire fx_hs,fx_vs,fx_de;
    wire [23:0] fx_rgb;
    // SW1 平滑切换图片大小及音乐叠加层；顶部状态栏保持显示。
    // SW2 为转场总开关（0 开启、1 关闭），特效类型来自设置。
    // 目录/预览仍隐藏音频图层，报警仍强制显示红色波形与频谱。
    wire hide_audio_visuals=!alarm && (modes[0] || picture_zoom_phase!=0 || preview_visible || directory);
    always @(posedge video_clk or posedge rst_video) begin
        if(rst_video) begin wav_seen<=0;wav_active<=0;picture_layout<=0;end
        else begin
            if(wav_sample_valid) wav_seen<=1;
            if(frame_tick) begin
                wav_active<=wav_seen || wav_sample_valid;wav_seen<=0;
                picture_layout<=display_valid && !preview_visible && !directory_active && !alarm;
            end
        end
    end
    player_music_dynamics #(.PIPELINED_COLOR(1)) music_dynamics(.clk(video_clk),.rst(rst_video),.frame_tick(frame_tick),
        .fixed_audio(fixed_visual_audio || alarm),.audio_valid(audio_valid),.audio_sample(audio_left),
        .beat(music_beat),.color(ambient_color));
    // Reuse the existing RGB gain multipliers for the background fade. The
    // directory itself is drawn afterwards, so its text keeps full brightness.
    wire [8:0] background_gain=preview_visible ? 9'd256 : gain;
    reg [8:0] directory_gain;
    always @* begin
        case(directory_dim)
            1:directory_gain=background_gain-(background_gain>>3);
            2:directory_gain=background_gain-(background_gain>>2);
            3:directory_gain=(background_gain>>1)+(background_gain>>3);
            4:directory_gain=background_gain>>1;
            default:directory_gain=background_gain;
        endcase
    end
    player_video #(.MODE_576(0),.MODE_XGA(1),.CLK_HZ(VIDEO_HZ),.UI_ENABLE(1),.WAVE_MUSIC_ENABLE(2),.PANEL_ALPHA_ENABLE(1),.IMAGE_EFFECTS_ENABLE(1),.AMBIENT_ENABLE(1),.AMBIENT_ZOOM_ENABLE(1)) effects(.clk(video_clk),.rst(rst_video),.hs(thumb_hs),.vs(thumb_vs),.de(thumb_de),.rgb(thumb_rgb),
        .ambient_color(ambient_color),.picture_layout(picture_layout),
        .layout_size(picture_zoom_size),.layout_left(picture_zoom_left),.layout_top(picture_zoom_top),
        .layout_width(picture_zoom_width),.layout_height(picture_zoom_height),
        .effect_mask_active(effect_mask_active && !preview_visible),.effect_mask_style(effect_mask_style),.effect_mask_level(effect_mask_level),
        .brightness(brightness),.contrast(contrast),.gain(directory_gain),.display_valid(display_valid || preview_visible),
        .picture(active_picture),.scaled(active_scaled),.auto_play(auto_frame),.error_code(error_frame),
        .state_code(state_frame),.volume(volume),.interval_seconds(interval_seconds),.menu(menu),.transition_mode(transition_mode),
        .modes({modes[3:2],hide_audio_visuals,1'b0}),
        .audio_valid(audio_valid),.audio_sample(audio_left),.out_hs(fx_hs),.out_vs(fx_vs),.out_de(fx_de),.out_rgb(fx_rgb),
        .debug_status(debug_frame),.audio_status(audio_frame),.image_valid(display_valid),
        .ui_directory(directory),.ui_status(status_panel),.ui_alarm(alarm),.ui_browse(preview_visible),
        .source_resolution(active_resolution),.run_mode(run_mode),.audio_select(audio_select));
    // RGB 和同步信号一起经过频谱一级流水，保持像素对齐。
    wire spectrum_hs,spectrum_vs,spectrum_de;
    wire [23:0] spectrum_rgb;
    reg fx_hs_q,fx_vs_q,fx_de_q;
    reg [23:0] fx_rgb_q;
    // Register the completed effects pixel before spectrum alpha blending.
    // Sync and RGB take the same clock; the frame and pixel count are intact.
    always @(posedge video_clk or posedge rst_video) begin
        if(rst_video) begin fx_hs_q<=1;fx_vs_q<=1;fx_de_q<=0;fx_rgb_q<=0;end
        else begin fx_hs_q<=fx_hs;fx_vs_q<=fx_vs;fx_de_q<=fx_de;fx_rgb_q<=fx_rgb;end
    end
    audio_spectrum_overlay #(.AMBIENT_ENABLE(1),.MODE_576(0),.MODE_XGA(1)) spectrum_display(
        .ambient_color(ambient_color),.picture_layout(picture_layout),
        .clk(video_clk),.rst(rst_video),.enable(!hide_audio_visuals),
        .hs(fx_hs_q),.vs(fx_vs_q),.de(fx_de_q),.rgb_in(fx_rgb_q),
        .audio_valid(audio_valid),.audio_sample(audio_left),
        .hs_out(spectrum_hs),.vs_out(spectrum_vs),.de_out(spectrum_de),.rgb_out(spectrum_rgb),.alarm(alarm));
    wire axis_user,axis_valid,axis_last,axis_ready,edid_trig;
    wire [23:0] axis_data;
    wire [9:0] t0,t1,t2,tc;
    wire ui_hs,ui_vs,ui_de;
    wire [23:0] ui_rgb;
    player_ui_overlay #(.SOUND_SCENE_ENABLE(1),.MODE_576(0),.MODE_XGA(1),.BOOT_FRAMES(210),.LOGO_ENABLE(1),.NO_SIGNAL_ENABLE(1),.BOOT_ENABLE(1),.DIRECTORY_ANIMATION_ENABLE(1),.DIRECTORY_EXTERNAL_DIM(1)) ui(.clk(video_clk),.rst(rst_video),.hs(spectrum_hs),.vs(spectrum_vs),
        .de(spectrum_de),.rgb(spectrum_rgb),.directory(directory),.selection(directory_focus),.alarm(alarm),.sound_alarm(sound_alarm),
        .out_hs(ui_hs),.out_vs(ui_vs),.out_de(ui_de),.out_rgb(ui_rgb),.directory_run(directory_run),.no_signal(no_signal_frame),
        .boot_ready(display_valid || error_frame!=0),.directory_active(directory_active),.background_dim(directory_dim));
    wire xga_hs,xga_vs,xga_de;
    wire [23:0] xga_rgb,hdmi_pcm;
    wire hdmi_audio_valid,hdmi_acr_valid;
    assign xga_hs=ui_hs;assign xga_vs=ui_vs;assign xga_de=ui_de;assign xga_rgb=ui_rgb;
    assign hdmi_audio_valid=audio_valid;assign hdmi_pcm=audio_left;assign hdmi_acr_valid=acr_valid;
    video_rgb_to_axis_640x480 #(.WIDTH(1024)) axis(.I_clk(pixel_clk),.I_rst(rst_pixel),.I_vs(xga_vs),
        .I_de(xga_de),.I_rgb(xga_rgb),.O_video_user(axis_user),.O_video_valid(axis_valid),
        .O_video_last(axis_last),.O_video_data(axis_data));
    startup_pulse #(.CNT_MAX(20'd260000)) edid(.I_clk(pixel_clk),.I_rst(rst_pixel),.O_pulse(edid_trig));
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"),.HTOTAL(1344),.HSA(136),.HFP(24),.HBP(160),.HACTIVE(1024),
        .VTOTAL(806),.VSA(6),.VFP(3),.VBP(29),.VACTIVE(768),.VIDEO_VIC(0),
        .VIDEO_TPG("Disable"),.VIDEO_FORMAT("RGB"),.AUDIO_SAMPLE_RATE("48K"),.IIC_SCL_DIV(650)
    ) u_hdmi_1_4b_transmitter_core_wrapper(
        .I_pixel_clk(pixel_clk),.I_rst(rst_pixel),.I_edid_read_trig(edid_trig),
        .O_edid_read_valid(),.O_edid_read_data(),
        .I_axis_s_user(axis_user),.I_axis_s_valid(axis_valid),.I_axis_s_last(axis_last),
        .I_axis_s_data(axis_data),.O_axis_s_ready(axis_ready),
        .I_audio_valid(hdmi_audio_valid),.I_audio_left_data(hdmi_pcm),.I_audio_right_data(hdmi_pcm),
        .I_acr_valid(hdmi_acr_valid),.I_acr_cts(20'd65000),.I_acr_n(20'd6144),
        .O_video_locked(),.O_ddc_scl(HDMI_DDC_SCL),.IO_ddc_sda(HDMI_DDC_SDA),
        .O_ch0_tmds_data(t0),.O_ch1_tmds_data(t1),.O_ch2_tmds_data(t2),.O_clk_tmds_data(tc));
    hdmi_phy_wrapper #(.DEVICE("EG")) u_hdmi2phy_wrapper(
        .I_pixel_clk(pixel_clk),.I_serial_clk(hdmi_5x_clk),.I_rst(rst_pixel),
        .I_tmds_channel_0(t0),.I_tmds_channel_1(t1),.I_tmds_channel_2(t2),.I_tmds_channel_clk(tc),
        .O_tmds_ch0_p(HDMI_D0_P),.O_tmds_ch1_p(HDMI_D1_P),.O_tmds_ch2_p(HDMI_D2_P),.O_tmds_clk_p(HDMI_CLK_P));
    wire [6:0] seg_state,seg_picture,seg_err_hi,seg_err_lo;
    wire [15:0] seg_snapshot;
    player_status_cdc #(.WIDTH(16)) diagnostics(.source_clk(video_clk),.source_rst(rst_video),
        .update(frame_tick),.status({state_sync,active_picture,display_valid && underflow ? 8'h41 : error_sync}),
        .target_clk(sd_card_clk),.target_rst(rst_board),.snapshot(seg_snapshot));
    seg_decoder ds(seg_snapshot[15:12],seg_state);
    seg_decoder dp(seg_snapshot[11:8]+4'd1,seg_picture);
    seg_decoder dh(seg_snapshot[7:4],seg_err_hi);
    seg_decoder dl(seg_snapshot[3:0],seg_err_lo);
    wire [5:0] diagnostic_sel;
    wire [7:0] diagnostic_data;
    // SW4 selects audio only. Shared DIG/SEL pins always carry diagnostic scanning.
    assign seg_sel=diagnostic_sel;
    assign seg_data=diagnostic_data;
    assign seg_sel_extra=2'b11;
    seg_scan seg_scan_m0(.clk(sd_card_clk),.rst_n(!rst_board),.seg_sel(diagnostic_sel),.seg_data(diagnostic_data),
        .seg_data_0({1'b1,seg_err_lo}),.seg_data_1({1'b1,seg_err_hi}),
        .seg_data_2(8'hff),.seg_data_3({1'b1,seg_picture}),.seg_data_4(8'hff),.seg_data_5({1'b1,seg_state}));
endmodule

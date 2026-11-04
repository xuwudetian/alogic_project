`timescale 1ns/1ps
// FAT32 front end. Metadata is held until the pixel-domain commit acknowledgement.
module sd_card_bmp #(
    // 32-bit mode retains the standalone legacy test interface; top uses 24.
    parameter integer WRITE_DATA_BITS = 32,
    parameter integer FRAME_WIDTH = 640, FRAME_HEIGHT = 480,
    parameter integer MODE_576 = 0,
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer POWER_WAIT_CYCLES = CLK_FREQ_HZ/4,
    parameter integer READY_WAIT_CYCLES = CLK_FREQ_HZ/100,
    parameter integer BOOT_RETRIES = 2,
    parameter integer UI_PAUSE_ENABLE = 0,
    parameter integer FOUR_BANK_CACHE = 0, // Legacy parameter alias.
    parameter integer FRAME_CACHE_ENABLE = FOUR_BANK_CACHE,
    parameter integer GENERAL_SCALE = 0,
    parameter integer RUN_MODE_CONTROL = 0,
    parameter integer AUDIO_SELECT_ENABLE = 0,
    parameter integer HOTPLUG_ENABLE = 0,
    parameter integer PROBE_INTERVAL_CYCLES = CLK_FREQ_HZ,
    parameter integer REINSERT_WAIT_CYCLES = CLK_FREQ_HZ
) (
    input clk, input rst,
    input next_toggle, input auto_toggle,
    input [3:0] interval_seconds,
    input commit_ack_toggle,
    input write_finish_toggle,
    input write_overflow,
    output reg commit_toggle,
    output reg [3:0] write_buf_idx,
    output reg [3:0] disp_buf_idx,
    output reg [3:0] picture_id,
    output [3:0] state_code,
    output reg [7:0] error_code,
    output reg auto_play,
    output reg scaled_image,
    output [8:0] available_images,
    output reg write_req,
    input write_req_ack,
    output write_en,
    output [WRITE_DATA_BITS-1:0] write_data,
    output write_v_flip,
    output SD_nCS, output SD_DCLK, output SD_MOSI, input SD_MISO,
    output reg [59:0] debug_status,output reg debug_toggle,
    input write_ready,
    input audio_clk,input audio_rst,input audio_tick,input [23:0] tone,
    input [3:0] volume,input mute,output audio_valid,output [23:0] audio_pcm,
    output [7:0] audio_status,
    input browse,input select_toggle,input [3:0] select_index,
    output reg [8:0] thumbnail_valid,
    output thumbnail_write,output [3:0] thumbnail_slot,
    output [15:0] thumbnail_x,output [15:0] thumbnail_y,output [23:0] thumbnail_rgb,
    input ui_pause,
    output reg [8:0] thumbnail_failed,
    input run_auto,output reg [31:0] source_resolution,
    output reg no_signal,output audio_wav_sample_valid,
    input [1:0] audio_select,
    output reg commit_auto
);
    localparam INIT=0, SCAN=1, PICK=2, REQUEST=3, RELEASE=4;
    localparam LOAD=5, DRAIN=6, COMMIT=7, IDLE=8, FAILED=9, HALT=10;
    localparam POWER_WAIT=11, READY_WAIT=12, START_FILE=13;
    localparam [32:0] LOAD_TIMEOUT_CYCLES=33'd120*CLK_FREQ_HZ;
    localparam [31:0] INIT_TIMEOUT_CYCLES=32'd5*CLK_FREQ_HZ;
    reg [3:0] state;
    reg [2:0] next_sync, auto_sync, done_sync;
    reg [1:0] ack_sync, wrack_sync;
    reg [3:0] period_meta, period_sync;
    reg scan_start, file_start, pending_next, written, decoded;
    reg pending_auto,navigation_auto;
    reg first_frame;
    reg [3:0] selected;
    reg [3:0] navigation_index;
    reg [31:0] cluster, size;
    reg [25:0] second_count;
    reg [5:0] seconds_count;
    reg [32:0] watchdog;
    reg [31:0] settle_count;
    reg [1:0] boot_retries;
    reg [1:0] browse_sync;
    reg [3:0] index_meta,index_sync,requested_index;
    (* async_reg="true" *) reg [1:0] pause_sync;
    wire paused=UI_PAUSE_ENABLE!=0 && pause_sync[1];
    // 仅暂停新图片事务；已经开始的 SD/SDRAM 事务必须完整结束。
    always @(posedge clk or posedge rst)
        if(rst) pause_sync<=0;else pause_sync<={pause_sync[0],ui_pause};
    reg [2:0] select_sync;
    reg pending_select,background,browse_previous;
    reg [8:0] attempted;
    // Logical PIC slots may move after recovery: never overwrite the visible
    // bank until its replacement has been acknowledged in the pixel domain.
    reg [8:0] cache_valid,cache_scaled;
    reg [3:0] cache_bank[0:8];
    // 每张缓存图保存自己的 BMP 原始宽高，后台预加载不更新当前显示元数据。
    (* ram_style="dram" *) reg [31:0] cache_resolution[0:8];
    wire [31:0] decoded_resolution;
    (* async_reg="true" *) reg [1:0] run_auto_sync;
    always @(posedge clk or posedge rst)
        if(rst) run_auto_sync<=0;else run_auto_sync<={run_auto_sync[0],run_auto};
    wire [8:0] occupied_banks;
    genvar occupied_bank,occupied_slot;
    generate for(occupied_bank=0;occupied_bank<9;occupied_bank=occupied_bank+1) begin: bank_occupancy
        wire [8:0] occupied_hits;
        for(occupied_slot=0;occupied_slot<9;occupied_slot=occupied_slot+1) begin: slot_match
            assign occupied_hits[occupied_slot]=cache_valid[occupied_slot] && cache_bank[occupied_slot]==occupied_bank;
        end
        // Parallel reduction avoids nine priority-encoded variable bit writes.
        assign occupied_banks[occupied_bank]=(|occupied_hits) || (!first_frame && disp_buf_idx==occupied_bank);
    end endgenerate
    wire [8:0] free_banks=~occupied_banks;
    reg media_enabled;
    // State bits do not switch simultaneously on silicon. IDLE(1000)->PICK(0010)
    // can momentarily decode as HALT(1010); using that decode as an asynchronous
    // reset erases the catalog and turns the next image into a zero-length file.
    // Sample the stable state on the clock before driving any downstream reset.
    reg driver_reset_hold;
    always @(posedge clk or posedge rst)
        if(rst) driver_reset_hold<=1'b1;
        else driver_reset_hold<=(state==HALT || state==POWER_WAIT);
    wire driver_reset=rst || driver_reset_hold;
    wire service_reset=driver_reset;
    wire card_ready, scan_done, file_done, file_valid, bmp_done, frame_commit;
    wire scan_req, file_req, scan_busy, file_busy, header_accepted;
    wire [31:0] scan_lba, file_lba, file_offset, partition_lba;
    wire [31:0] fat_lba, data_lba, max_cluster;
    wire [31:0] catalog_cluster,catalog_size;
    wire [7:0] spc, scan_error, file_error, bmp_error, file_byte;
    wire [23:0] rgb;
    wire top_down, source_2x;
    wire pixel_valid,decoder_sector_room;
    wire full_frame_write=FRAME_CACHE_ENABLE!=0 || !background;
    wire is_scan = state == SCAN;
    wire sector_request;
    wire [31:0] requested_lba;
    wire sector_busy, sector_read, sector_done;
    wire backend_busy,backend_valid,backend_done,emit_ready,audio_owner;
    wire [7:0] backend_error;
    wire wav_req,wav_valid,wav_done,wav_ready,wav_urgent;
    wire [31:0] wav_lba,audio_cluster,audio_size;
    wire [7:0] wav_error;
    wire audio_found;
    wire [1:0] active_audio_select;
    reg [1:0] audio_select_hold,audio_select_sd;
    reg audio_select_request,audio_select_ack;
    (* async_reg="true" *) reg [1:0] audio_request_sync,audio_ack_sync;
    // Bundled-data mailbox: the UI payload stays fixed until the storage
    // domain acknowledges it. A rapid new selection is sent after that ACK.
    // This avoids transient mixed bits on transitions such as 2 -> 3.
    always @(posedge audio_clk or posedge audio_rst) begin
        if(audio_rst) begin audio_select_hold<=0;audio_select_request<=0;audio_ack_sync<=0;end
        else if(AUDIO_SELECT_ENABLE!=0) begin
            audio_ack_sync<={audio_ack_sync[0],audio_select_ack};
            if(audio_select_request==audio_ack_sync[1] && audio_select_hold!=audio_select) begin
                audio_select_hold<=audio_select;audio_select_request<=!audio_select_request;
            end
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin audio_request_sync<=0;audio_select_ack<=0;audio_select_sd<=0;end
        else if(AUDIO_SELECT_ENABLE!=0) begin
            audio_request_sync<={audio_request_sync[0],audio_select_request};
            if(audio_request_sync[1]!=audio_select_ack) begin
                audio_select_sd<=audio_select_hold;audio_select_ack<=audio_request_sync[1];
            end
        end
    end
    wire [31:0] sector_lba;
    wire [8:0] byte_index;
    wire [7:0] sector_error,raw_error,raw_byte;
    wire raw_valid,sector_end,slow_read;
    wire [7:0] sector_byte;
    wire sector_valid;
    // 无卡检测脚：成功的业务读本身就是心跳，完全缓存/暂停时才补读 LBA0。
    localparam integer MAINT_MAX=PROBE_INTERVAL_CYCLES>REINSERT_WAIT_CYCLES ? PROBE_INTERVAL_CYCLES : REINSERT_WAIT_CYCLES;
    localparam integer MAINT_BITS=MAINT_MAX>0 ? $clog2(MAINT_MAX+1) : 1;
    reg [MAINT_BITS-1:0] maintenance_count;
    reg was_retry;
    wire retry_mode=state==FAILED || state==HALT;
    reg probe_req,probe_pending;
    wire probe_done;
    wire [7:0] probe_error;
    wire backend_fault=backend_done && backend_error!=0;
    wire rescan_due=HOTPLUG_ENABLE!=0 && (state==FAILED || state==HALT) &&
        maintenance_count>=REINSERT_WAIT_CYCLES && ack_sync[1]==commit_toggle;
    always @(posedge clk or posedge rst) begin
        if(rst) begin maintenance_count<=0;was_retry<=0;probe_req<=0;probe_pending<=0;end
        else begin
            probe_req<=0;was_retry<=retry_mode;
            // 探测与重试不会并发，复用一个最小位宽的饱和计数器。
            if(HOTPLUG_ENABLE==0 || retry_mode!=was_retry) maintenance_count<=0;
            else if(retry_mode) begin
                if(maintenance_count<REINSERT_WAIT_CYCLES) maintenance_count<=maintenance_count+1'b1;
            end else if(driver_reset || (backend_done && backend_error==0)) maintenance_count<=0;
            else if(maintenance_count<PROBE_INTERVAL_CYCLES) maintenance_count<=maintenance_count+1'b1;
            if(driver_reset || HOTPLUG_ENABLE==0) probe_pending<=0;
            else begin
                if(probe_done) probe_pending<=0;
                if(state==IDLE && !sector_busy && !probe_pending && maintenance_count>=PROBE_INTERVAL_CYCLES) begin
                    probe_req<=1;probe_pending<=1;maintenance_count<=0;
                end
            end
        end
    end
    wire [59:0] sector_debug,file_debug,bmp_debug;
    wire sector_debug_toggle;
    reg last_sector_debug_toggle;
    assign state_code = state;
    // Cache mode fills a complete SDRAM frame and its thumbnail in one pass.
    assign write_en = pixel_valid && state == LOAD && full_frame_write;
    assign write_data = WRITE_DATA_BITS==8 ? {rgb[23:21],rgb[15:13],rgb[7:6]} :
                        WRITE_DATA_BITS==16 ? {rgb[23:19],rgb[15:10],rgb[7:3]} :
                        WRITE_DATA_BITS==24 ? rgb : {rgb,8'd0};
    assign write_v_flip = !top_down;
    assign thumbnail_write=pixel_valid && state==LOAD && !thumbnail_valid[selected];
    assign thumbnail_slot=selected;
    assign thumbnail_rgb=rgb;

    function [3:0] first_present;
        input [8:0] mask;
        begin
            if (mask[0]) first_present=0;
            else if (mask[1]) first_present=1;
            else if (mask[2]) first_present=2;
            else if (mask[3]) first_present=3;
            else if (mask[4]) first_present=4;
            else if (mask[5]) first_present=5;
            else if (mask[6]) first_present=6;
            else if (mask[7]) first_present=7;
            else first_present=8;
        end
    endfunction
    // 九项固定优先编码：先选当前项之后的最低有效项，再回绕。
    // 避免五级动态加法/索引串联；四位索引只接受0..8。
    function [3:0] next_present;
        input [3:0] current;
        input [8:0] mask;
        reg [3:0] preferred,wrapped;
        reg found;
        integer step;
        begin
            preferred=current;wrapped=current;found=0;
            for(step=8;step>=0;step=step-1) if(mask[step] && step!=current) begin
                wrapped=step;
                if(step>current) begin preferred=step;found=1;end
            end
            next_present=found ? preferred : wrapped;
        end
    endfunction

    // 前台命中与后台切图共用一个缓存读端口，避免三份宽数据多路器。
    // 只在后台 LOAD 时使用待处理索引；PICK 始终读取已锁存的 selected。
    wire [3:0] next_index=next_present(navigation_index,available_images);
    wire [3:0] cache_read_index=(background && state==LOAD) ?
        (pending_select ? requested_index : next_index) : selected;
    // 小位宽控制各自预译码，避免state->共享索引->有效位->区号长链。
    // 32位尺寸数据仍共用读端，节省主要的宽多路器开销。
    wire [31:0] cached_resolution=cache_resolution[cache_read_index];
    // RAM 无整体复位；cache_valid 清零屏蔽旧数据，完整写帧后同拍发布。
    // 深度仅九项，用分布式 RAM 保留全部32位原始尺寸而不消耗额外BRAM。
    always @(posedge clk) begin
        if(!rst && FRAME_CACHE_ENABLE!=0 && state==DRAIN &&
           decoded && (!full_frame_write || written))
            cache_resolution[selected]<=decoded_resolution;
    end

    sd_sector_guard #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) sector_guard(
        .clk(clk),.rst(service_reset),.request(sector_request),.requested_lba(requested_lba),
        .busy(backend_busy),.valid(backend_valid),.data(sector_byte),.byte_index(byte_index),
        .done(backend_done),.error(backend_error),.raw_request(sector_read),.raw_lba(sector_lba),
        .slow_read(slow_read),.raw_valid(raw_valid),.raw_data(raw_byte),.raw_done(sector_end),
        .raw_error(raw_error),.debug_status(sector_debug),.debug_toggle(sector_debug_toggle),
        .emit_ready(emit_ready));
    media_sector_arbiter #(.PROBE_ENABLE(HOTPLUG_ENABLE)) arbiter(
        .clk(clk),.rst(service_reset),.main_req(is_scan ? scan_req : file_req),
        .main_lba(is_scan ? scan_lba : file_lba),.audio_req(wav_req),.audio_lba(wav_lba),
        .audio_urgent(wav_urgent),.busy(sector_busy),.request(sector_request),.lba(requested_lba),
        .backend_busy(backend_busy),.backend_done(backend_done),.backend_valid(backend_valid),
        .backend_error(backend_error),.main_valid(sector_valid),.main_done(sector_done),.main_error(sector_error),
        .audio_valid(wav_valid),.audio_done(wav_done),.audio_error(wav_error),
        .main_ready(is_scan || GENERAL_SCALE!=0 || !full_frame_write || write_ready),.audio_ready(wav_ready),
        .emit_ready(emit_ready),.audio_owner(audio_owner),
        .probe_req(probe_req),.probe_done(probe_done),.probe_error(probe_error));
    media_wav #(.AUDIO_SELECT_ENABLE(AUDIO_SELECT_ENABLE)) wav(
        .clk(clk),.rst(driver_reset),.enable(media_enabled),.found(audio_found),
        .cluster(audio_cluster),.size(audio_size),.spc(spc),.fat_lba(fat_lba),.data_lba(data_lba),
        .max_cluster(max_cluster),.sector_req(wav_req),.sector_lba(wav_lba),.sector_busy(sector_busy),
        .sector_valid(wav_valid),.sector_byte(sector_byte),.byte_index(byte_index),
        .sector_done(wav_done),.sector_error(wav_error),.replay_ready(wav_ready),.urgent(wav_urgent),
        .audio_clk(audio_clk),.audio_rst(audio_rst),.tick(audio_tick),.tone(tone),.volume(volume),.mute(mute),
        .valid(audio_valid),.pcm(audio_pcm),.status(audio_status),
        .wav_sample_valid(audio_wav_sample_valid),.audio_select(audio_select_sd),
        .active_select(active_audio_select));

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=POWER_WAIT; next_sync<=0; auto_sync<=0; done_sync<=0;
            ack_sync<=0; wrack_sync<=0; period_meta<=3; period_sync<=3;
            scan_start<=0; file_start<=0; pending_next<=0; written<=0; decoded<=0;
            pending_auto<=0;navigation_auto<=0;commit_auto<=0;
            first_frame<=1; selected<=0; cluster<=0; size<=0;
            navigation_index<=0;
            commit_toggle<=0; write_buf_idx<=0; disp_buf_idx<=0; picture_id<=0;
            error_code<=0; auto_play<=0; scaled_image<=0; write_req<=0;
            second_count<=0; seconds_count<=0;
            watchdog<=0;
            settle_count<=0;boot_retries<=0;media_enabled<=0;
            browse_sync<=0;select_sync<=0;index_meta<=0;index_sync<=0;requested_index<=0;
            pending_select<=0;background<=0;browse_previous<=0;attempted<=0;thumbnail_valid<=0;thumbnail_failed<=0;
            cache_valid<=0;cache_scaled<=0;
            cache_bank[0]<=0;cache_bank[1]<=1;cache_bank[2]<=2;cache_bank[3]<=3;cache_bank[4]<=4;cache_bank[5]<=5;cache_bank[6]<=6;cache_bank[7]<=7;cache_bank[8]<=8;
            source_resolution<=0;
            no_signal<=0;
            debug_status<=0;debug_toggle<=0;last_sector_debug_toggle<=0;
        end else begin
            last_sector_debug_toggle<=sector_debug_toggle;
            if(last_sector_debug_toggle!=sector_debug_toggle && !audio_owner &&
               !(error_code>=8'h23 && error_code<=8'h26) && error_code!=8'h37 && state!=POWER_WAIT && state!=HALT) begin
                debug_status<=sector_debug;debug_toggle<=!debug_toggle;
            end
            next_sync<={next_sync[1:0],next_toggle};
            auto_sync<={auto_sync[1:0],auto_toggle};
            done_sync<={done_sync[1:0],write_finish_toggle};
            ack_sync<={ack_sync[0],commit_ack_toggle};
            wrack_sync<={wrack_sync[0],write_req_ack};
            period_meta<=interval_seconds; period_sync<=period_meta;
            browse_sync<={browse_sync[0],browse};
            browse_previous<=browse_sync[1] && !paused;
            // One attempt per preview visit. Keep an in-flight attempt accounted for.
            if(browse_sync[1] && !paused && !browse_previous)
                attempted<=thumbnail_valid | ((state>=PICK && state<=DRAIN) ? (9'b000000001<<selected) : 9'b000000000);
            select_sync<={select_sync[1:0],select_toggle};
            index_meta<=select_index;index_sync<=index_meta;
            if(select_sync[2]!=select_sync[1]) begin pending_select<=1;requested_index<=index_sync;end
            scan_start<=0; file_start<=0;
            if(state==INIT || state==REQUEST || state==RELEASE || state==START_FILE || state==LOAD || state==DRAIN)
                watchdog<=watchdog+1'b1;
            else watchdog<=0;
            // Large source files may take longer than 120 s; detect a stalled
            // transfer, not the total time spent making continuous progress.
            if(GENERAL_SCALE!=0 && state==LOAD && (file_valid || pixel_valid)) watchdog<=0;
            if(next_sync[2]^next_sync[1]) begin pending_next<=1;pending_auto<=0;end
            if(RUN_MODE_CONTROL!=0) auto_play<=run_auto_sync[1];
            else if(auto_sync[2]^auto_sync[1]) auto_play<=!auto_play;
            if(state != IDLE || !auto_play || browse_sync[1] || paused) begin
                second_count<=0; seconds_count<=0;
            end else if(second_count == CLK_FREQ_HZ-1) begin
                second_count<=0;
                if(seconds_count+1 >= period_sync) begin
                    pending_next<=1; seconds_count<=0;
                    pending_auto<=!(next_sync[2]^next_sync[1]);
                end else seconds_count<=seconds_count+1'b1;
            end else second_count<=second_count+1'b1;
            if((state==LOAD || state==DRAIN) && (done_sync[2]^done_sync[1]))
                written<=1;
            case(state)
                POWER_WAIT: begin
                    if(settle_count>=POWER_WAIT_CYCLES) begin
                        settle_count<=0;state<=INIT;last_sector_debug_toggle<=0;
                    end else settle_count<=settle_count+1'b1;
                end
                INIT: if(raw_error!=0) begin error_code<=raw_error;state<=HALT;end
                      else if(card_ready) begin settle_count<=0;state<=READY_WAIT;end
                READY_WAIT: if(settle_count>=READY_WAIT_CYCLES) begin
                    scan_start<=1;state<=SCAN;settle_count<=0;
                end else settle_count<=settle_count+1'b1;
                SCAN: if(scan_done) begin
                    if(scan_error!=0 || available_images==0) begin
                        error_code<=scan_error; state<=FAILED;
                        if(HOTPLUG_ENABLE!=0) no_signal<=1;
                        if(scan_error==8'h20 && boot_retries<BOOT_RETRIES) begin
                            boot_retries<=boot_retries+1'b1;settle_count<=0;state<=POWER_WAIT;
                        end
                    end else begin
                        media_enabled<=1;
                        selected<=first_present(available_images); state<=PICK;navigation_auto<=0;
                    end
                end
                PICK: begin
                    if(!background) navigation_index<=selected;
                    cluster<=catalog_cluster;size<=catalog_size;
                    write_buf_idx<=FRAME_CACHE_ENABLE!=0 ? first_present(free_banks) :
                        (first_frame ? 4'd0 : {3'b0,!disp_buf_idx[0]});
                    write_req<=full_frame_write; written<=0; decoded<=0;
                    if(!background) error_code<=0;
                    pending_next<=0;
                    if(!full_frame_write) state<=START_FILE;
                    else state<=REQUEST;
                    attempted[selected]<=1;
                    thumbnail_failed[selected]<=0;
                    if(FRAME_CACHE_ENABLE!=0 && cache_valid[selected]) begin
                        write_req<=0;
                        disp_buf_idx<=cache_bank[selected];picture_id<=selected;
                        scaled_image<=cache_scaled[selected];commit_toggle<=!commit_toggle;state<=COMMIT;
                        commit_auto<=navigation_auto;
                        source_resolution<=cached_resolution;
                    end else if(FRAME_CACHE_ENABLE!=0 && free_banks==0) begin
                        write_req<=0;error_code<=8'h43;state<=HALT;
                    end
                end
                REQUEST: if(wrack_sync[1]) begin write_req<=0; state<=RELEASE; end
                RELEASE: if(!wrack_sync[1]) state<=START_FILE;
                // 正常图片和后台缩略图共用启动边界，先锁存参数，再等待旧事务退出。
                START_FILE: if(!file_busy && !file_done && !bmp_done) begin
                    file_start<=1;state<=LOAD;
                end
                LOAD: if(bmp_done) begin
                    if(bmp_error!=0 || file_error!=0 || !frame_commit || (full_frame_write && write_overflow)) begin
                        error_code<=(full_frame_write && write_overflow) ? 8'h40 : (file_error!=0 ? file_error : bmp_error);
                        if((!full_frame_write || !write_overflow) && file_error>=8'h23 && file_error<=8'h26) begin
                            debug_status<=file_debug;debug_toggle<=!debug_toggle;
                        end else if((!full_frame_write || !write_overflow) && file_error==0 && bmp_error==8'h37) begin
                            // 保留首次失败的 BMP 诊断，后续音频/扇区读取不得覆盖。
                            debug_status<={bmp_debug[59:28],bmp_debug[26:18],bmp_debug[17:2],selected[2:0]};debug_toggle<=!debug_toggle;
                        end
                        state<=IDLE;
                        if(!thumbnail_valid[selected]) thumbnail_failed[selected]<=1;
                    end else begin decoded<=1; state<=DRAIN; end
                end
                DRAIN: if(decoded && (!full_frame_write || written)) begin
                    thumbnail_valid[selected]<=1;
                    thumbnail_failed[selected]<=0;
                    if(FRAME_CACHE_ENABLE!=0) begin
                        cache_valid[selected]<=1;cache_bank[selected]<=write_buf_idx;
                        cache_scaled[selected]<=source_2x;
                    end
                    if(background) begin
                        background<=0;state<=IDLE;
                        if(thumbnail_failed==0) error_code<=0;
                    end
                    else begin
                        disp_buf_idx<=write_buf_idx; picture_id<=selected;
                        scaled_image<=source_2x;
                        source_resolution<=decoded_resolution;
                        commit_toggle<=!commit_toggle; state<=COMMIT;
                        commit_auto<=navigation_auto;
                    end
                end
                COMMIT: if(ack_sync[1]==commit_toggle) begin first_frame<=0;state<=IDLE;no_signal<=0;end
                IDLE: begin
                    background<=0;
                    if(HOTPLUG_ENABLE!=0 && cache_valid==0 &&
                       (attempted & available_images)==available_images && thumbnail_failed!=0) begin
                        no_signal<=1;state<=FAILED;
                    end else if(paused || ack_sync[1]!=commit_toggle) begin end
                    else if(pending_select) begin
                        pending_select<=0;
                        if(requested_index<4'd9 && available_images[requested_index]) begin
                            selected<=requested_index;state<=PICK;navigation_auto<=0;
                        end
                    end else if(pending_next) begin
                        selected<=next_index; state<=PICK;navigation_auto<=pending_auto;
                    end else if(first_frame && |(available_images & ~attempted)) begin
                        // Find a usable first frame even when autoplay is disabled.
                        selected<=first_present(available_images & ~attempted);state<=PICK;navigation_auto<=0;
                    end else if((browse_sync[1] || FRAME_CACHE_ENABLE!=0) && |(available_images & ~attempted)) begin
                        selected<=first_present(available_images & ~attempted);
                        background<=1;state<=PICK;
                    end
                end
                FAILED,HALT: begin
                    write_req<=0;auto_play<=0;
                    if((pending_next && !paused) || rescan_due) begin
                        // Run is also the recovery command. Preserve committed bank/ACK
                        // and first_frame so a retry never overwrites the visible frame.
                        state<=POWER_WAIT;settle_count<=0;boot_retries<=0;watchdog<=0;
                        pending_next<=0;pending_select<=0;background<=0;
                        media_enabled<=0;written<=0;decoded<=0;
                        attempted<=0;thumbnail_valid<=0;thumbnail_failed<=0;
                        cache_valid<=0;cache_scaled<=0;
                        error_code<=0;auto_play<=RUN_MODE_CONTROL!=0 ? run_auto_sync[1] : 1'b1;
                        debug_status<=0;debug_toggle<=!debug_toggle;
                    end
                end
                default: state<=INIT;
            endcase
            // Already cached pictures remain selectable while another file is
            // preloading. Keep the writer/decoder transaction running and hold
            // display metadata until the normal frame-boundary acknowledgement.
            if(FRAME_CACHE_ENABLE!=0 && background && state==LOAD && !bmp_done &&
               !first_frame && !paused && ack_sync[1]==commit_toggle) begin
                if(pending_select && requested_index<4'd9 && cache_valid[requested_index]) begin
                    pending_select<=0;navigation_index<=requested_index;
                    disp_buf_idx<=cache_bank[requested_index];picture_id<=requested_index;
                    scaled_image<=cache_scaled[requested_index];commit_toggle<=!commit_toggle;
                    commit_auto<=0;
                    source_resolution<=cached_resolution;
                end else if(!pending_select && pending_next && cache_valid[next_index]) begin
                    pending_next<=0;navigation_index<=next_index;
                    disp_buf_idx<=cache_bank[next_index];
                    picture_id<=next_index;
                    scaled_image<=cache_scaled[next_index];commit_toggle<=!commit_toggle;
                    commit_auto<=pending_auto;
                    source_resolution<=cached_resolution;
                end
            end
            if(state!=HALT && state!=POWER_WAIT && ((state==INIT && watchdog>=INIT_TIMEOUT_CYCLES) ||
               ((state==REQUEST || state==RELEASE || state==START_FILE || state==LOAD || state==DRAIN) &&
                watchdog>=LOAD_TIMEOUT_CYCLES) || sector_error!=0)) begin
                state<=HALT; write_req<=0;pending_next<=0;pending_select<=0;
                if(state==LOAD && !thumbnail_valid[selected]) thumbnail_failed[selected]<=1;
                // Capture before HALT resets the service; its reset toggle is not new evidence.
                if(sector_error!=0) begin debug_status<=sector_debug;debug_toggle<=!debug_toggle;end
                error_code<=sector_error!=0 ? sector_error : (state==INIT ? 8'h11 : 8'h42);
            end
            // 音频/后台心跳错误也要触发恢复；不复位 HDMI、UI 或当前显示 bank。
            if(HOTPLUG_ENABLE!=0 && state!=POWER_WAIT && state!=HALT &&
               (backend_fault || (state==INIT && (raw_error!=0 || watchdog>=INIT_TIMEOUT_CYCLES)))) begin
                no_signal<=1;state<=HALT;write_req<=0;media_enabled<=0;
                pending_next<=0;pending_select<=0;
                error_code<=backend_fault ? backend_error : raw_error!=0 ? raw_error : 8'h11;
            end
        end
    end

    fat32_volume_scanner #(.AUDIO_SELECT_ENABLE(AUDIO_SELECT_ENABLE),.INDEXED_RESOURCES(1)) scanner(
        .clk(clk),.rst_n(!driver_reset),.scan_start(scan_start),.scan_busy(scan_busy),
        .scan_done(scan_done),.fs_error(scan_error),.partition_lba(partition_lba),
        .sectors_per_cluster(spc),.fat_start_lba(fat_lba),.data_start_lba(data_lba),
        .max_cluster(max_cluster),.resource_valid(available_images),
        .resource_index(selected),.resource_cluster(catalog_cluster),.resource_size(catalog_size),
        .sector_req(scan_req),.sector_lba(scan_lba),.sector_busy(sector_busy),
        .sector_valid(sector_valid && is_scan),.sector_byte(sector_byte),
        .sector_byte_index(byte_index),.sector_done(sector_done && is_scan),.sector_error(sector_error),
        .audio_found(audio_found),.audio_cluster(audio_cluster),.audio_size(audio_size),
        .audio_select(active_audio_select)
    );
    fat32_file_streamer #(.MAX_VISITED_CLUSTERS(GENERAL_SCALE!=0 ? 2097152 : 16384)) streamer(
        .clk(clk),.rst_n(!driver_reset),.file_start(file_start),.first_cluster(cluster),.file_size(size),
        .sectors_per_cluster(spc),.fat_start_lba(fat_lba),.data_start_lba(data_lba),
        .max_cluster(max_cluster),.file_busy(file_busy),.file_done(file_done),
        .file_valid(file_valid),.file_byte(file_byte),.file_byte_offset(file_offset),.fs_error(file_error),
        .sector_req(file_req),.sector_lba(file_lba),.sector_busy(sector_busy || (GENERAL_SCALE!=0 && !decoder_sector_room)),
        .sector_valid(sector_valid && !is_scan),.sector_byte(sector_byte),
        .sector_byte_index(byte_index),.sector_done(sector_done && !is_scan),.sector_error(sector_error),
        .error_detail(file_debug)
    );
    bmp24_decoder #(.EXPECTED_WIDTH(FRAME_WIDTH),.EXPECTED_HEIGHT(FRAME_HEIGHT),.MODE_576(MODE_576),
        .ALLOW_2X_SOURCE(1),.GENERAL_SCALE(GENERAL_SCALE)) decoder(
        .clk(clk),.rst_n(!driver_reset),.file_start(file_start),.file_size(size),
        .file_valid(file_valid),.file_byte(file_byte),.file_byte_offset(file_offset),
        .file_end(file_done),.upstream_error(file_error),.header_accepted(header_accepted),
        .pixel_valid(pixel_valid),.pixel_rgb(rgb),.pixel_x(thumbnail_x),.pixel_y(thumbnail_y),
        .frame_commit(frame_commit),.bmp_done(bmp_done),.bmp_error(bmp_error),
        .top_down(top_down),.pixel_offset(),.row_stride(),.source_scale_2x(source_2x),.error_detail(bmp_debug),
        .pixel_ready(!full_frame_write || write_ready),.sector_room(decoder_sector_room),
        .source_resolution(decoded_resolution)
    );
    sd_card_top sd_card_top_m0(
        .clk(clk),.rst(driver_reset),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),
        .sd_init_done(card_ready),.sd_sec_read(sector_read),.sd_sec_read_addr(sector_lba),
        .sd_sec_read_data(raw_byte),.sd_sec_read_data_valid(raw_valid),.sd_sec_read_end(sector_end),
        .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(),.sd_sec_write_end(),.read_slow(slow_read || is_scan),.sd_sec_read_error(raw_error)
    );
endmodule

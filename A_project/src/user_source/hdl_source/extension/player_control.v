`timescale 1ns/1ps
module player_key #(
    parameter integer CYCLES=500000
) (input clk,input rst,input button,output reg press,output down);
    reg [1:0] sync;
    reg stable;
    reg [(CYCLES>1 ? $clog2(CYCLES) : 1)-1:0] count;
    // Reuse the debounced state; stop repeats on a synchronized release.
    assign down=!stable && !sync[1];
    always @(posedge clk or posedge rst) begin
        if(rst) begin sync<=3; stable<=1; count<=0; press<=0; end
        else begin
            sync<={sync[0],button}; press<=0;
            if(sync[1]==stable) count<=0;
            else if(count==CYCLES-1) begin
                stable<=sync[1]; count<=0;
                if(!sync[1]) press<=1;
            end else count<=count+1'b1;
        end
    end
endmodule

// Use the existing ~60 Hz frame tick instead of wide pixel-clock timers.
// 48 frames starts a hold at ~0.8 s; 12 frames repeats at ~0.2 s.
module player_key_repeat #(
    parameter integer LONG_FRAMES=48,
    parameter integer REPEAT_FRAMES=12
)(input clk,input rst,input frame_tick,input enable,input down,input press,
  output reg repeat_press);
    localparam integer MAX_FRAMES=LONG_FRAMES>REPEAT_FRAMES ? LONG_FRAMES : REPEAT_FRAMES;
    localparam integer COUNT_BITS=MAX_FRAMES>1 ? $clog2(MAX_FRAMES) : 1;
    reg [COUNT_BITS-1:0] frames_left;
    always @(posedge clk or posedge rst) begin
        if(rst) begin frames_left<=LONG_FRAMES-1;repeat_press<=0;end
        else begin
            repeat_press<=0;
            if(!enable || !down || press) frames_left<=LONG_FRAMES-1;
            else if(frame_tick) begin
                if(frames_left==0) begin
                    frames_left<=REPEAT_FRAMES-1;repeat_press<=1;
                end else frames_left<=frames_left-1'b1;
            end
        end
    end
endmodule

// Bundled-data handshake: hold a complete diagnostic snapshot until acknowledged.
module player_status_cdc #(
    parameter integer WIDTH=14
)(
    input source_clk,input source_rst,input update,input [WIDTH-1:0] status,
    input target_clk,input target_rst,output reg [WIDTH-1:0] snapshot
);
    reg [WIDTH-1:0] held;
    reg [WIDTH-1:0] held_target;
    (* async_reg="true" *) reg request_target;
    reg request,acknowledge;
    (* async_reg="true" *) reg [1:0] ack_sync;
    (* async_reg="true" *) reg [2:0] request_sync;
    always @(posedge source_clk or posedge source_rst) begin
        if(source_rst) begin held<=0;request<=0;ack_sync<=0;end
        else begin
            ack_sync<={ack_sync[0],acknowledge};
            if(update && request==ack_sync[1]) begin held<=status;request<=!request;end
        end
    end
    // The source holds this bundle for the entire request/ACK exchange. Capture
    // it on the target's opposite edge, then publish only after the synchronized
    // request. This gives the related 25/50 MHz clocks half a target period of
    // separation, instead of a same-edge data path sensitive to clock skew.
    always @(negedge target_clk or posedge target_rst) begin
        if(target_rst) begin held_target<=0;request_target<=0;end
        else begin held_target<=held;request_target<=request;end
    end
    always @(posedge target_clk or posedge target_rst) begin
        if(target_rst) begin request_sync<=0;acknowledge<=0;snapshot<=0;end
        else begin
            request_sync<={request_sync[1:0],request_target};
            if(request_sync[2]!=acknowledge) begin
                snapshot<=held_target;acknowledge<=request_sync[2];
            end
        end
    end
endmodule

module player_gesture #(
    parameter integer CYCLES=500000,
    parameter integer LONG_CYCLES=20000000
)(input clk,input rst,input button,output reg tap,output reg hold);
    reg [1:0] sync;
    reg stable,long_sent;
    reg [(CYCLES>1 ? $clog2(CYCLES) : 1)-1:0] debounce;
    reg [(LONG_CYCLES>1 ? $clog2(LONG_CYCLES) : 1)-1:0] duration;
    always @(posedge clk or posedge rst) begin
        if(rst) begin sync<=3;stable<=1;long_sent<=0;debounce<=0;duration<=0;tap<=0;hold<=0;end
        else begin
            sync<={sync[0],button};tap<=0;hold<=0;
            if(sync[1]==stable) debounce<=0;
            else if(debounce==CYCLES-1) begin
                stable<=sync[1];debounce<=0;
                if(sync[1] && !long_sent) tap<=1;
                if(!sync[1]) begin duration<=0;long_sent<=0;end
            end else debounce<=debounce+1'b1;
            // A debounced release wins on the threshold clock: never emit both events.
            if(!stable && !long_sent && !(sync[1] && debounce==CYCLES-1)) begin
                if(duration==LONG_CYCLES-1) begin hold<=1;long_sent<=1;end
                else duration<=duration+1'b1;
            end
        end
    end
endmodule

// 板上 KEY2=key_next，KEY3=key_menu，KEY4=key_auto。
// 界面在帧边界提交；一次按键只进入一个分支，避免确认后又触发报警。
module player_control #(
    parameter integer SENSOR_ENABLE=0,
    parameter integer REMOTE_ENABLE=0,
    parameter integer NETWORK_ENABLE=0,
    parameter integer CURRENT_PICTURE_FOCUS_ENABLE=0,
    parameter integer DEBOUNCE_CYCLES=500000,
    parameter integer LONG_CYCLES=20000000,
    parameter integer KEY_LONG_FRAMES=48,
    parameter integer KEY_REPEAT_FRAMES=12
)(
    input clk,input rst,input frame_tick,
    input key_next,input key_auto,input key_menu,input [3:0] switches,
    output reg next_toggle,output reg auto_toggle,
    output reg signed [8:0] brightness,
    output reg [8:0] contrast,
    output reg [3:0] volume,output reg [3:0] interval_seconds,
    output reg [2:0] menu,output reg [3:0] modes,
    input [8:0] available,input [8:0] thumbnail_valid,
    output reg browse,output reg [3:0] focus,
    output reg select_toggle,output reg [3:0] select_index,
    output reg directory,output reg [1:0] directory_focus,
    output reg status_panel,output reg alarm,
    input auto_active,
    output reg directory_run,output reg [1:0] run_mode,
    input sensor_alarm,input sensor_alarm_clear,
    output reg [3:0] transition_mode,
    input playback_fault,
    input remote_valid,input [7:0] remote_command,input [23:0] remote_argument,
    output reg remote_done,output reg [2:0] remote_result,
    output reg [3:0] remote_switch_mask,output reg [3:0] remote_switch_value,
    output [3:0] physical_switches,
    input network_alarm,
    output reg [1:0] audio_select,
    input [3:0] current_picture,
    output reg sound_alarm // Frame-committed source; collision/network alarm has priority.
);
    wire next_press,auto_press,menu_press,menu_hold;
    wire local_next,local_auto,local_menu,local_hold;
    wire local_next_long,local_auto_long;
    wire local_next_down,local_auto_down;
    wire remote_request=REMOTE_ENABLE!=0 && remote_valid;
    wire remote_key=remote_request && remote_command==8'h10;
    wire remote_alarm_override=remote_request && remote_command==8'h14 && remote_argument[7:0]<=1;
    assign next_press=local_next || (remote_key && remote_argument[7:0]==0);
    assign menu_press=local_menu || (remote_key && remote_argument[7:0]==1);
    assign menu_hold=local_hold || (remote_key && remote_argument[7:0]==2);
    assign auto_press=local_auto || (remote_key && remote_argument[7:0]==3);
    reg [3:0] sw_meta,sw_sync;
    assign physical_switches=sw_sync;
    wire [3:0] effective_switches=(sw_sync & ~remote_switch_mask) | (remote_switch_value & remote_switch_mask);
    wire signed [15:0] remote_value=remote_argument[23:8];
    wire remote_high_zero=remote_argument[23:16]==0;
    wire remote_brightness_ok=remote_high_zero ||
        (remote_argument[23:16]==8'hff && remote_argument[15:8]!=0);
    wire remote_contrast_ok=remote_high_zero ||
        (remote_argument[23:16]==1 && remote_argument[15:8]<=128);
    reg signed [8:0] bright_edit;
    reg [8:0] contrast_edit;
    reg [3:0] volume_edit,interval_edit;
    reg [1:0] audio_edit;
    player_key #(.CYCLES(DEBOUNCE_CYCLES)) a(clk,rst,key_next,local_next,local_next_down);
    player_key #(.CYCLES(DEBOUNCE_CYCLES)) b(clk,rst,key_auto,local_auto,local_auto_down);
    reg view_edit,confirm_pending;
    reg [3:0] focus_edit;
    reg [2:0] menu_edit;
    // 0淡入淡出，1原四特效轮换，2滑动，3横擦，4对开帘，5百叶窗，6方块，7旋转，8散点。
    reg [3:0] transition_edit;
    reg directory_edit,status_edit,alarm_edit;
    wire network_active=NETWORK_ENABLE!=0 && network_alarm;
    wire any_alarm_edit=alarm_edit || network_active;
    reg alarm_from_sensor;
    reg [1:0] directory_selection;
    // Only MAN=1 and AUTO=2 remain. The preview is a view, not a playback mode.
    // modes[3] is the settings-active flag; SW4 is reserved. The synchronized
    // physical SW2 separately gates image transitions, never visual overlays.
    reg [1:0] run_mode_edit;
    player_gesture #(.CYCLES(DEBOUNCE_CYCLES),.LONG_CYCLES(LONG_CYCLES))
        c(clk,rst,key_menu,local_menu,local_hold);
    // Repeat events only edit brightness/contrast in the settings view.
    wire repeat_enable=status_edit && !directory_edit && !any_alarm_edit &&
        !(SENSOR_ENABLE!=0 && sensor_alarm) && menu_edit<2 && !menu_press && !menu_hold;
    player_key_repeat #(.LONG_FRAMES(KEY_LONG_FRAMES),.REPEAT_FRAMES(KEY_REPEAT_FRAMES))
        next_repeat(clk,rst,frame_tick,repeat_enable,local_next_down,local_next,local_next_long);
    player_key_repeat #(.LONG_FRAMES(KEY_LONG_FRAMES),.REPEAT_FRAMES(KEY_REPEAT_FRAMES))
        auto_repeat(clk,rst,frame_tick,repeat_enable,local_auto_down,local_auto,local_auto_long);
    // Fixed nine-entry priority encoders avoid a modulo divider or a chain of
    // dynamic additions. Skip absent slots, wrapping only at the list end.
    function [3:0] step_focus;
        input [3:0] current;
        input backwards;
        integer i;
        reg [3:0] preferred,wrapped;
        reg found;
        begin
            preferred=current;wrapped=current;found=0;
            if(backwards) begin
                for(i=0;i<9;i=i+1) if(available[i] && i!=current) begin
                    wrapped=i;
                    if(i<current) begin preferred=i;found=1;end
                end
            end else begin
                for(i=8;i>=0;i=i-1) if(available[i] && i!=current) begin
                    wrapped=i;
                    if(i>current) begin preferred=i;found=1;end
                end
            end
            step_focus=found ? preferred : wrapped;
        end
    endfunction
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            next_toggle<=0; auto_toggle<=0; brightness<=0; bright_edit<=0;
            contrast<=128; contrast_edit<=128; volume<=4; volume_edit<=4;
            audio_select<=0;audio_edit<=0;
            interval_seconds<=3; interval_edit<=3; menu<=0; menu_edit<=0; sw_meta<=0; sw_sync<=0; modes<=0;
            transition_mode<=0;transition_edit<=0;
            browse<=0;focus<=0;view_edit<=0;focus_edit<=0;
            select_toggle<=0;select_index<=0;confirm_pending<=0;
            directory<=0;directory_edit<=0;directory_focus<=0;directory_selection<=0;
            status_panel<=0;status_edit<=0;alarm<=0;alarm_edit<=0;
            alarm_from_sensor<=0;sound_alarm<=0;
            directory_run<=0;run_mode<=2;run_mode_edit<=2;
            remote_done<=0;remote_result<=0;remote_switch_mask<=0;remote_switch_value<=0;
        end else begin
            sw_meta<=switches; sw_sync<=sw_meta;
            remote_done<=remote_request;remote_result<=0;
            if(remote_key && remote_argument[7:0]>3) remote_result<=3;
            if(remote_request && !remote_key) begin
                case(remote_command)
                    8'h11: case(remote_argument[7:0])
                        0: if(remote_brightness_ok) bright_edit<=remote_value[8:0];else remote_result<=3;
                        1: if(remote_contrast_ok) contrast_edit<=remote_value[8:0];else remote_result<=3;
                        2: if(remote_high_zero && remote_argument[15:8]<=8) volume_edit<=remote_value[3:0];else remote_result<=3;
                        3: if(remote_high_zero && remote_argument[15:8]>=1 && remote_argument[15:8]<=9) interval_edit<=remote_value[3:0];else remote_result<=3;
                        4: if(remote_high_zero && remote_argument[15:8]<=8) transition_edit<=remote_value[3:0];else remote_result<=3;
                        5: if(remote_high_zero && (remote_argument[15:8]==1 || remote_argument[15:8]==2)) run_mode_edit<=remote_value[1:0];else remote_result<=3;
                        default: remote_result<=3;
                    endcase
                    8'h12: if(remote_argument[7:0]>3) remote_result<=3;
                        else if(any_alarm_edit) remote_result<=4;
                        else begin
                            directory_edit<=remote_argument[7:0]==1;
                            view_edit<=remote_argument[7:0]==2;
                            status_edit<=remote_argument[7:0]==3;
                            if(remote_argument[7:0]==2) begin
                                if(CURRENT_PICTURE_FOCUS_ENABLE!=0 && current_picture<9 && available[current_picture])
                                    focus_edit<=current_picture;
                                else if(!available[focus_edit]) focus_edit<=step_focus(focus_edit,0);
                            end
                            if(remote_argument[7:0]==0 && playback_fault) next_toggle<=!next_toggle;
                        end
                    8'h13: if(remote_argument[7:0]>8) remote_result<=3;
                        else if(any_alarm_edit || confirm_pending) remote_result<=4;
                        else if(!available[remote_argument[3:0]] || !thumbnail_valid[remote_argument[3:0]]) remote_result<=5;
                        else begin
                            focus_edit<=remote_argument[3:0];confirm_pending<=1;
                            view_edit<=0;directory_edit<=0;status_edit<=0;
                        end
                    8'h14: if(remote_argument[7:0]>1) remote_result<=3;
                        else begin alarm_edit<=remote_argument[0];alarm_from_sensor<=0;end
                    8'h15: if((remote_argument[7:0] & 8'hfa)!=0 || (remote_argument[15:8] & 8'hfa)!=0) remote_result<=3;
                        else begin remote_switch_mask<=remote_argument[3:0];remote_switch_value<=remote_argument[11:8];end
                    8'h16: if(any_alarm_edit) remote_result<=4;
                        else begin next_toggle<=!next_toggle;view_edit<=0;directory_edit<=0;status_edit<=0;end
                    default: remote_result<=1;
                endcase
            end else if(any_alarm_edit) begin
                // KEY4 and quiet-exit clear only the local source. The network
                // source releases independently after B's healthy clear window.
                if(auto_press || (SENSOR_ENABLE!=0 && alarm_from_sensor && sensor_alarm_clear)) begin
                    alarm_edit<=0;alarm_from_sensor<=0;
                end
            end else if(SENSOR_ENABLE!=0 && sensor_alarm) begin
                // 仅置位现有报警状态；返回后原目录、预览、播放参数均保留。
                alarm_edit<=1;alarm_from_sensor<=1;
            end else if(directory_edit) begin
                if(next_press) directory_edit<=0;
                else if(menu_press) directory_selection<=directory_selection==2 ? 0 : directory_selection+1'b1;
                else if(auto_press) begin
                    directory_edit<=0;
                    case(directory_selection)
                        0: begin
                            view_edit<=1;
                            status_edit<=0;
                            if(CURRENT_PICTURE_FOCUS_ENABLE!=0 && current_picture<9 && available[current_picture])
                                focus_edit<=current_picture;
                            else if(!available[focus_edit]) focus_edit<=step_focus(focus_edit,0);
                        end
                        1: begin
                            // Resume the selected mode without changing it or
                            // advancing a healthy picture. Retain fault retry.
                            view_edit<=0;status_edit<=0;
                            if(playback_fault) next_toggle<=!next_toggle;
                        end
                        2: begin status_edit<=1;view_edit<=0;end
                    endcase
                end
            end else if(view_edit && !status_edit) begin
                if(next_press) directory_edit<=1;
                else if(auto_press) begin alarm_edit<=1;alarm_from_sensor<=0;end
                else if(menu_press) focus_edit<=step_focus(focus_edit,0);
                else if(menu_hold && thumbnail_valid[focus_edit]) begin
                    confirm_pending<=1;view_edit<=0;
                end
            end else if(!status_edit) begin
                if(next_press) directory_edit<=1;
                else if(auto_press) begin alarm_edit<=1;alarm_from_sensor<=0;end
                else if(menu_hold) status_edit<=1;
                else if(menu_press && run_mode_edit==1) next_toggle<=!next_toggle;
            end else begin
                // Settings are entered from the menu or a KEY3 hold, never SW4.
                // KEY3 hold returns to the directory; KEY2/KEY4 edit the field.
                if(menu_hold) begin status_edit<=0;directory_edit<=1;end
                if(menu_press) menu_edit<=menu_edit==6 ? 3'd0 : menu_edit+1'b1;
                case(menu_edit)
                    0: begin
                        // 中间步长 4，末步饱和到 +/-255；禁止有符号回绕。
                        if(next_press || local_next_long) bright_edit<=bright_edit>9'sd251 ? 9'sd255 : bright_edit+9'sd4;
                        if(auto_press || local_auto_long) bright_edit<=bright_edit< -9'sd251 ? -9'sd255 : bright_edit-9'sd4;
                    end
                    1: begin
                        // 128 为原始对比度；范围 0..384 对应 0..3 倍。
                        if((next_press || local_next_long) && contrast_edit<9'd384) contrast_edit<=contrast_edit>9'd380 ? 9'd384 : contrast_edit+9'd4;
                        if((auto_press || local_auto_long) && contrast_edit>9'd0) contrast_edit<=contrast_edit<9'd4 ? 9'd0 : contrast_edit-9'd4;
                    end
                    2: begin
                        if(next_press && volume_edit<8) volume_edit<=volume_edit+1'b1;
                        if(auto_press && volume_edit>0) volume_edit<=volume_edit-1'b1;
                    end
                    3: begin
                        if(next_press && interval_edit<9) interval_edit<=interval_edit+1'b1;
                        if(auto_press && interval_edit>1) interval_edit<=interval_edit-1'b1;
                    end
                    4: begin
                        if(next_press) transition_edit<=transition_edit==8 ? 4'd0 : transition_edit+1'b1;
                        else if(auto_press) transition_edit<=transition_edit==0 ? 4'd8 : transition_edit-1'b1;
                    end
                    5: if(next_press || auto_press) run_mode_edit<=run_mode_edit==2 ? 2'd1 : 2'd2;
                    // Two-bit wrap implements four choices without a divider.
                    6: begin
                        if(next_press) audio_edit<=audio_edit+2'd1;
                        else if(auto_press) audio_edit<=audio_edit-2'd1;
                    end
                endcase
            end
            // A sensor event must not be lost to an unrelated remote setting.
            if(SENSOR_ENABLE!=0 && sensor_alarm && !alarm_edit &&
               !remote_alarm_override) begin
                alarm_edit<=1;alarm_from_sensor<=1;
            end
            // Quiet-exit is a pulse; retain it even if a SET arrives that cycle.
            if(SENSOR_ENABLE!=0 && alarm_edit && alarm_from_sensor && sensor_alarm_clear && !remote_alarm_override) begin
                alarm_edit<=0;alarm_from_sensor<=0;
            end
            if(frame_tick) begin
                brightness<=bright_edit; contrast<=contrast_edit; volume<=volume_edit;
                audio_select<=audio_edit;
                interval_seconds<=interval_edit; modes<={status_edit,effective_switches[2],1'b0,effective_switches[0]}; menu<=menu_edit;
                transition_mode<=transition_edit;
                browse<=view_edit;focus<=focus_edit;
                directory<=directory_edit;
                directory_run<=0;
                directory_focus<=directory_selection;
                if(run_mode!=run_mode_edit) auto_toggle<=!auto_toggle;
                run_mode<=run_mode_edit;
                status_panel<=status_edit;alarm<=any_alarm_edit;
                sound_alarm<=alarm_edit && alarm_from_sensor && !network_active;
                if(confirm_pending) begin
                    select_index<=focus_edit;select_toggle<=!select_toggle;confirm_pending<=0;
                end
            end
        end
    end
endmodule

// 宽高复用一套移位加三电路，共 32 拍，不使用除法器或 DSP。
module player_resolution_bcd(input clk,input rst,input [31:0] dimensions,input request,
    output reg [39:0] digits,output reg ready,output reg completed_request);
    reg [31:0] shift;
    reg [19:0] work_digits;
    reg [4:0] count;
    reg busy,last_request;
    reg [19:0] adjusted_digits;
    integer n;
    always @* begin
        adjusted_digits=work_digits;
        for(n=0;n<5;n=n+1) begin
            if(work_digits[n*4 +: 4]>=5) adjusted_digits[n*4 +: 4]=work_digits[n*4 +: 4]+4'd3;
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin shift<=0;work_digits<=0;count<=0;busy<=0;ready<=0;digits<=0;last_request<=0;completed_request<=0;end
        else if(request!=last_request) begin
            last_request<=request;shift<=dimensions;work_digits<=0;count<=0;busy<=1;ready<=0;
        end else if(busy) begin
            shift<={shift[30:0],1'b0};
            work_digits<={adjusted_digits[18:0],shift[31]};count<=count+1'b1;
            if(count==15) begin digits[39:20]<={adjusted_digits[18:0],shift[31]};work_digits<=0;end
            if(count==31) begin
                digits[19:0]<={adjusted_digits[18:0],shift[31]};busy<=0;ready<=1;completed_request<=last_request;
            end
        end
    end
endmodule

// 一次只处理一个提交；淡出在黑帧换库，滑动在旧图完全推出后释放旧库。
module player_transition #(parameter integer SLIDE_ENABLE=0,parameter integer MULTI_EFFECT_ENABLE=0,
    parameter integer DIRECTORY_HOLD_ENABLE=0,parameter integer THUMBNAIL_SELECT_ENABLE=0,
    parameter integer BEAT_SYNC_ENABLE=0,parameter integer BEAT_WAIT_FRAMES=30,
    parameter integer FRAME_WIDTH=640,FRAME_HEIGHT=480)(
    input clk,input rst,input frame_tick,
    input request_toggle,input [3:0] pending_bank,input [3:0] pending_picture,
    input pending_scaled,
    output reg ack_toggle,output reg [3:0] active_bank,
    output reg [3:0] active_picture,output reg active_scaled,
    output reg display_valid,output reg [8:0] gain,
    input [31:0] pending_resolution,output reg [39:0] active_resolution,
    input [3:0] transition_mode,input effect_pause,input effects_disabled,
    output reg slide_active,output reg [19:0] slide_offset,output reg [3:0] slide_bank,
    output reg mask_active,output reg [2:0] mask_style,output reg [5:0] mask_level,
    input directory_hold,input thumbnail_select,
    input request_auto,input music_active,input music_beat
);
    reg [2:0] req_sync;
    reg [3:0] bank_meta,bank_sync,pic_meta,pic_sync;
    reg scale_meta,scale_sync;
    // 与 bank/PIC 共用请求-应答：源端保持到 ACK，帧边界才发布。
    reg [31:0] resolution_meta,resolution_sync;
    wire [39:0] resolution_digits;
    wire resolution_ready,resolution_request;
    player_resolution_bcd dimensions(.clk(clk),.rst(rst),.dimensions(resolution_sync),
        .request(req_sync[2]),.digits(resolution_digits),.ready(resolution_ready),.completed_request(resolution_request));
    reg [3:0] state;
    reg [1:0] next_effect;
    // Only read the selected mode and SW2 when accepting a new image. The
    // state/style registers hold the transaction even if either input changes.
    wire animate_image=display_valid && !effects_disabled;
    wire cycle_mode=transition_mode==1 && MULTI_EFFECT_ENABLE!=0;
    wire use_slide=SLIDE_ENABLE!=0 &&
        (transition_mode==2 || (cycle_mode && next_effect==0));
    wire use_mask=MULTI_EFFECT_ENABLE!=0 &&
        ((cycle_mode && next_effect!=0) || (transition_mode>=3 && transition_mode<=8));
    wire [3:0] fixed_style=transition_mode-4'd2;
    localparam integer SLIDE_ROWS=FRAME_HEIGHT==576 ? 24 : 16;
    localparam integer SLIDE_STEPS=FRAME_HEIGHT==768 ? 30 : FRAME_HEIGHT/SLIDE_ROWS;
    reg [4:0] slide_step;
    // Request metadata is stable until ACK, including its automatic/manual origin.
    reg auto_meta,auto_sync;
    reg beat_seen;
    localparam integer WAIT_BITS=BEAT_WAIT_FRAMES>1 ? $clog2(BEAT_WAIT_FRAMES+1) : 1;
    reg [WAIT_BITS-1:0] beat_wait;
    wire request_ready=req_sync[2]!=ack_toggle && resolution_ready && resolution_request==req_sync[2];
    wire wait_for_beat=BEAT_SYNC_ENABLE!=0 && auto_sync && display_valid && music_active;
    wire beat_release=!wait_for_beat || beat_seen || music_beat || beat_wait>=BEAT_WAIT_FRAMES-1;
    always @(posedge clk or posedge rst) begin
        if(rst) begin auto_meta<=0;auto_sync<=0;beat_seen<=0;beat_wait<=0;end
        else begin
            auto_meta<=request_auto;auto_sync<=auto_meta;
            // Never reuse a beat heard before the carousel request, during a
            // menu/alarm pause, or during a previous transition.
            if(state!=0 || !request_ready || !wait_for_beat || effect_pause || thumbnail_select) begin
                beat_seen<=0;beat_wait<=0;
            end else begin
                if(music_beat) beat_seen<=1;
                if(frame_tick && !beat_release) beat_wait<=beat_wait+1'b1;
            end
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            req_sync<=0; bank_meta<=0; bank_sync<=0; pic_meta<=0; pic_sync<=0;
            scale_meta<=0; scale_sync<=0; state<=0; ack_toggle<=0; active_bank<=0;
            active_picture<=0; active_scaled<=0; display_valid<=0; gain<=0;
            resolution_meta<=0;resolution_sync<=0;active_resolution<=0;
            slide_active<=0;slide_offset<=0;slide_bank<=0;slide_step<=0;
            mask_active<=0;mask_style<=0;mask_level<=0;next_effect<=0;
        end else begin
            req_sync<={req_sync[1:0],request_toggle};
            bank_meta<=pending_bank; bank_sync<=bank_meta;
            pic_meta<=pending_picture; pic_sync<=pic_meta;
            scale_meta<=pending_scaled; scale_sync<=scale_meta;
            resolution_meta<=pending_resolution;resolution_sync<=resolution_meta;
            // Freeze every picture effect and bank commit while the directory
            // moves. Permit the first image to load when there is no background.
            if(frame_tick && !(DIRECTORY_HOLD_ENABLE!=0 && directory_hold && display_valid)) begin
            if(THUMBNAIL_SELECT_ENABLE!=0 && thumbnail_select) begin
                // The card covers bank publication. Finish any older request
                // too, so a queued selection cannot deadlock behind its ACK.
                gain<=256;slide_active<=0;slide_offset<=0;mask_active<=0;mask_level<=0;
                if(state==5) begin ack_toggle<=req_sync[2];state<=0;end
                else if(req_sync[2]!=ack_toggle && resolution_ready && resolution_request==req_sync[2]) begin
                    active_bank<=bank_sync;active_picture<=pic_sync;active_scaled<=scale_sync;
                    active_resolution<=resolution_digits;display_valid<=1;state<=5;
                end else state<=0;
            end else case(state)
                0: if(request_ready && beat_release &&
                    !(BEAT_SYNC_ENABLE!=0 && auto_sync && display_valid && effect_pause)) begin
                    if(animate_image && use_mask) begin
                        // 设置中的轮换档依次选择滑动、横擦、对开帘、百叶窗。
                        // 先闭合到全黑再换库，整帧稳定后ACK，不并发读取两张全图。
                        mask_active<=1;mask_style<=cycle_mode ? {1'b0,next_effect} : fixed_style[2:0];mask_level<=0;
                        if(cycle_mode) next_effect<=next_effect+1'b1;
                        state<=6;
                    end else if(animate_image && use_slide) begin
                        // 每次移动16行（10240像素）；存储端换算为7680字，仍按128字对齐。
                        slide_active<=1;slide_offset<=0;slide_step<=0;slide_bank<=bank_sync;state<=4;
                        if(cycle_mode) next_effect<=1;
                    end else if(animate_image) state<=1;
                    else begin
                        active_bank<=bank_sync; active_picture<=pic_sync; active_scaled<=scale_sync;
                        active_resolution<=resolution_digits;
                        // SW2=1 shares the first-image bank/metadata commit.
                        // Full gain and state 5 bypass every effect, retaining
                        // a full new frame before ACK and the carousel index.
                        display_valid<=1;gain<=effects_disabled ? 9'd256 : 9'd0;
                        state<=effects_disabled ? 4'd5 : 4'd2;
                    end
                end
                1: if(gain!=0) gain<=gain-16;
                   else begin
                       active_bank<=bank_sync; active_picture<=pic_sync; active_scaled<=scale_sync; state<=2;
                       active_resolution<=resolution_digits;
                   end
                2: begin ack_toggle<=req_sync[2]; state<=3; end
                3: if(gain<256) gain<=gain+16; else state<=0;
                4: if(!effect_pause) begin
                    if(slide_step==SLIDE_STEPS-1) begin
                        slide_active<=0;slide_offset<=0;slide_step<=0;
                        active_bank<=slide_bank;active_picture<=pic_sync;active_scaled<=scale_sync;
                        active_resolution<=resolution_digits;state<=5;
                    end else begin slide_step<=slide_step+1'b1;slide_offset<=FRAME_HEIGHT==768 ? (((slide_step+1)*128)/5)*FRAME_WIDTH : slide_offset+FRAME_WIDTH*SLIDE_ROWS;end
                end
                // 新库完整显示一帧以后才ACK，源端不能提前回收旧画面。
                5: begin ack_toggle<=req_sync[2];state<=0;end
                6: if(!effect_pause) begin
                    if(mask_level==32) state<=7;
                    else mask_level<=mask_level+6'd2;
                end
                7: if(!effect_pause) begin
                    active_bank<=bank_sync;active_picture<=pic_sync;active_scaled<=scale_sync;
                    active_resolution<=resolution_digits;state<=8;
                end
                8: if(!effect_pause) begin ack_toggle<=req_sync[2];state<=9;end
                9: if(!effect_pause) begin
                    if(mask_level==0) begin mask_active<=0;state<=0;end
                    else mask_level<=mask_level-6'd2;
                end
            endcase
            end
        end
    end
endmodule

// A display-only tap of the actual HDMI PCM. No multiplier, RAM or feedback
// into audio. 256-sample peak windows detect onsets, with a 170 ms refractory
// period at 48 kHz. A steady tone cannot retrigger on individual sine cycles.
module player_music_dynamics #(parameter integer PIPELINED_COLOR=0)(
    input clk,input rst,input frame_tick,input fixed_audio,
    input audio_valid,input signed [23:0] audio_sample,
    output reg beat,output reg [23:0] color
);
    wire [15:0] pcm=audio_sample[23:8];
    wire [15:0] magnitude=pcm[15] ? (~pcm+16'd1) : pcm;
    reg [7:0] samples;
    reg [15:0] window_peak,previous_peak,baseline,frame_peak;
    reg [5:0] cooldown;
    reg [6:0] envelope;
    reg publish_color,fixed_color;
    reg [6:0] target_color;
    wire [15:0] peak=audio_valid && magnitude>window_peak ? magnitude : window_peak;
    wire [15:0] peak_frame=audio_valid && magnitude>frame_peak ? magnitude : frame_peak;
    wire [20:0] average=({5'd0,baseline}<<4)-baseline+peak;
    wire [16:0] threshold={1'b0,baseline}+{3'd0,baseline[15:2]}+17'd512;
    wire [16:0] onset_floor={1'b0,previous_peak}+17'd512;
    wire [6:0] frame_target=peak_frame>=16384 ? 7'd64 : {1'b0,peak_frame[13:8]};
    wire [6:0] target=PIPELINED_COLOR!=0 ? target_color : frame_target;
    wire [7:0] fall={1'b0,envelope}-{1'b0,target};
    wire [6:0] next_envelope=target>envelope ? envelope+((target-envelope+7'd1)>>1) :
        envelope-((fall+8'd7)>>3);
    // One yellow hue for the frame, waveform and FFT; only brightness varies.
    wire [7:0] tint_r=8'd191+{1'b0,next_envelope};
    wire [7:0] tint_g=tint_r;
    wire [7:0] tint_b=8'd0;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            samples<=0;window_peak<=0;previous_peak<=0;baseline<=0;cooldown<=0;
            frame_peak<=0;envelope<=0;beat<=0;color<=24'hffff00;
            publish_color<=0;fixed_color<=0;target_color<=0;
        end else begin
            beat<=0;
            publish_color<=frame_tick;
            if(frame_tick) begin target_color<=frame_target;fixed_color<=fixed_audio;end
            if(fixed_audio) begin
                samples<=0;window_peak<=0;previous_peak<=0;baseline<=0;cooldown<=0;
            end else if(audio_valid) begin
                samples<=samples+1'b1;
                if(samples==255) begin
                    window_peak<=0;previous_peak<=peak;baseline<=average[19:4];
                    if(cooldown!=0) cooldown<=cooldown-1'b1;
                    if(cooldown==0 && peak>=1024 && {1'b0,peak}>threshold && {1'b0,peak}>onset_floor) begin
                        beat<=1;cooldown<=32;
                    end
                end else window_peak<=peak;
            end
            // Publish one shared tint at vertical blanking: no brightness
            // discontinuity halfway down a frame. Silence gently returns dim.
            if(frame_tick) begin
                frame_peak<=0;
                if(PIPELINED_COLOR==0) begin
                    envelope<=fixed_audio ? 7'd32 : next_envelope;
                    color<=fixed_audio ? 24'hffff00 : {tint_r,tint_g,tint_b};
                end
            end else frame_peak<=peak_frame;
            // Same frame peak and smoothing, published one blanking clock
            // later. Neither the beat detector nor HDMI PCM is delayed.
            if(PIPELINED_COLOR!=0 && publish_color) begin
                envelope<=fixed_color ? 7'd32 : next_envelope;
                color<=fixed_color ? 24'hffff00 : {tint_r,tint_g,tint_b};
            end
        end
    end
endmodule

// SW1 reversibly eases from 544x408 at (48,32) to 640x480 at (0,0).
// The permanent header overlays the image. Geometry changes only in blanking.
module player_picture_zoom #(parameter integer MODE_576=0,NATIVE_RECT_ENABLE=0)(
    input clk,input rst,input frame_tick,input fullscreen,input pause,
    output reg [4:0] phase,output moving,
    output reg [7:0] size,output [9:0] left,output reg [9:0] top,
    output [9:0] width,output [9:0] height,output [43:0] native_rect
);
    assign moving=fullscreen ? phase!=16 : phase!=0;
    generate if(NATIVE_RECT_ENABLE) begin: registered_geometry
    reg [43:0] rectangle;
    assign native_rect=rectangle;
    wire [4:0] next_phase=frame_tick && !pause ?
        (fullscreen && phase<16 ? phase+1'b1 : !fullscreen && phase!=0 ? phase-1'b1 : phase) : phase;
    wire [43:0] next_native_rect;
    player_xga_geometry native_geometry(.expand_phase(5'd0),.target(4'd0),
        .picture_phase(next_phase),.expand_rect(),.picture_rect(next_native_rect));
    // Commit the native rectangle with the legacy phase, not one cycle later.
    always @(posedge clk or posedge rst) begin
        if(rst) rectangle<={11'd77,11'd52,11'd868,11'd652};
        else rectangle<=next_native_rect;
    end
    end else begin assign native_rect=44'd0;end endgenerate
    reg [6:0] native_progress;
    assign width=MODE_576 ? 10'd640+native_progress : {size,2'b00};
    assign height=MODE_576 ? 10'd480+((native_progress*6)/5) : {size,1'b0}+size;
    assign left=MODE_576 ? (10'd720-width)>>1 : 10'd320-{1'b0,size,1'b0};
    always @* begin
        native_progress=0;
        // Rounded smoothstep 3*t*t-2*t*t*t, t=phase/16. A small lookup
        // moves both dimensions and the vertical origin without a divider.
        case(phase)
            0,1:begin size=136;top=32;end
            2:begin size=137;top=31;end
            3:begin size=138;top=29;end
            4:begin size=140;top=27;end
            5:begin size=142;top=25;end
            6:begin size=144;top=22;end
            7:begin size=146;top=19;end
            8:begin size=148;top=16;end
            9:begin size=150;top=13;end
            10:begin size=152;top=10;end
            11:begin size=154;top=7;end
            12:begin size=156;top=5;end
            13:begin size=158;top=3;end
            14:begin size=159;top=1;end
            default:begin size=160;top=0;end
        endcase
        if(MODE_576) begin
            case(phase)
                0,1:native_progress=0;2:native_progress=4;3:native_progress=8;
                4:native_progress=12;5:native_progress=20;6:native_progress=24;
                7:native_progress=32;8:native_progress=40;9:native_progress=48;
                10:native_progress=56;11:native_progress=60;12:native_progress=68;
                13:native_progress=72;14:native_progress=76;default:native_progress=80;
            endcase
            // 640x480 at (40,32), ending at the native 720x576 raster.
            // Destination dimensions remain even for the packed RGB565 FIFO.
            top=(32*(80-native_progress))/80;
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) phase<=0;
        else if(frame_tick && !pause) begin
            if(fullscreen && phase<16) phase<=phase+1'b1;
            else if(!fullscreen && phase!=0) phase<=phase-1'b1;
        end
    end
endmodule

module player_reset #(parameter integer FALLING_RELEASE=0)(input clk,input async_reset,output reset);
    (* async_reg="true" *) reg [2:0] stages=3'b111;
    always @(posedge clk or posedge async_reset) begin
        if(async_reset) stages<=3'b111;
        else stages<={stages[1:0],1'b0};
    end
    generate if(FALLING_RELEASE!=0) begin: falling_release
        // Keep asynchronous assertion and three rising-edge synchronizer
        // stages. Release video reset halfway between the consumer edges so
        // the HDMI reset fanout has real recovery/removal margin.
        reg stage=1'b1;
        always @(negedge clk or posedge async_reset)
            if(async_reset) stage<=1'b1;
            else stage<=stages[2];
        assign reset=stage;
    end else begin: rising_release
        assign reset=stages[2];
    end endgenerate
endmodule

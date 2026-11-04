`timescale 1ns/1ps
// Nine immutable-after-commit previews. XGA uses seven BRAM32K blocks
// containing pairs of RGB332 pixels; legacy modes retain RGB565 storage.
module thumbnail_video #(parameter integer MODE_576=0,MODE_XGA=0)(
    input write_clk,input write_enable,input [3:0] write_slot,
    input [15:0] pixel_x,input [15:0] pixel_y,input [23:0] pixel_rgb,
    input clk,input rst,input hs,input vs,input de,input [23:0] rgb,
    input browse,input [3:0] focus,input [8:0] ready,input [8:0] available,
    output reg out_hs,output reg out_vs,output reg out_de,output reg [23:0] out_rgb,
    input [8:0] failed
);
    reg [5:0] native_write_x=0;
    reg [9:0] native_next_x=0;
    wire native_sample=pixel_x==0 || pixel_x==native_next_x;
    // 720 -> 64 columns: intervals 12,11,11,11; 576 ->48 rows:12.
    // Counters are restarted by the first pixel of every decoded row.
    always @(posedge write_clk) if(write_enable) begin
        if(pixel_x==0) begin native_write_x<=1;native_next_x<=12;end
        else if(native_sample) begin
            native_write_x<=native_write_x+1'b1;
            native_next_x<=native_next_x+(native_write_x[1:0]==0 ? 12 : 11);
        end
    end
    wire [5:0] write_x=MODE_XGA ? pixel_x[9:4] : MODE_576 ? (pixel_x==0 ? 6'd0 : native_write_x) : pixel_x[9:0]/10;
    wire [5:0] write_y=MODE_XGA ? pixel_y[9:4] : MODE_576 ? pixel_y[9:0]/12 : pixel_y[8:0]/10;
    wire [14:0] write_address={write_slot,11'd0}+{1'b0,write_slot,10'd0}+
                             {write_y,6'd0}+write_x;
    wire sample_write=write_enable && write_slot<9 && (MODE_XGA ?
        pixel_x<1024 && pixel_y<768 && pixel_x[3:0]==0 && pixel_y[3:0]==0 : MODE_576 ?
        pixel_x<720 && pixel_y<576 && native_sample && pixel_y[9:0]%12==0 :
        pixel_x<640 && pixel_y<480 && pixel_x[9:0]%10==0 && pixel_y[8:0]%10==0);
    reg last_de,last_vs;
    reg [9:0] raster_x,raster_y;
    wire [9:0] logical_x,logical_y;
    generate if(MODE_XGA) begin: registered_coordinates
        player_xga_logical_coordinates coordinates(.clk(clk),.rst(rst),.de(de),
            .frame_tick(last_vs && !vs),.row_tick(last_de && !de),
            .native_x_phase(raster_x[2:0]),.native_y_phase(raster_y[2:0]),.x(logical_x),.y(logical_y));
    end else begin assign logical_x=0;assign logical_y=0;end endgenerate
    wire [9:0] x=MODE_XGA ? logical_x : raster_x-(MODE_576 ? 40 : 0);
    wire [9:0] y=MODE_XGA ? logical_y : raster_y-(MODE_576 ? 48 : 0);
    wire content_pixel=MODE_576==0 ||
        (raster_x>=40 && raster_x<680 && raster_y>=48 && raster_y<528);
    wire [1:0] column=x>=424 ? 2'd2 : x>=240 ? 2'd1 : 2'd0;
    wire [1:0] row=y>=336 ? 2'd2 : y>=192 ? 2'd1 : 2'd0;
    wire [9:0] local_x=x-(column==2 ? 10'd424 : column==1 ? 10'd240 : 10'd56);
    wire [9:0] local_y=y-(row==2 ? 9'd336 : row==1 ? 9'd192 : 9'd48);
    wire [3:0] slot=(row==2 ? 4'd6 : row==1 ? 4'd3 : 4'd0)+{2'b0,column};
    wire in_preview=content_pixel && local_x<160 && local_y<120;
    wire border=local_x<3 || local_x>=157 || local_y<3 || local_y>=117;
    wire [8:0] scaled_x={local_x[7:0],1'b0};
    wire [7:0] scaled_y={local_y[6:0],1'b0};
    wire [5:0] rx=scaled_x/9'd5;
    wire [5:0] ry=scaled_y/8'd5;
    wire [15:0] pixel;
    wire [23:0] preview_rgb;
    reg [23:0] base;
    reg view_q,inside_q,border_q,focus_q,ready_q,present_q,failed_q,mark_q;
    wire [14:0] read_address={slot,11'd0}+{1'b0,slot,10'd0}+{ry,6'd0}+rx;
    generate if(MODE_XGA) begin: compact_preview
        reg [7:0] first_pixel;
        reg byte_select;
        wire [7:0] quantized={pixel_rgb[23:21],pixel_rgb[15:13],pixel_rgb[7:6]};
        wire [15:0] packed_pixel;
        wire [7:0] color=byte_select ? packed_pixel[7:0] : packed_pixel[15:8];
        assign pixel=0;
        assign preview_rgb={color[7:5],color[7:5],color[7:6],color[4:2],color[4:2],color[4:3],{4{color[1:0]}}};
        always @(posedge write_clk) if(sample_write && !write_x[0]) first_pixel<=quantized;
        always @(posedge clk) byte_select<=rx[0];
        bram32k_sdp #(.DEPTH(13824),.ADDR_BITS(14)) preview_memory(
            .write_clk(write_clk),.write_enable(sample_write && write_x[0]),
            .write_address(write_address[14:1]),.write_data({first_pixel,quantized}),
            .read_clk(clk),.read_enable(in_preview),.read_address(read_address[14:1]),.read_data(packed_pixel));
    end else begin: legacy_preview
    assign preview_rgb={pixel[15:11],pixel[15:13],pixel[10:5],pixel[10:9],pixel[4:0],pixel[4:2]};
    bram32k_sdp #(.DEPTH(27648),.ADDR_BITS(15)) preview_memory(
        .write_clk(write_clk),.write_enable(sample_write),.write_address(write_address),
        .write_data({pixel_rgb[23:19],pixel_rgb[15:10],pixel_rgb[7:3]}),
        .read_clk(clk),.read_enable(in_preview),
        .read_address(read_address),.read_data(pixel)
    );
    end endgenerate
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            raster_x<=0;raster_y<=0;last_de<=0;last_vs<=1;out_hs<=1;out_vs<=1;out_de<=0;
            base<=0;view_q<=0;inside_q<=0;border_q<=0;focus_q<=0;ready_q<=0;present_q<=0;failed_q<=0;mark_q<=0;
        end else begin
            last_de<=de;last_vs<=vs;
            if(de) raster_x<=raster_x+1'b1;else raster_x<=0;
            if(last_vs && !vs) raster_y<=0;else if(last_de && !de) raster_y<=raster_y+1'b1;
            out_hs<=hs;out_vs<=vs;out_de<=de;base<=rgb;view_q<=browse;
            inside_q<=in_preview;border_q<=border;focus_q<=slot==focus;
            ready_q<=ready[slot];present_q<=available[slot];
            failed_q<=failed[slot];
            // Central exclamation mark makes failure visible without relying on colour.
            mark_q<=local_x>=76 && local_x<84 &&
                    ((local_y>=40 && local_y<64) || (local_y>=72 && local_y<80));
        end
    end
    always @* begin
        out_rgb=base;
        if(view_q) begin
            out_rgb=24'h182024;
            if(inside_q) begin
                if(ready_q) out_rgb=preview_rgb;
                else if(failed_q) out_rgb=mark_q ? 24'hffffff : 24'ha02020;
                else out_rgb=present_q ? 24'h486068 : 24'h282c30;
                if(border_q) out_rgb=focus_q ? 24'hffd050 : 24'h849498;
            end
        end
        if(!out_de) out_rgb=0;
    end
endmodule

// A confirmation owns the image commit until the card has covered the screen.
// Storage still receives the selection immediately: holding its UI pause here
// would prevent that very request from reaching the display bank.
module thumbnail_expand #(parameter integer MODE_576=0,FRAME_HZ=60,NATIVE_RECT_ENABLE=0)(
    input clk,input rst,input frame_tick,input browse,
    input select_toggle,input [3:0] select_index,input [8:0] ready,
    input [3:0] active_picture,input [3:0] pending_picture,
    input display_valid,input request_toggle,input ack_toggle,
    input directory,input status_panel,input alarm,input effects_disabled,
    output reg active,output reg moving,output reg [3:0] target,
    output reg [4:0] phase,output reg [7:0] size,
    output [9:0] left,output [9:0] top,output [1:0] border_size,
    output [9:0] width,output [9:0] height,
    output [2:0] dim,output [43:0] native_rect
);
    reg seen_select,previous_browse;
    reg [6:0] wait_frames;
    reg [1:0] column,row;
    // Compute the incoming phase's rectangle before its commit edge. This
    // breaks the phase-to-FIFO-control path without delaying the animation.
    generate if(NATIVE_RECT_ENABLE) begin: registered_geometry
    reg [43:0] rectangle;
    assign native_rect=rectangle;
    reg [4:0] next_phase;
    reg [3:0] next_target;
    wire [43:0] next_native_rect;
    player_xga_geometry native_geometry(.expand_phase(next_phase),.target(next_target),
        .picture_phase(5'd0),.expand_rect(next_native_rect),.picture_rect());
    always @* begin
        next_phase=phase;next_target=target;
        if(select_toggle!=seen_select && (previous_browse || active)) begin
            next_phase=0;
            if(!effects_disabled && select_index<9 && ready[select_index]) next_target=select_index;
        end else if(frame_tick && active) begin
            if(directory || status_panel || browse || !ready[target] ||
               (moving && (active_picture!=target ||
                (request_toggle!=ack_toggle && pending_picture!=target)))) next_phase=0;
            else if(!alarm) begin
                if(!moving) begin
                    if(display_valid && active_picture==target && request_toggle==ack_toggle) next_phase=0;
                end else if(phase==19) next_phase=0;
                else next_phase=phase+1'b1;
            end
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) rectangle<={11'd90,11'd77,11'd256,11'd192};
        else rectangle<=next_native_rect;
    end
    end else begin assign native_rect=44'd0;end endgenerate
    reg [29:0] xs;
    reg [26:0] ys;
    wire [9:0] legacy_left=column==2 ? xs[29:20] : column==1 ? xs[19:10] : xs[9:0];
    wire [8:0] legacy_top=row==2 ? ys[26:18] : row==1 ? ys[17:9] : ys[8:0];
    // Keep 160x120 thumbnail origins; expand into the720x576 native frame.
    wire [9:0] native_width=160+((size-40)*14)/3;
    assign width=MODE_576 ? {native_width[9:1],1'b0} : {size,2'b00};
    assign height=MODE_576 ? 120+((size-40)*19)/5 : {size,1'b0}+size;
    assign left=legacy_left+(MODE_576 ? (160-size)/3 : 0);
    assign top=legacy_top+(MODE_576 ? ((160-size)*2)/5 : 0);
    assign border_size=phase<3 ? 2'd3 : phase<16 ? 2'd2 : phase==16 ? 2'd1 : 2'd0;
    assign dim=!moving ? 3'd0 : phase>=4 ? 3'd4 : {1'b0,phase[1:0]};
    always @* begin
        size=160;xs=0;ys=0;
        case(phase)
            5'd0: begin size=8'd40; xs={10'd424,10'd240,10'd56}; ys={9'd336,9'd192,9'd48};end
            5'd1: begin size=8'd41; xs={10'd422,10'd238,10'd54}; ys={9'd335,9'd191,9'd47};end
            5'd2: begin size=8'd41; xs={10'd422,10'd238,10'd54}; ys={9'd335,9'd191,9'd47};end
            5'd3: begin size=8'd63; xs={10'd343,10'd194,10'd44}; ys={9'd272,9'd155,9'd38};end
            5'd4: begin size=8'd83; xs={10'd275,10'd155,10'd35}; ys={9'd218,9'd124,9'd31};end
            5'd5: begin size=8'd99; xs={10'd216,10'd122,10'd28}; ys={9'd172,9'd98,9'd24};end
            5'd6: begin size=8'd113; xs={10'd166,10'd94,10'd21}; ys={9'd132,9'd75,9'd19};end
            5'd7: begin size=8'd125; xs={10'd125,10'd71,10'd16}; ys={9'd99,9'd57,9'd14};end
            5'd8: begin size=8'd134; xs={10'd91,10'd51,10'd12}; ys={9'd72,9'd41,9'd10};end
            5'd9: begin size=8'd142; xs={10'd64,10'd36,10'd8}; ys={9'd51,9'd29,9'd7};end
            5'd10: begin size=8'd148; xs={10'd43,10'd24,10'd5}; ys={9'd34,9'd19,9'd5};end
            5'd11: begin size=8'd152; xs={10'd27,10'd15,10'd3}; ys={9'd21,9'd12,9'd3};end
            5'd12: begin size=8'd156; xs={10'd16,10'd9,10'd2}; ys={9'd12,9'd7,9'd2};end
            5'd13: begin size=8'd158; xs={10'd8,10'd5,10'd1}; ys={9'd6,9'd4,9'd1};end
            5'd14: begin size=8'd159; xs={10'd3,10'd2,10'd0}; ys={9'd3,9'd2,9'd0};end
            5'd15: begin size=8'd160; xs=0; ys=0;end
            5'd16: begin size=8'd160; xs={10'd0,10'd0,10'd0}; ys={9'd0,9'd0,9'd0};end
            5'd17: begin size=8'd160; xs={10'd0,10'd0,10'd0}; ys={9'd0,9'd0,9'd0};end
            5'd18: begin size=8'd160; xs={10'd0,10'd0,10'd0}; ys={9'd0,9'd0,9'd0};end
            5'd19: begin size=8'd160; xs={10'd0,10'd0,10'd0}; ys={9'd0,9'd0,9'd0};end
            default:begin size=160;xs=0;ys=0;end
        endcase
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            active<=0;moving<=0;phase<=0;target<=0;column<=0;row<=0;
            seen_select<=0;previous_browse<=0;wait_frames<=0;
        end else begin
            seen_select<=select_toggle;previous_browse<=browse;
            if(select_toggle!=seen_select && (previous_browse || active)) begin
                if(!effects_disabled && select_index<9 && ready[select_index]) begin
                    active<=1;moving<=0;phase<=0;target<=select_index;wait_frames<=0;
                    column<=select_index==2 || select_index==5 || select_index==8 ? 2 :
                            select_index==1 || select_index==4 || select_index==7 ? 1 : 0;
                    row<=select_index>=6 ? 2 : select_index>=3 ? 1 : 0;
                end else begin active<=0;moving<=0;phase<=0;end
            end else if(frame_tick && active) begin
                if(directory || status_panel || browse || !ready[target] ||
                   (moving && (active_picture!=target ||
                    (request_toggle!=ack_toggle && pending_picture!=target)))) begin
                    active<=0;moving<=0;phase<=0;
                end else if(!alarm) begin
                    if(!moving) begin
                        if(display_valid && active_picture==target && request_toggle==ack_toggle) begin
                            moving<=1;phase<=0;
                        end else if(wait_frames==2*FRAME_HZ-1) begin active<=0;moving<=0;end
                        else wait_frames<=wait_frames+1'b1;
                    end else if(phase==19) begin active<=0;moving<=0;phase<=0;end
                    else phase<=phase+1'b1;
                end
            end
        end
    end
endmodule

// Keep the original thumbnail RAM. A second, aligned video stage shades the
// grid; the moving card uses the selected full-resolution SDRAM bank.
module thumbnail_scene #(parameter integer MODE_576=0,MODE_XGA=0,PRECOMPUTED_GEOMETRY=0)(
    input write_clk,input write_enable,input [3:0] write_slot,
    input [15:0] pixel_x,input [15:0] pixel_y,input [23:0] pixel_rgb,
    input clk,input rst,input hs,input vs,input de,input [23:0] rgb,
    input browse,input [3:0] focus,input [8:0] ready,input [8:0] available,input [8:0] failed,
    input active,input moving,input [3:0] target,
    input [9:0] left,input [9:0] top,input [7:0] size,
    input [9:0] explicit_width,input [9:0] explicit_height,
    input [43:0] native_rect,
    input [1:0] border_size,input [2:0] dim,
    output reg out_hs,output reg out_vs,output reg out_de,output reg [23:0] out_rgb
);
    wire [23:0] grid_rgb;
    wire grid_hs,grid_vs,grid_de;
    thumbnail_video #(.MODE_576(MODE_576),.MODE_XGA(MODE_XGA)) grid(
        .write_clk(write_clk),.write_enable(write_enable),.write_slot(write_slot),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_rgb(pixel_rgb),
        .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .browse(browse || active),.focus(active ? target : focus),.ready(ready),
        .available(available),.failed(failed),
        .out_hs(grid_hs),.out_vs(grid_vs),.out_de(grid_de),.out_rgb(grid_rgb));
    reg last_de,last_vs;
    reg [9:0] scene_x,scene_y;
    wire [9:0] logical_x,logical_y;
    generate if(MODE_XGA) begin: registered_coordinates
        player_xga_logical_coordinates coordinates(.clk(clk),.rst(rst),.de(de),
            .frame_tick(last_vs && !vs),.row_tick(last_de && !de),
            .native_x_phase(scene_x[2:0]),.native_y_phase(scene_y[2:0]),.x(logical_x),.y(logical_y));
    end else begin assign logical_x=0;assign logical_y=0;end endgenerate
    wire [9:0] x=MODE_XGA ? logical_x : scene_x;
    wire [9:0] y=MODE_XGA ? logical_y : scene_y;
    wire [9:0] width=MODE_576 ? explicit_width : {size,2'b00};
    wire [9:0] height=MODE_576 ? explicit_height : {size,1'b0}+size;
    wire [9:0] lx=x-left;
    wire [9:0] ly=y-top;
    wire [9:0] shadow_x=x-left-10'd5;
    wire [9:0] shadow_y=y-top-9'd6;
    wire [9:0] origin_x=(MODE_576 ? 40 : 0)+(target==2 || target==5 || target==8 ? 424 :
                         target==1 || target==4 || target==7 ? 240 : 56);
    wire [9:0] origin_y=(MODE_576 ? 48 : 0)+(target>=6 ? 336 : target>=3 ? 192 : 48);
    wire [9:0] ox=x-origin_x;
    wire [9:0] oy=y-origin_y;
    // Match the SDRAM reader's word-aligned rectangle exactly. The grid and
    // text retain logical coordinates, while full-size picture pixels do not.
    wire [10:0] scaled_width=(width*8)/5;
    wire [10:0] native_left=PRECOMPUTED_GEOMETRY ? native_rect[43:33] : (left*8+4)/5;
    wire [10:0] native_top=PRECOMPUTED_GEOMETRY ? native_rect[32:22] : (top*8+4)/5;
    wire [10:0] native_width=PRECOMPUTED_GEOMETRY ? native_rect[21:11] : {scaled_width[10:2],2'b00};
    wire [10:0] native_height=PRECOMPUTED_GEOMETRY ? native_rect[10:0] : (height*8)/5;
    wire [10:0] native_lx={1'b0,scene_x}-native_left,native_ly={1'b0,scene_y}-native_top;
    wire [10:0] native_shadow_x=native_lx-8,native_shadow_y=native_ly-10;
    wire [3:0] native_border=(border_size*8+4)/5;
    reg moving_q,card_q,edge_q,shadow_q,origin_q;
    reg [2:0] dim_q;
    reg [23:0] raw_q;
    wire [23:0] grid_stage,raw_stage;
    wire grid_hs_stage,grid_vs_stage,grid_de_stage;
    wire origin_stage,shadow_stage,moving_stage,card_stage,edge_stage;
    wire [2:0] dim_stage;
    generate if(MODE_XGA) begin: shade_input_pipeline
        reg [23:0] grid_d,raw_d;
        reg hs_d,vs_d,de_d,origin_d,shadow_d,moving_d,card_d,edge_d;
        reg [2:0] dim_d;
        always @(posedge clk or posedge rst) begin
            if(rst) begin
                grid_d<=0;raw_d<=0;hs_d<=1;vs_d<=1;de_d<=0;
                origin_d<=0;shadow_d<=0;moving_d<=0;card_d<=0;edge_d<=0;dim_d<=0;
            end else begin
                grid_d<=grid_rgb;raw_d<=raw_q;hs_d<=grid_hs;vs_d<=grid_vs;de_d<=grid_de;
                origin_d<=origin_q;shadow_d<=shadow_q;moving_d<=moving_q;
                card_d<=card_q;edge_d<=edge_q;dim_d<=dim_q;
            end
        end
        assign {grid_stage,raw_stage,grid_hs_stage,grid_vs_stage,grid_de_stage}=
            {grid_d,raw_d,hs_d,vs_d,de_d};
        assign {origin_stage,shadow_stage,moving_stage,card_stage,edge_stage,dim_stage}=
            {origin_d,shadow_d,moving_d,card_d,edge_d,dim_d};
    end else begin
        assign {grid_stage,raw_stage,grid_hs_stage,grid_vs_stage,grid_de_stage}=
            {grid_rgb,raw_q,grid_hs,grid_vs,grid_de};
        assign {origin_stage,shadow_stage,moving_stage,card_stage,edge_stage,dim_stage}=
            {origin_q,shadow_q,moving_q,card_q,edge_q,dim_q};
    end endgenerate
    wire [23:0] background=origin_stage ? 24'h182024 : grid_stage;
    reg [8:0] shade_gain;
    reg [16:0] shaded_r,shaded_g,shaded_b;
    reg [23:0] base_qq,raw_qq;
    reg moving_qq,card_qq,edge_qq;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            scene_x<=0;scene_y<=0;last_de<=0;last_vs<=1;moving_q<=0;card_q<=0;edge_q<=0;
            shadow_q<=0;origin_q<=0;dim_q<=0;raw_q<=0;
            out_hs<=1;out_vs<=1;out_de<=0;shaded_r<=0;shaded_g<=0;shaded_b<=0;
            base_qq<=0;raw_qq<=0;moving_qq<=0;card_qq<=0;edge_qq<=0;
        end else begin
            last_de<=de;last_vs<=vs;
            if(de) scene_x<=scene_x+1'b1;else scene_x<=0;
            if(last_vs && !vs) scene_y<=0;else if(last_de && !de) scene_y<=scene_y+1'b1;
            moving_q<=moving;raw_q<=rgb;dim_q<=dim;
            card_q<=MODE_XGA ? native_lx<native_width && native_ly<native_height : lx<width && ly<height;
            edge_q<=border_size!=0 && (MODE_XGA ?
                native_lx<native_border || native_lx>=native_width-native_border ||
                native_ly<native_border || native_ly>=native_height-native_border :
                lx<border_size || lx>=width-border_size || ly<border_size || ly>=height-border_size);
            shadow_q<=MODE_XGA ? native_shadow_x<native_width && native_shadow_y<native_height : shadow_x<width && shadow_y<height;
            origin_q<=ox<160 && oy<120;
            // DSP multipliers implement the three shaded channels. Registered
            // outputs add one clock equally to RGB, geometry and video sync.
            shaded_r<=background[23:16]*shade_gain;
            shaded_g<=background[15:8]*shade_gain;
            shaded_b<=background[7:0]*shade_gain;
            base_qq<=grid_stage;raw_qq<=raw_stage;
            moving_qq<=moving_stage;card_qq<=card_stage;edge_qq<=edge_stage;
            out_hs<=grid_hs_stage;out_vs<=grid_vs_stage;out_de<=grid_de_stage;
        end
    end
    always @* begin
        case(dim_stage)
            1:shade_gain=224;2:shade_gain=192;3:shade_gain=160;4:shade_gain=128;
            default:shade_gain=256;
        endcase
        if(shadow_stage) shade_gain=shade_gain>>2;
        out_rgb=base_qq;
        if(moving_qq) begin
            out_rgb={shaded_r[15:8],shaded_g[15:8],shaded_b[15:8]};
            if(card_qq) out_rgb=edge_qq ? 24'hffd050 : raw_qq;
        end
        if(!out_de) out_rgb=0;
    end
endmodule


// Exact XGA conversion of the finite animation tables above and in
// player_picture_zoom. No extra registers or display latency are added.
module player_xga_geometry(input [4:0] expand_phase,picture_phase,
    input [3:0] target,output [43:0] expand_rect,output reg [43:0] picture_rect);
    reg [32:0] lefts,tops;
    reg [10:0] width,height;
    wire [10:0] left=target==2 || target==5 || target==8 ? lefts[32:22] :
        target==1 || target==4 || target==7 ? lefts[21:11] : lefts[10:0];
    wire [10:0] top=target>=6 ? tops[32:22] : target>=3 ? tops[21:11] : tops[10:0];
    assign expand_rect={left,top,width,height};
    always @* begin
        lefts=0;tops=0;width=1024;height=768;
        case(expand_phase)
            5'd0:begin lefts={11'd679,11'd384,11'd90};tops={11'd538,11'd308,11'd77};width=11'd256;height=11'd192;end
            5'd1:begin lefts={11'd676,11'd381,11'd87};tops={11'd536,11'd306,11'd76};width=11'd260;height=11'd196;end
            5'd2:begin lefts={11'd676,11'd381,11'd87};tops={11'd536,11'd306,11'd76};width=11'd260;height=11'd196;end
            5'd3:begin lefts={11'd549,11'd311,11'd71};tops={11'd436,11'd248,11'd61};width=11'd400;height=11'd302;end
            5'd4:begin lefts={11'd440,11'd248,11'd56};tops={11'd349,11'd199,11'd50};width=11'd528;height=11'd398;end
            5'd5:begin lefts={11'd346,11'd196,11'd45};tops={11'd276,11'd157,11'd39};width=11'd632;height=11'd475;end
            5'd6:begin lefts={11'd266,11'd151,11'd34};tops={11'd212,11'd120,11'd31};width=11'd720;height=11'd542;end
            5'd7:begin lefts={11'd200,11'd114,11'd26};tops={11'd159,11'd92,11'd23};width=11'd800;height=11'd600;end
            5'd8:begin lefts={11'd146,11'd82,11'd20};tops={11'd116,11'd66,11'd16};width=11'd856;height=11'd643;end
            5'd9:begin lefts={11'd103,11'd58,11'd13};tops={11'd82,11'd47,11'd12};width=11'd908;height=11'd681;end
            5'd10:begin lefts={11'd69,11'd39,11'd8};tops={11'd55,11'd31,11'd8};width=11'd944;height=11'd710;end
            5'd11:begin lefts={11'd44,11'd24,11'd5};tops={11'd34,11'd20,11'd5};width=11'd972;height=11'd729;end
            5'd12:begin lefts={11'd26,11'd15,11'd4};tops={11'd20,11'd12,11'd4};width=11'd996;height=11'd748;end
            5'd13:begin lefts={11'd13,11'd8,11'd2};tops={11'd10,11'd7,11'd2};width=11'd1008;height=11'd758;end
            5'd14:begin lefts={11'd5,11'd4,11'd0};tops={11'd5,11'd4,11'd0};width=11'd1016;height=11'd763;end
            5'd16:begin lefts={11'd0,11'd0,11'd0};tops={11'd0,11'd0,11'd0};width=11'd1024;height=11'd768;end
            5'd17:begin lefts={11'd0,11'd0,11'd0};tops={11'd0,11'd0,11'd0};width=11'd1024;height=11'd768;end
            5'd18:begin lefts={11'd0,11'd0,11'd0};tops={11'd0,11'd0,11'd0};width=11'd1024;height=11'd768;end
            5'd19:begin lefts={11'd0,11'd0,11'd0};tops={11'd0,11'd0,11'd0};width=11'd1024;height=11'd768;end
            default:begin end
        endcase
    end
    always @* begin
        case(picture_phase)
            0,1:picture_rect={11'd77,11'd52,11'd868,11'd652};
            2:picture_rect={11'd74,11'd50,11'd876,11'd657};
            3:picture_rect={11'd71,11'd47,11'd880,11'd662};
            4:picture_rect={11'd64,11'd44,11'd896,11'd672};
            5:picture_rect={11'd58,11'd40,11'd908,11'd681};
            6:picture_rect={11'd52,11'd36,11'd920,11'd691};
            7:picture_rect={11'd45,11'd31,11'd932,11'd700};
            8:picture_rect={11'd39,11'd26,11'd944,11'd710};
            9:picture_rect={11'd32,11'd21,11'd960,11'd720};
            10:picture_rect={11'd26,11'd16,11'd972,11'd729};
            11:picture_rect={11'd20,11'd12,11'd984,11'd739};
            12:picture_rect={11'd13,11'd8,11'd996,11'd748};
            13:picture_rect={11'd7,11'd5,11'd1008,11'd758};
            14:picture_rect={11'd4,11'd2,11'd1016,11'd763};
            default:picture_rect={11'd0,11'd0,11'd1024,11'd768};
        endcase
    end
endmodule

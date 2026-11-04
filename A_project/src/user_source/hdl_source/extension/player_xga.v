`timescale 1ns/1ps
// Registered floor(native_coordinate*5/8). The increment pattern removes
// a shift/add carry chain from every UI pixel path without delaying pixels.
module player_xga_logical_coordinates(
    input clk,input rst,input de,input frame_tick,input row_tick,
    input [2:0] native_x_phase,input [2:0] native_y_phase,
    output reg [9:0] x,output reg [9:0] y
);
    wire x_step=native_x_phase==1 || native_x_phase==3 || native_x_phase==4 || native_x_phase==6 || native_x_phase==7;
    wire y_step=native_y_phase==1 || native_y_phase==3 || native_y_phase==4 || native_y_phase==6 || native_y_phase==7;
    always @(posedge clk or posedge rst) begin
        if(rst) begin x<=0;y<=0;end
        else begin
            if(!de) x<=0;else if(x_step) x<=x+1'b1;
            if(frame_tick) y<=0;else if(row_tick && y_step) y<=y+1'b1;
        end
    end
endmodule

// Render 640x480 once per XGA frame at 32.5 MHz. Each source row is
// scheduled one output line before its first use; 5 source rows -> 8 lines.
module player_xga_native_timing(input clk,input rst,input ack,
    output reg request,output hs,output vs,output de,output reg frame_toggle);
    reg [10:0] h;
    reg [9:0] v;
    reg [5:0] guard;
    (* async_reg="true" *) reg [1:0] ack_sync;
    assign hs=h>=136;
    assign vs=v>=6;
    assign de=h>=296 && h<1320 && v>=35 && v<803;
    always @(posedge clk or posedge rst) begin
        if(rst) begin h<=0;v<=0;guard<=32;request<=0;ack_sync<=0;frame_toggle<=0;end
        else begin
            ack_sync<={ack_sync[0],ack};
            if(guard!=0) guard<=guard-1'b1;
            if(guard==1) request<=1;
            else if(ack_sync[1]) request<=0;
            if(h==1343) begin
                h<=0;
                if(v==805) begin v<=0;guard<=32;frame_toggle<=~frame_toggle;end
                else v<=v+1'b1;
            end else h<=h+1'b1;
        end
    end
endmodule

module player_xga_source(input clk,input rst,input ack,
    output reg request,output hs,output vs,output de,output reg frame_toggle);
    reg [9:0] h,v;
    reg [2:0] phase;
    reg [5:0] guard;
    reg [1:0] ack_sync;
    wire selected=phase==0 || phase==2 || phase==4 || phase==5 || phase==7;
    assign hs=!(h>=640 && h<656);
    assign vs=v>=6;
    assign de=v>=34 && v<802 && selected && h<640;
    always @(posedge clk or posedge rst) begin
        if(rst) begin h<=0;v<=0;phase<=0;guard<=32;request<=0;ack_sync<=0;frame_toggle<=0;end
        else begin
            ack_sync<={ack_sync[0],ack};
            if(guard!=0) guard<=guard-1'b1;
            if(guard==1) request<=1;
            else if(ack_sync[1]) request<=0;
            if(h==671) begin
                h<=0;
                if(v==805) begin v<=0;guard<=32;frame_toggle<=~frame_toggle;end
                else v<=v+1'b1;
                if(v<34 || v>=801) phase<=0;else phase<=phase+1'b1;
            end else h<=h+1'b1;
        end
    end
endmodule

// Two completed RGB565 rows, nearest-neighbour 8/5 expansion. No full-frame
// output store and no extra SDRAM reads for duplicated output rows/pixels.
// Source/destination clocks are related outputs of the same PLL (1:2).
module player_xga_scaler(input source_clk,input source_rst,input source_vs,
    input source_de,input [23:0] source_rgb,input frame_toggle,
    input pixel_clk,input pixel_rst,
    output reg hs,output reg vs,output reg de,output [23:0] rgb);
    reg [15:0] rows[0:2047];
    reg [15:0] pixel;
    assign rgb={pixel[15:11],pixel[15:13],pixel[10:5],pixel[10:9],pixel[4:0],pixel[4:2]};
    reg [9:0] wx;
    reg write_bank,last_de,last_vs;
    always @(posedge source_clk) begin
        if(source_de) rows[{write_bank,wx}]<={source_rgb[23:19],source_rgb[15:10],source_rgb[7:3]};
    end
    always @(posedge source_clk or posedge source_rst) begin
        if(source_rst) begin wx<=0;write_bank<=0;last_de<=0;last_vs<=0;end
        else begin
            last_de<=source_de;last_vs<=source_vs;
            if(last_vs && !source_vs) begin wx<=0;write_bank<=0;end
            else begin
                if(source_de) wx<=wx+1'b1;else wx<=0;
                if(last_de && !source_de) write_bank<=~write_bank;
            end
        end
    end
    (* async_reg="true" *) reg [2:0] frame_sync;
    reg [10:0] h;
    reg [9:0] v;
    reg [9:0] sx;
    reg [2:0] xphase,yphase;
    reg read_bank;
    always @(posedge pixel_clk) pixel<=rows[{read_bank,sx}];
    wire active=h>=296 && h<1320 && v>=35 && v<803;
    always @(posedge pixel_clk or posedge pixel_rst) begin
        if(pixel_rst) begin
            frame_sync<=0;h<=0;v<=0;sx<=0;xphase<=0;yphase<=0;read_bank<=0;
            hs<=1;vs<=1;de<=0;
        end else begin
            frame_sync<={frame_sync[1:0],frame_toggle};
            if(frame_sync[2]!=frame_sync[1]) begin h<=0;v<=0;sx<=0;xphase<=0;yphase<=0;read_bank<=0;end
            else if(h==1343) begin
                h<=0;v<=v==805 ? 0 : v+1'b1;
                if(v<35 || v>=802) begin yphase<=0;read_bank<=0;end
                else begin
                    yphase<=yphase+1'b1;
                    if(yphase==1 || yphase==3 || yphase==4 || yphase==6 || yphase==7)
                        read_bank<=~read_bank;
                end
            end else h<=h+1'b1;
            if(!active) begin sx<=0;xphase<=0;end
            else begin
                xphase<=xphase+1'b1;
                if(xphase==1 || xphase==3 || xphase==4 || xphase==6 || xphase==7) sx<=sx+1'b1;
            end
            hs<=h>=136;vs<=v>=6;de<=active;
            // Synchronous RAM read; DE/HS/VS have the identical one-edge delay.

        end
    end
endmodule

// Audio samples are held for >600 source clocks. A toggle crosses to the
// faster HDMI clock; capture follows two settling clocks. CTS refers to the
// HDMI 65 MHz pixel clock, independently of the 32.5 MHz audio engine.
module player_xga_audio(input source_clk,input source_rst,input valid,input [23:0] pcm,
    input pixel_clk,input pixel_rst,output reg out_valid,output reg [23:0] out_pcm,
    output reg acr_valid);
    reg toggle;
    reg [23:0] held;
    (* async_reg="true" *) reg [2:0] sync;
    reg [6:0] count;
    always @(posedge source_clk or posedge source_rst)
        if(source_rst) begin toggle<=0;held<=0;end
        else if(valid) begin held<=pcm;toggle<=~toggle;end
    always @(posedge pixel_clk or posedge pixel_rst)
        if(pixel_rst) begin sync<=0;out_valid<=0;out_pcm<=0;acr_valid<=0;count<=0;end
        else begin
            sync<={sync[1:0],toggle};out_valid<=0;acr_valid<=0;
            if(sync[2]!=sync[1]) begin out_valid<=1;out_pcm<=held;acr_valid<=count==0;count<=count+1'b1;end
        end
endmodule

`timescale 1ns/1ps
// The top permanently clears only the OSD's hide-header bit. Keep the status
// glyphs, background and five-stage pipeline identical for either SW1 value.
module tb_sw1_header;
    reg clk=0,rst=1,sw1=0;
    reg [9:0] x=0;reg [8:0] y=0;
    wire cover_on;wire [23:0] color;
    wire [3:0] modes={2'b0,sw1,1'b0};
    reg [24:0] reference[0:15359];
    integer state,row,col,index,k;
    always #5 clk=~clk;
    player_status_osd #(.PANEL_ALPHA_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.x(x),.y(y),.brightness(9'sd0),
        .bright_digits(12'd0),.contrast_digits(12'h128),.picture(4'd0),.scaled(1'b0),
        .auto_play(1'b1),.run_mode(2'd2),.error_code(8'd0),.audio_status(8'd1),.state_code(4'd0),
        .volume(4'd8),.interval_seconds(4'd3),.menu(3'd0),.modes(modes),
        .directory(1'b0),.status_panel(1'b0),.alarm(1'b0),.browse(1'b0),.image_valid(1'b1),
        .source_resolution(40'h0064000480),.debug_status(60'd0),.time_digits(24'd0),
        .cover_on(cover_on),.color(color),.background_rgb(24'h081014),.transition_mode(4'd0),.audio_select(2'd0));
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(state=0;state<2;state=state+1) begin
            sw1=state;x=0;y=0;repeat(8) @(negedge clk);index=0;
            for(row=0;row<24;row=row+1) for(col=0;col<640;col=col+1) begin
                @(negedge clk);x=col;y=row;
                @(posedge clk);#1;
                if(dut.top_active!==1 || dut.cover0!==1) $fatal(1,"header hidden at SW1=%0d",state);
                if(state==0) reference[index]={cover_on,color};
                else if({cover_on,color}!==reference[index]) $fatal(1,"header pixel changed at %0d,%0d",col,row);
                index=index+1;
            end
        end
        $display("PASS SW1 permanent header: all 15360 pixels identical in both switch states, original glyphs/alpha/pipeline");$finish;
    end
endmodule

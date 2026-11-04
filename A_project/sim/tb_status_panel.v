`timescale 1ns/1ps
module tb_status_panel;
    reg clk=0,rst=1;reg [9:0] x=0;reg [8:0] y=0;
    reg [3:0] modes=0;reg [2:0] menu=0;
    reg panel=1,directory=0,alarm=0;
    wire cover_on;wire [23:0] color;
    integer phase,xx,yy,k,file,count,selected_pixels;
    reg ref_cover,ref_selected;reg [23:0] ref_base;
    reg [4:0] covers=0;reg [23:0] expected[0:4];
    reg [23:0] pixel;
    always #5 clk=~clk;
    player_status_osd dut(.clk(clk),.rst(rst),.x(x),.y(y),
        .brightness(9'sd64),.bright_digits(12'h064),.contrast_digits(12'h128),
        .picture(3'd2),.scaled(1'b1),.auto_play(1'b1),.run_mode(2'd2),
        .error_code(8'h00),.audio_status(8'h01),.state_code(4'hf),
        .volume(4'd4),.interval_seconds(4'd3),.transition_mode(4'd0),.menu(menu),.modes(modes),
        .directory(directory),.status_panel(panel),.alarm(alarm),.browse(1'b0),
        .image_valid(1'b1),.source_resolution(40'h0192001440),
        .debug_status(60'hfffffffffffffff),.time_digits(24'h235959),
        .cover_on(cover_on),.color(color));
    initial begin
        for(k=0;k<5;k=k+1) expected[k]=0;
        repeat(4) @(negedge clk);rst=0;
        // Every pixel, all seven editable rows, SW1 hidden, and menu/alarm priority.
        for(phase=0;phase<11;phase=phase+1) begin
            modes=phase>=1 && phase<=7 ? 9 : 1;menu=phase-1;
            panel=phase!=8;directory=phase==9;alarm=phase==10;
            count=0;selected_pixels=0;covers=0;file=0;
            if(phase==7) file=$fopen("../doc/validation/status_edit.ppm","wb");
            if(phase==7 && file==0) $fatal(1,"cannot open panel raster");
            if(file) $fwrite(file,"P6\n640 480\n255\n");
            for(yy=0;yy<480;yy=yy+1) for(xx=0;xx<640;xx=xx+1) begin
                @(negedge clk);x=xx;y=yy;#1;
                ref_cover=phase<8 && xx>=160 && xx<480 && yy>=128 && yy<352;
                ref_selected=phase>=1 && phase<=7 && xx>=176 && xx<464 &&
                             yy>=174+20*(phase-1) && yy<194+20*(phase-1);
                ref_base=24'h606060;
                if(ref_cover && (xx==160 || xx==479 || yy==128 || yy==351 ||
                   (yy==167 && xx>=176 && xx<464))) ref_base=24'hc0c8c8;
                if(ref_selected) ref_base=24'ha5dfd9;
                if(dut.cover0!==ref_cover) $fatal(1,"center bounds/priority phase=%0d x=%0d y=%0d",phase,xx,yy);
                if(ref_cover && dut.base!==ref_base) $fatal(1,"panel frame/cursor position");
                if(ref_cover && dut.text_on && (dut.code>=126 && dut.code<=137))
                    $fatal(1,"removed diagnostics still displayed");
                if(ref_cover && dut.text_on && (dut.code==102 || dut.code==159 || dut.code==160 ||
                   dut.code==161 || dut.code==118 || dut.code==119 || dut.code==37 || dut.code==55))
                    $fatal(1,"removed resolution or status row still displayed");
                if(ref_cover && dut.text_on!==(xx>=184 && xx<456 &&
                   ((yy>=144 && yy<160) || (yy>=176 && yy<332 && (yy-176)%20<16))))
                    $fatal(1,"eight-row spacing or title text bounds");
                if(ref_cover && dut.text_on && dut.code!=0) begin
                    if(dut.ink!==(ref_selected ? 24'h123f43 :
                       (dut.line==7 ? ((dut.slot>=9 && dut.slot<=11) || dut.slot>=32) : dut.slot>=23) ? 24'hffe080 : 24'hffffff))
                        $fatal(1,"label/value/cursor ink");
                    if(dut.code<96 && dut.column[3]) $fatal(1,"ASCII sampled from wrong half");
                end
                if(ref_selected) selected_pixels=selected_pixels+1;
                @(posedge clk);#1;
                for(k=4;k>0;k=k-1) expected[k]=expected[k-1];
                expected[0]=ref_base;covers={covers[3:0],ref_cover};
                if(count>4 && cover_on!==covers[4]) $fatal(1,"panel cover pipeline");
                if(count>4 && covers[4] && !dut.hit4 && color!==expected[4])
                    $fatal(1,"panel background pipeline");
                // Pipeline is four coordinates behind the sampled pixel.
                if(file && count>=4) begin
                    pixel=cover_on ? color : 24'h304050;
                    $fwrite(file,"%c%c%c",pixel[23:16],pixel[15:8],pixel[7:0]);
                end
                count=count+1;
            end
            if(file) begin
                repeat(4) $fwrite(file,"%c%c%c",8'h30,8'h40,8'h50);
                $fclose(file);
            end
            if(selected_pixels!==(phase>=1 && phase<=7 ? 5760 : 0))
                $fatal(1,"selection size or stale cursor");
        end
        $display("PASS centered status: every pixel, seven 20px cursors, eight evenly spaced rows, no resolution/status diagnostics, SW1/settings and menu/alarm priority, five-stage alignment");
        $finish;
    end
endmodule

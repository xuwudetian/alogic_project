`timescale 1ns/1ps
module tb_ui;
    reg clk=0,rst=1,hs=1,vs=1,de=0,directory=1,alarm=0,status_panel=0;
    reg [1:0] selection=0;
    reg submenu=0;
    reg browse_mode=0,auto_mode=1;
    reg [1:0] running_mode=2;
    wire fh,fv,fd,oh,ov,od;
    wire [23:0] fx,out;
    integer row,col,mode,file,pixels,red,white,cyan,hint,step,warmup=0;
    reg [6:0] ds=0,hsq=127,vsq=127;
    always #20 clk=~clk;
    player_video #(.UI_ENABLE(1),.PANEL_ALPHA_ENABLE(1)) video(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(24'h486850),
        .brightness(9'sd0),.contrast(9'd128),.gain(9'd256),.display_valid(1'b1),.picture(3'd2),.scaled(1'b1),
        .auto_play(auto_mode),.error_code(8'h37),.state_code(4'd8),.volume(4'd4),.interval_seconds(4'd3),
        .transition_mode(4'd0),.menu(3'd0),.modes(4'd0),.audio_valid(1'b0),.audio_sample(24'd0),.out_hs(fh),.out_vs(fv),
        .out_de(fd),.out_rgb(fx),.debug_status(60'h123456789abcdef),.audio_status(8'h01),.image_valid(1'b1),
        .ui_directory(directory),.ui_status(status_panel),.ui_alarm(alarm),.ui_browse(browse_mode),
        .source_resolution(40'h0192001080),.run_mode(running_mode));
    player_ui_overlay #(.LOGO_ENABLE(1)) dut(.clk(clk),.rst(rst),.hs(fh),.vs(fv),.de(fd),.rgb(fx),
        .directory(directory),.selection(selection),.alarm(alarm),.out_hs(oh),.out_vs(ov),.out_de(od),.out_rgb(out),.directory_run(submenu));
    always @(posedge clk) begin
        ds={ds[5:0],de};hsq={hsq[5:0],hs};vsq={vsq[5:0],vs};
        #1;
        if(rst) warmup=0;else warmup=warmup+1;
        if(warmup>7 && (od!==ds[6] || oh!==hsq[6] || ov!==vsq[6])) $fatal(1,"UI sync misalignment");
        if(!directory && !alarm && fd) begin
            if(video.yp[4]<4 && fx!==24'h546458) $fatal(1,"header transparent top padding");
            if(video.yp[4]==23 && fx!==24'h404848) $fatal(1,"header divider");
            if(video.y==4 && video.x[2:0]==0) begin
                if(video.x==8 && video.chinese_osd.status.code!=(running_mode==1 ? 106 : 108)) $fatal(1,"Chinese AUTO/MAN mode missing");
                if(video.x==24 && video.chinese_osd.status.code!=107) $fatal(1,"Chinese mode second glyph missing");
                if(video.x>=40 && video.x<424 && video.chinese_osd.status.code!=0) $fatal(1,"removed header fields still present");
                if(video.x==424 && video.chinese_osd.status.code!=102) $fatal(1,"Chinese source missing");
                if(video.x==536 && video.chinese_osd.status.code!=18) $fatal(1,"original width not 1920");
                if(video.x==576 && video.chinese_osd.status.code!=16) $fatal(1,"original height not 1080");
            end
            if(status_panel && video.yp[4]>=128 && video.yp[4]<352 && video.xp[4]>=160 && video.xp[4]<480 &&
                fx!==24'h546458 && fx!==24'hc0c8c8 && fx!==24'hffe080 && fx!==24'hffffff)
                $fatal(1,"panel color leak x=%0d y=%0d rgb=%h cover=%b color=%h",video.xp[4],video.yp[4],fx,video.status_cover,video.status_color);
        end
        if(directory && dut.y==40 && dut.x==224 && dut.glyph_id!=138) $fatal(1,"system title missing");
        if(directory && dut.y==104 && dut.x==288 && dut.glyph_id!=144) $fatal(1,"directory title missing");
        if(directory && dut.x==112 && dut.y==128 && dut.base!=24'h101418) $fatal(1,"old tile position retained");
        if(directory && dut.x==112 && dut.y==160 && dut.tile!=0) $fatal(1,"tiles did not move down");
        if(od && file!=0) begin
            $fwrite(file,"%c%c%c",out[23:16],out[15:8],out[7:0]);pixels=pixels+1;
            if(out[23:16]>=8'hc0 && out[15:8]<8'h40 && out[7:0]<8'h40) red=red+1;
            if(out==24'hffffff) white=white+1;
            if(out==24'h40e0d0) cyan=cyan+1;
            if(out==24'hc0e8ff) hint=hint+1;
            if(alarm && pixels/640>196 && out!==dut.alarm_background) $fatal(1,"alarm background leaked picture");
        end
    end
    initial begin
        file=0;repeat(12) @(negedge clk);rst=0;
        for(mode=0;mode<8;mode=mode+1) begin
            directory=mode<3;selection=mode;alarm=mode==3;status_panel=mode==4;
            submenu=mode==1; // Deprecated input cannot create a second level.
            browse_mode=mode==7;auto_mode=mode!=5;
            running_mode=mode==5 ? 1 : 2;
            vs=0;repeat(12) @(negedge clk);vs=1;repeat(12) @(negedge clk);
            case(mode)
                0:file=$fopen("../doc/validation/menu_preview.ppm","wb");
                1:file=$fopen("../doc/validation/menu_resume.ppm","wb");
                2:file=$fopen("../doc/validation/menu_settings.ppm","wb");
                3:file=$fopen("../doc/validation/alarm.ppm","wb");
                4:file=$fopen("../doc/validation/status.ppm","wb");
                5:file=$fopen("../doc/validation/play_manual.ppm","wb");
                6:file=$fopen("../doc/validation/play_auto.ppm","wb");
                7:file=$fopen("../doc/validation/play_preview.ppm","wb");
            endcase
            if(!file) $fatal(1,"cannot open raster");
            $fwrite(file,"P6\n640 480\n255\n");pixels=0;red=0;white=0;cyan=0;hint=0;
            for(row=0;row<480;row=row+1) begin
                for(col=0;col<650;col=col+1) begin
                    @(negedge clk);de=col<640;hs=!(col>=642 && col<646);
                end
            end
            @(negedge clk);de=0;repeat(12) @(negedge clk);
            $fclose(file);file=0;
            if(pixels!=307200) $fatal(1,"raster incomplete %0d",pixels);
            if(directory && (white<100 || cyan<100)) $fatal(1,"menu missing glyphs/cursor");
            if(directory && hint<100) $fatal(1,"directory hint missing");
            if(!directory && hint!=0) $fatal(1,"directory hint leaked into other modes");
            if(mode==3 && red<5000) $fatal(1,"warning missing");
        end
        directory=0;repeat(12) @(negedge clk);directory=1;
        for(step=1;step<=1026;step=step+1) begin
            vs=0;repeat(12) @(negedge clk);vs=1;repeat(12) @(negedge clk);
            if(dut.hint_scroll!==((step/2)%512)) $fatal(1,"hint speed/wrap at frame %0d",step);
        end
        directory=0;repeat(12) @(negedge clk);
        if(dut.hint_scroll!=0) $fatal(1,"hint must restart on next directory entry");
        $display("PASS UI: eight full rasters with logo, playback AUTO/MAN labels, primary menu only, aligned status fields/padding/colors, cursor/glyphs, scrolling hint, alarm, sync");$finish;
    end
    initial begin #220000000;$fatal(1,"UI timeout");end
endmodule

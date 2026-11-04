`timescale 1ns/1ps
module tb_boot_overlay;
    reg clk=0,rst=1,hs=1,vs=1,de=0,ready=0,absent=0,alarm=0,directory=0;
    reg [23:0] rgb=24'h123456;
    wire oh,ov,od;wire [23:0] pixel;
    integer xx,yy,n,fd,count,phase,col,row,code,bright,logos,letters,letter,scenario;
    integer glyph_pixels[0:12];
    reg [23:0] expected0,expected1;
    reg [2:0] sync0,sync1;
    reg [31:0] logo_bits;
    function integer title_code;
        input integer index;
        begin case(index)
            0:title_code=205;1:title_code=206;
            2:title_code=38;3:title_code=48;4:title_code=39;5:title_code=33;
            6:title_code=207;
            default:title_code=138+index-7;
        endcase end
    endfunction
    function [23:0] official_color;
        input integer lx,ly;
        integer first_red;
        begin
            case(ly/2)
                0,1:first_red=12;3:first_red=13;4:first_red=14;6:first_red=15;
                9:first_red=16;12:first_red=17;14,15:first_red=18;
                17:first_red=19;18:first_red=20;20:first_red=21;
                default:first_red=32;
            endcase
            official_color=lx/2>=first_red ? 24'hed1b23 : 24'h1c2c4e;
        end
    endfunction
    always #5 clk=~clk;
    player_ui_overlay #(.LOGO_ENABLE(1),.NO_SIGNAL_ENABLE(1),.BOOT_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .directory(directory),.selection(2'd0),.alarm(alarm),.directory_run(1'b0),
        .no_signal(absent),.boot_ready(ready),.out_hs(oh),.out_vs(ov),.out_de(od),.out_rgb(pixel));
    task reset_dut;begin
        rst=1;de=0;vs=1;alarm=0;directory=0;ready=0;absent=0;
        repeat(4) @(negedge clk);rst=0;repeat(3) @(negedge clk);
        if(!dut.boot_active || !dut.boot_visible) $fatal(1,"boot missing after reset");
    end endtask
    task frame;begin
        de=0;vs=0;repeat(3) @(negedge clk);vs=1;repeat(3) @(negedge clk);
    end endtask
    task raster;input integer which;begin
        frame;phase=dut.boot_bar_phase;bright=0;logos=0;letters=0;count=0;
        for(letter=0;letter<13;letter=letter+1) glyph_pixels[letter]=0;
        if(which==0) fd=$fopen("boot_preview_0.ppm","wb");
        else fd=$fopen("boot_preview_1.ppm","wb");
        if(!fd) $fatal(1,"preview file");
        $fwrite(fd,"P6\n640 480\n255\n");
        sync0=3'b110;sync1=3'b110;expected0=0;expected1=0;
        for(yy=0;yy<480;yy=yy+1) begin
            for(xx=0;xx<650;xx=xx+1) begin
                @(negedge clk);de=xx<640;hs=!(xx>=642 && xx<646);
                sync1=sync0;sync0={hs,vs,de};expected1=expected0;expected0=0;
                if(de) begin
                    expected0=24'hffffff;
                    if(xx>=192 && xx<448 && yy>=304 && yy<312) begin
                        expected0=((xx-192-phase+256)%256)<32 ? 24'h40e0d0 : 24'h303c48;
                        if(expected0==24'h40e0d0) bright=bright+1;
                    end
                    code=0;col=0;row=0;
                    if(xx>=144 && xx<496 && yy>=224 && yy<256) begin
                        if(xx<208) begin letter=(xx-144)/32;col=((xx-144)%32)/2;end
                        else if(xx<272) begin letter=2+(xx-208)/16;col=((xx-208)%16)/2;end
                        else begin letter=6+(xx-272)/32;col=((xx-272)%32)/2;end
                        code=title_code(letter);row=(yy-224)/2;
                        if(dut.font.rows[code*16+row][15-col]) begin
                            expected0=24'h1c2c4e;letters=letters+1;
                            glyph_pixels[letter]=glyph_pixels[letter]+1;
                        end
                    end
                    if(xx>=288 && xx<352 && yy>=152 && yy<200) begin
                        logo_bits=dut.logo_layer.sprite.logo_row((yy-152)/2);
                        if(logo_bits[31-(xx-288)/2]) begin
                            expected0=official_color(xx-288,yy-152);
                            logos=logos+1;
                        end
                    end
                end
                @(posedge clk);#1;
                if(xx>1 && ({oh,ov,od}!==sync1 || pixel!==expected1))
                    $fatal(1,"boot raster x%0d y%0d pixel%h expected%h sync%b/%b",xx,yy,pixel,expected1,{oh,ov,od},sync1);
                if(od) begin $fwrite(fd,"%c%c%c",pixel[23:16],pixel[15:8],pixel[7:0]);count=count+1;end
            end
        end
        @(negedge clk);de=0;hs=1;repeat(4) @(negedge clk);$fclose(fd);
        if(count!=307200 || bright!=256 || logos<700 || letters<500) $fatal(1,"incomplete boot frame");
        for(letter=0;letter<13;letter=letter+1)
            if(glyph_pixels[letter]<20) $fatal(1,"missing title glyph %0d",letter);
        if(dut.boot_bar_phase!=phase) $fatal(1,"animation changes during active frame");
    end endtask
    initial begin
        // Production timing: 25MHz, 800*525 clocks/frame. Round 3.5s up to 209 frames.
        if(dut.BOOT_FRAMES!=209 || dut.BOOT_FRAMES*420000<87500000 ||
            dut.BOOT_FRAMES*420000>=87500000+420000) $fatal(1,"production duration is not 3.5s rounded to a frame");
        reset_dut;raster(0);raster(1);
        ready=1;de=1;repeat(8) @(negedge clk);
        if(!dut.boot_active) $fatal(1,"ready changed active frame");
        for(n=2;n<208;n=n+1) begin
            frame;if(!dut.boot_active) $fatal(1,"ready shortened fixed startup");
        end
        frame;if(dut.boot_active) $fatal(1,"fixed startup exit missing");
        ready=0;absent=1;frame;
        if(dut.boot_active) $fatal(1,"hotplug retriggered startup");
        // Not-ready, ready/error, no-card, and simultaneous flags all last 209 frames.
        for(scenario=0;scenario<4;scenario=scenario+1) begin
            reset_dut;ready=scenario%2;absent=scenario/2;
            for(n=0;n<208;n=n+1) begin
                frame;if(!dut.boot_active) $fatal(1,"early startup exit scenario %0d frame %0d",scenario,n+1);
            end
            de=1;repeat(8) @(negedge clk);
            if(!dut.boot_active) $fatal(1,"startup ended within active video");
            frame;if(dut.boot_active) $fatal(1,"fixed duration stuck scenario %0d",scenario);
            ready=!ready;absent=!absent;frame;
            if(dut.boot_active) $fatal(1,"status transition restarted startup");
        end
        reset_dut;alarm=1;#1;
        if(dut.boot_visible) $fatal(1,"boot blocks alarm");
        frame;alarm=0;#1;if(dut.boot_active) $fatal(1,"boot resumed after alarm");
        reset_dut;directory=1;#1;
        if(dut.boot_visible) $fatal(1,"boot blocks menu");
        frame;directory=0;#1;if(dut.boot_active) $fatal(1,"boot resumed after menu");
        $display("PASS boot: white full-frame pixel reference, complete FPGA title, removed loading text, color logo, animated bar, unchanged sync, fixed 209-frame duration for ready/error/no-card/waiting, menu/alarm/reset/hotplug");
        $finish;
    end
    initial begin #10000000;$fatal(1,"boot overlay timeout");end
endmodule

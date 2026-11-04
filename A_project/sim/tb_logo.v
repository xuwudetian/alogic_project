`timescale 1ns/1ps
module tb_logo;
    `define SPRITE dut.logo_layer.sprite
    reg clk=0,rst=1,hs=1,vs=1,de=0;
    reg directory=0,alarm=0;
    reg [23:0] rgb=0;
    wire oh,ov,od;
    wire [23:0] pixel;
    integer ix,iy,n,color_count=0,active_count=0,fd;
    integer px,py,dx,dy,bounces_x=0,bounces_y=0;
    reg old_left,old_up;
    reg [2:0] expected_sync=3'b110;
    reg [23:0] expected_base=0;
    integer expected_x=0,expected_y=0;
    reg inspect=0;
    // Independent stripe boundary reference in original 32x24 coordinates.
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
    player_ui_overlay #(.LOGO_ENABLE(1)) dut(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .directory(directory),.selection(2'd0),.alarm(alarm),.directory_run(1'b0),
        .out_hs(oh),.out_vs(ov),.out_de(od),.out_rgb(pixel));
    // The output must have exactly two register stages, with no displaced base pixels.
    always @(posedge clk) begin
        #1;
        if(inspect) begin
            if({oh,ov,od}!==expected_sync) $fatal(1,"logo changed sync latency");
            if(od) begin
                active_count=active_count+1;
                if(pixel!==expected_base && (pixel==24'hed1b23 || pixel==24'h1c2c4e)) begin
                    color_count=color_count+1;
                    if(expected_x<96 || expected_x>=160 || expected_y<72 || expected_y>=120)
                        $fatal(1,"logo outside bounding box");
                    if(pixel!==official_color(expected_x-96,expected_y-72))
                        $fatal(1,"official logo body/stripe color misaligned");
                end else if(pixel!==expected_base) $fatal(1,"transparent background corrupted");
                if(expected_y==72 && expected_x==120 && pixel!==24'hed1b23)
                    $fatal(1,"first colored logo pixel displaced");
                if(expected_y==72 && expected_x==96 && pixel!==expected_base)
                    $fatal(1,"transparent corner filled");
                $fwrite(fd,"%0d %0d %0d\n",pixel[23:16],pixel[15:8],pixel[7:0]);
            end else if(pixel!==0) $fatal(1,"blanking not black");
        end
        expected_sync={hs,vs,de};expected_base=rgb;expected_x=ix;expected_y=iy;
    end
    task frame;
        begin
            vs=0;@(negedge clk);vs=1;repeat(2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        frame;
        // Keep the first rendered frame at the reset location.
        fd=$fopen("logo_preview.ppm","w");$fwrite(fd,"P3\n640 480\n255\n");
        inspect=1;
        for(iy=0;iy<480;iy=iy+1) begin
            for(ix=0;ix<640;ix=ix+1) begin
                de=1;hs=1;rgb={8'h30,iy[7:0],ix[7:0]};@(negedge clk);
            end
            de=0;hs=0;repeat(5) @(negedge clk);
        end
        repeat(3) @(negedge clk);inspect=0;$fclose(fd);
        if(active_count!=307200 || color_count<700 || color_count>2000)
            $fatal(1,"missing pixels or blank logo %0d %0d",active_count,color_count);
        // Colored mark stays above directory and warning without inheriting their colors.
        force dut.x=120;force dut.y=72;de=1;directory=1;
        repeat(3) @(negedge clk);
        if(pixel!==24'hed1b23) $fatal(1,"directory covered logo");
        directory=0;alarm=1;repeat(3) @(negedge clk);
        if(pixel!==24'hed1b23) $fatal(1,"warning recolored/covered logo");
        release dut.x;release dut.y;de=0;alarm=0;repeat(3) @(negedge clk);
        // Many accelerated frame boundaries: motion is straight until a wall hit.
        for(n=0;n<3000;n=n+1) begin
            px=`SPRITE.logo_x;py=`SPRITE.logo_y;old_left=`SPRITE.left;old_up=`SPRITE.up;
            repeat(3) @(negedge clk);
            if(`SPRITE.logo_x!=px || `SPRITE.logo_y!=py) $fatal(1,"motion outside frame boundary");
            frame;
            if(`SPRITE.logo_x>576 || `SPRITE.logo_y>432) $fatal(1,"logo escaped screen");
            dx=`SPRITE.logo_x-px;dy=`SPRITE.logo_y-py;
            if(dx>2 || dx< -2 || dy>2 || dy< -2) $fatal(1,"motion jumped");
            if(`SPRITE.left!=old_left) begin
                bounces_x=bounces_x+1;
                if(px>2 && px<574) $fatal(1,"x direction changed away from wall");
            end
            if(`SPRITE.up!=old_up) begin
                bounces_y=bounces_y+1;
                if(py>2 && py<430) $fatal(1,"y direction changed away from wall");
            end
        end
        if(bounces_x<2 || bounces_y<2) $fatal(1,"not enough rebounds tested");
        // Corner contact must reflect both components on the same update.
        `SPRITE.logo_x=576;`SPRITE.logo_y=432;`SPRITE.left=0;`SPRITE.up=0;`SPRITE.frame_div=1;
        frame;
        if(!`SPRITE.left || !`SPRITE.up || `SPRITE.logo_x>576 || `SPRITE.logo_y>432)
            $fatal(1,"corner failed to reflect both axes");
        rst=1;@(negedge clk);
        if(od || pixel!=0 || `SPRITE.logo_x!=96 || `SPRITE.logo_y!=72) $fatal(1,"reset failed");
        $display("PASS logo: full frame, official navy/red transparent mask (%0d pixels), aligned sync, frame-only motion, walls/corner/reset",color_count);
        $finish;
    end
    initial begin #5000000;$fatal(1,"logo timeout");end
    `undef SPRITE
endmodule

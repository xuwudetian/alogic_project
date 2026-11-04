`timescale 1ns/1ps
module tb_new_effects;
    reg clk=0,rst=1,active=1;reg [9:0] x=0;reg [8:0] y=0;
    reg [2:0] style=0;reg [5:0] level=0;wire [4:0] masks;
    integer s,l,p,j,pos,count,file,xx,yy,tiles,changes;
    integer indices[0:4];reg history[0:307199];reg tile_value[0:1199];
    reg [23:0] pixel;reg [4:0] pipe_expected;
    player_image_mask dut(.clk(clk),.rst(rst),.x(x),.y(y),.active(active),.style(style),.level(level),.mask_pipe(masks));
    always #5 clk=~clk;
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(s=4;s<=6;s=s+1) begin
            style=s;
            for(l=0;l<=32;l=l+1) begin
                @(negedge clk);level=l;count=0;changes=0;file=0;
                if((s==5 && l==10) || (s!=5 && l==16)) begin
                    case(s)
                        4:file=$fopen("../doc/validation/transition_blocks.ppm","wb");
                        5:file=$fopen("../doc/validation/transition_rotation.ppm","wb");
                        6:file=$fopen("../doc/validation/transition_scatter.ppm","wb");
                    endcase
                    if(!file) $fatal(1,"cannot write preview");
                    $fwrite(file,"P6\n640 480\n255\n");
                end
                // Scan every pixel at all 33 levels. Verify visual properties,
                // not a duplicate of the coordinate hash implementation.
                for(p=0;p<307204;p=p+1) begin
                    @(negedge clk);x=p%640;y=(p/640)%480;
                    for(j=4;j>0;j=j-1) indices[j]=indices[j-1];indices[0]=p;
                    @(posedge clk);#1;
                    if(p>=4) begin
                        pos=indices[4];xx=pos%640;yy=pos/640;
                        if(masks[4]!==0 && masks[4]!==1) $fatal(1,"undefined mask");
                        if(l==0 && masks[4]) $fatal(1,"start not fully visible");
                        if(l==32 && !masks[4]) $fatal(1,"end not fully black");
                        if(l>0 && history[pos] && !masks[4]) $fatal(1,"dissolve flickered backwards");
                        if(l>0 && history[pos]!=masks[4]) changes=changes+1;
                        history[pos]=masks[4];count=count+masks[4];
                        if(s==4) begin
                            tiles=(yy/16)*40+xx/16;
                            if(xx%16==0 && yy%16==0) tile_value[tiles]=masks[4];
                            else if(tile_value[tiles]!==masks[4]) $fatal(1,"block not uniform 16x16");
                        end
                        if(s==5 && (l==8 || l==16 || l==24)) begin
                            if(masks[4]!==((l==8 && xx>=320 && yy<240) ||
                               (l==16 && xx>=320) || (l==24 && (xx>=320 || yy>=240))))
                                $fatal(1,"rotation quadrant/order l=%0d x=%0d y=%0d",l,xx,yy);
                        end
                        if(file) begin
                            pixel=masks[4] ? 0 : {xx[7:0],yy[7:0],xx[7:0]^yy[7:0]};
                            $fwrite(file,"%c%c%c",pixel[23:16],pixel[15:8],pixel[7:0]);
                        end
                    end
                end
                if(file) $fclose(file);
                if(l>0 && changes==0) $fatal(1,"empty progress step");
                if(s!=5 && (count<l*9600-20000 || count>l*9600+20000)) $fatal(1,"nonuniform dissolve density");
            end
            // Keep the selected coordinate stable as a paused transition would.
            @(negedge clk);level=16;x=117;y=205;repeat(8) @(negedge clk);
            pipe_expected=masks;repeat(20) begin @(negedge clk);if(masks!==pipe_expected) $fatal(1,"paused effect not deterministic");end
            active=0;repeat(5) @(negedge clk);if(masks!==0) $fatal(1,"inactive mask");active=1;
        end
        @(negedge clk);rst=1;#1;if(masks!==0) $fatal(1,"mask reset");
        $display("PASS new effects: every pixel at 33 levels, endpoints, monotonicity, 16x16 blocks, density, clockwise quadrants, five-stage raster, pause, disable/reset");
        $finish;
    end
    initial begin #500000000;$fatal(1,"new effect timeout");end
endmodule

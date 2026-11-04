`timescale 1ns/1ps
module tb_effects_pixels;
    reg clk=0,rst=1,hs=1,vs=1,de=0,panel=0,edit=0,directory=0,alarm=0,mask_active=0;
    reg [23:0] rgb=0;reg [2:0] menu=0,style=0;reg [5:0] level=0;
    wire oh,ov,od;wire [23:0] out;
    wire [3:0] modes={edit,2'b01,1'b0};
    integer mode,row,col,j,n,file,count,blend_pixels;
    reg [23:0] pixels[0:4];reg [9:0] xx[0:4];reg [8:0] yy[0:4];
    reg [4:0] ds,hsq,vsq;reg [23:0] expected,base;reg covered,is_border;
    reg [9:0] mx=0;reg [8:0] my=0;wire [4:0] masks;reg [4:0] masks_ref=0;
    integer s,l,p;
    always #5 clk=~clk;
    player_image_mask mask_unit(.clk(clk),.rst(rst),.x(mx),.y(my),.active(mask_active),.style(style),.level(level),.mask_pipe(masks));
    player_video #(.UI_ENABLE(1),.PANEL_ALPHA_ENABLE(1),.IMAGE_EFFECTS_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .brightness(9'sd0),.contrast(9'd128),.gain(9'd256),.display_valid(1'b1),
        .picture(3'd2),.scaled(1'b1),.auto_play(1'b1),.error_code(8'd0),.state_code(4'd0),
        .volume(4'd8),.interval_seconds(4'd3),.transition_mode(4'd0),.menu(menu),.modes(modes),
        .audio_valid(1'b0),.audio_sample(24'd0),.out_hs(oh),.out_vs(ov),.out_de(od),.out_rgb(out),
        .debug_status(60'd0),.audio_status(8'd1),.image_valid(1'b1),
        .ui_alarm(alarm),.ui_status(panel),.ui_directory(directory),.ui_browse(1'b0),
        .run_mode(2'd2),.source_resolution(40'h0192001440),
        .effect_mask_active(mask_active),.effect_mask_style(style),.effect_mask_level(level));
    function mask_reference;input integer x,y,kind,amount;begin
        case(kind)
            1:mask_reference=x<amount*20;
            2:mask_reference=x<amount*10 || x>=640-amount*10;
            3:mask_reference=y%64<amount*2;
            default:mask_reference=0;
        endcase
    end endfunction
    function [23:0] background;input integer x,y;begin background={x[7:0],y[7:0],x[7:0]^y[7:0]};end endfunction
    function [23:0] blend;input [23:0] a,b;integer r,g,bl;begin
        r=(a[23:16]+b[23:16])/2;g=(a[15:8]+b[15:8])/2;bl=(a[7:0]+b[7:0])/2;
        blend={r[7:0],g[7:0],bl[7:0]};
    end endfunction
    task raster;input integer kind;begin
        panel=kind==0 || kind==1 || kind==2 || kind==3 || kind==7 || kind==8 || kind==9;
        edit=kind==1 || kind==2 || kind==3;menu=kind-1;directory=kind==7;alarm=kind==8;
        mask_active=kind>=4 && kind<=6 || kind==9;style=kind==9 ? 2 : kind-3;level=16;
        de=0;vs=0;hs=1;repeat(10) @(negedge clk);vs=1;repeat(10) @(negedge clk);
        ds=0;hsq=5'b11111;vsq=5'b11111;for(j=0;j<5;j=j+1) begin pixels[j]=0;xx[j]=0;yy[j]=0;end
        count=0;blend_pixels=0;file=0;
        if(kind==1) file=$fopen("../doc/validation/status_translucent.ppm","wb");
        if(kind==4) file=$fopen("../doc/validation/transition_wipe.ppm","wb");
        if(kind==5) file=$fopen("../doc/validation/transition_curtain.ppm","wb");
        if(kind==6) file=$fopen("../doc/validation/transition_blinds.ppm","wb");
        if(file) $fwrite(file,"P6\n640 480\n255\n");
        for(row=0;row<480;row=row+1) for(col=0;col<650;col=col+1) begin
            @(negedge clk);de=col<640;hs=!(col>=642 && col<646);rgb=background(col,row);
            base=alarm || (mask_active && mask_reference(col,row,style,level)) ? 0 : rgb;
            @(posedge clk);
            for(j=4;j>0;j=j-1) begin pixels[j]=pixels[j-1];xx[j]=xx[j-1];yy[j]=yy[j-1];end
            pixels[0]=base;xx[0]=col;yy[0]=row;ds={ds[3:0],de};hsq={hsq[3:0],hs};vsq={vsq[3:0],vs};
            #1;expected=pixels[4];
            covered=!directory && !alarm && yy[4]<24;
            if(covered) begin
                // Independently check the 50% header against the aligned image,
                // including masked black pixels. Glyphs/divider stay opaque.
                expected=yy[4]==23 ? 24'h404848 : blend(24'h606060,pixels[4]);
                if(dut.chinese_osd.status.hit4) expected=dut.chinese_osd.status.inks[4];
            end
            if((panel || edit) && !directory && !alarm && xx[4]>=160 && xx[4]<480 && yy[4]>=128 && yy[4]<352) begin
                base=24'h606060;
                is_border=xx[4]==160 || xx[4]==479 || yy[4]==128 || yy[4]==351 ||
                     (yy[4]==167 && xx[4]>=176 && xx[4]<464);
                if(is_border) base=24'hc0c8c8;
                if(edit && xx[4]>=176 && xx[4]<464 && yy[4]>=174+20*menu && yy[4]<194+20*menu) base=24'ha5dfd9;
                expected=is_border ? base : blend(base,pixels[4]);
                if(dut.chinese_osd.status.hit4) expected=dut.chinese_osd.status.inks[4];
                else if(!is_border) blend_pixels=blend_pixels+1;
            end
            if(!ds[4]) expected=0;
            if(out!==expected || od!==ds[4] || oh!==hsq[4] || ov!==vsq[4])
                $fatal(1,"effects pixel kind=%0d x=%0d y=%0d got=%h expected=%h",kind,xx[4],yy[4],out,expected);
            if(od) begin count=count+1;if(file) $fwrite(file,"%c%c%c",out[23:16],out[15:8],out[7:0]);end
        end
        if(file) $fclose(file);if(count!=640*480) $fatal(1,"missing raster");
        if(panel && !alarm && !directory && blend_pixels<60000) $fatal(1,"missing transparency");
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;mask_active=1;
        // All progress levels and every horizontal/vertical coordinate, not just a screenshot.
        for(s=1;s<=3;s=s+1) for(l=0;l<=32;l=l+1) for(p=0;p<640;p=p+1) begin
            @(negedge clk);style=s;level=l;mx=p;my=p%480;
            @(posedge clk);masks_ref={masks_ref[3:0],mask_reference(p,p%480,s,l)};#1;
            if(masks!==masks_ref) $fatal(1,"spatial mask kind=%0d progress=%0d coordinate=%0d",s,l,p);
        end
        for(mode=0;mode<10;mode=mode+1) raster(mode);
        $display("PASS effects pixels: 33 levels all masks, five-stage alignment, translucent header/panel/20px cursors, opaque glyphs/frame/divider, directory/alarm priority, masks under OSD");$finish;
    end
    initial begin #100000000;$fatal(1,"effects pixel timeout");end
endmodule

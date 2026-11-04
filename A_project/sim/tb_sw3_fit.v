`timescale 1ns/1ps
module tb_sw3_fit #(parameter OW=32,OH=24,NATIVE=0);
    reg fit=0,transaction_fit=0;
    reg outside;
    integer black_count,lit_count;
    reg [23:0] reference[0:OW*OH-1];
    reg compare_orientation=0;
    reg clk=0,rst=1,start=0,valid=0,finish=0,ready=0;
    reg [7:0] data=0,upstream=0;
    reg [31:0] size=0,offset=0;
    wire room,pv,commit,done,accepted,top,scaled;
    wire [23:0] rgb;
    wire [15:0] x,y;
    wire [7:0] error;
    wire [59:0] detail;
    integer w,h,stride,negative,cw,ch,cx,cy,count=0,cases=0,i,j,mode=0,pixoff;
    integer x0,x1,y0,y1,wx,wy,k,expected,got,ha,hb;
    reg [7:0] hdr[0:69];
    reg [15:0] random_state=16'hbeef;
    reg seen[0:OW*OH-1];
    reg signed [63:0] dx,dy,px,py;
    always #5 clk=~clk;
    always @(negedge clk) begin
        random_state={random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
        ready=random_state[2:0]!=0;
    end
    bmp_bilinear #(.WIDTH(OW),.HEIGHT(OH),.MODE_576(0),.FIT_MODE_ENABLE(1)) dut(
        .fit_mode(fit),
        .clk(clk),.rst_n(!rst),.file_start(start),.file_size(size),.file_valid(valid),
        .file_byte(data),.file_byte_offset(offset),.file_end(finish),.upstream_error(upstream),
        .pixel_ready(ready),.sector_room(room),.header_accepted(accepted),.pixel_valid(pv),
        .pixel_rgb(rgb),.pixel_x(x),.pixel_y(y),.frame_commit(commit),.bmp_done(done),
        .bmp_error(error),.top_down(top),.scaled(scaled),.error_detail(detail));
    function integer color;
        input integer a,b,c;
        begin
            case(c)
                0:color=(a*a+7*b+31)&255;
                1:color=(a*13+b*b+73)&255;
                2:color=(a*3+b*19+a*b+127)&255;
            endcase
        end
    endfunction
    function [7:0] file_byte;
        input integer p;
        integer row,col,comp;
        begin
            if(p<pixoff) file_byte=hdr[p];
            else if((p-pixoff)%stride>=w*3) file_byte=8'hde;
            else begin
                row=(p-pixoff)/stride;col=((p-pixoff)%stride)/3;comp=((p-pixoff)%stride)%3;
                file_byte=color(col,negative ? row : h-1-row,2-comp);
            end
        end
    endfunction
    always @(posedge clk) if(!rst && pv) begin
        if(x>=OW || y>=OH || seen[y*OW+x]) $fatal(1,"coordinate/repeated pixel %0d,%0d",x,y);
        seen[y*OW+x]=1;
        if(mode==0) begin
            px=((w-1)*65536-(OW-1)*dx)>>>1;px=px+x*dx;
            py=((h-1)*65536-(OH-1)*dy)>>>1;py=py+y*dy;
            outside=transaction_fit && (px < -32768 || px >= w*65536-32768 || py < -32768 || py >= h*65536-32768);
            if(outside) black_count=black_count+1;else lit_count=lit_count+1;
            if(px<cx*65536) px=cx*65536;
            if(px>(cx+cw-1)*65536) px=(cx+cw-1)*65536;
            if(py<cy*65536) py=cy*65536;
            if(py>(cy+ch-1)*65536) py=(cy+ch-1)*65536;
            x0=px>>16;y0=py>>16;x1=x0+1<cx+cw ? x0+1 : x0;y1=y0+1<cy+ch ? y0+1 : y0;
            wx=(px>>8)&255;wy=(py>>8)&255;
            for(k=0;k<3;k=k+1) begin
                ha=color(x0,y0,k)*(256-wx)+color(x1,y0,k)*wx;
                hb=color(x0,y1,k)*(256-wx)+color(x1,y1,k)*wx;
                expected=(ha*(256-wy)+hb*wy+32768)>>16;if(outside) expected=0;got=(rgb>>((2-k)*8))&255;
                if(got!==expected) $fatal(1,"bilinear %0dx%0d top=%0d xy=%0d,%0d channel=%0d expected=%0d got=%0d",w,h,negative,x,y,k,expected,got);
            end
        end
        if(compare_orientation && rgb!==reference[y*OW+x]) $fatal(1,"top/down mismatch at %0d,%0d",x,y);
        reference[y*OW+x]=rgb;
        count=count+1;
    end
    task u32;
        input integer p,v;
        begin hdr[p]=v;hdr[p+1]=v>>8;hdr[p+2]=v>>16;hdr[p+3]=v>>24;end
    endtask
    task run;
        input integer iw,ih,itop,imode;
        input [7:0] expected_error;
        begin
            w=iw;h=ih;negative=itop;mode=imode;stride=((w*3+3)/4)*4;
            pixoff=itop ? 70 : 54;size=pixoff+stride*h;
            for(i=0;i<70;i=i+1) hdr[i]=0;
            hdr[0]="B";hdr[1]="M";u32(2,size);u32(10,pixoff);u32(14,40);
            u32(18,w);u32(22,negative ? -h : h);hdr[26]=1;hdr[28]=24;
            cw=w;ch=h;cx=0;cy=0;
            transaction_fit=fit;
            dx=((w*OH>h*OW)^transaction_fit) ? h*65536/OH : w*65536/OW;dy=dx;
            if(mode==1) u32(2,size-1);
            if(mode==4) u32(18,16385);
            if(mode==5) u32(18,0);
            if(mode==6) hdr[28]=32;
            if(mode==7) u32(30,1);
            if(mode==8) hdr[0]="X";
            upstream=mode==9 ? 8'h24 : 0;
            @(negedge clk);start=1;count=0;black_count=0;lit_count=0;
            for(i=0;i<OW*OH;i=i+1) seen[i]=0;
            @(negedge clk);start=0;
            for(j=0;j<size-(mode==2 ? 1 : 0);j=j+1) begin
                if(j%512==0) begin valid=0;while(!room) @(negedge clk);end
                if(j==54) fit=!transaction_fit; // A mid-file switch must not alter this frame.
                valid=1;data=file_byte(j);offset=j+(mode==3 && j==size-10 ? 1 : 0);
                finish=j==size-(mode==2 ? 2 : 1);@(negedge clk);
            end
            valid=0;finish=0;
            wait(done);@(negedge clk);
            if(error) $display("debug row%0d hx%0d out%0d crop%0d,%0d,%0d,%0d step%0d,%0d pos%0d,%0d tags%0d,%0d",dut.source_row,dut.hx,dut.out_y,dut.crop_x,dut.crop_y,dut.crop_w,dut.crop_h,dut.step_x,dut.step_y,dut.pos_x,dut.pos_y,dut.tag0,dut.tag1);
            if(error!==expected_error || commit!==(expected_error==0)) $fatal(1,"mode%0d completion E%h expected%h commit%b detail%h",mode,error,expected_error,commit,detail);
            if(mode==0 && (count!=OW*OH || top!==itop[0] || scaled!==(w!=OW || h!=OH)))
                $fatal(1,"frame count/metadata");
            if(mode==0) for(i=0;i<OW*OH;i=i+1) if(!seen[i]) $fatal(1,"missing pixel %0d",i);
            $display("checked %0dx%0d -> %0dx%0d top=%0d mode=%0d pixels=%0d time=%0t",w,h,OW,OH,negative,mode,count,$time);
            if(lit_count==0 || (!transaction_fit && black_count!=0)) $fatal(1,"empty picture/cover bars");
            if(transaction_fit && w*OH!=h*OW && black_count==0) $fatal(1,"contain missing bars");
            fit=transaction_fit;cases=cases+1;repeat(3) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        if(NATIVE) begin
            fit=1;run(640,960,0,0,0);
        end else for(integer f=0;f<2;f=f+1) begin
            fit=f;
            for(integer shape=0;shape<7;shape=shape+1) begin
                case(shape)
                    0:begin cw=64;ch=24;end // wide, downscale
                    1:begin cw=16;ch=48;end // portrait, downscale
                    2:begin cw=7;ch=3;end   // odd wide, enlarge
                    3:begin cw=3;ch=7;end   // odd tall, enlarge
                    4:begin cw=32;ch=24;end // exact native aspect
                    5:begin cw=1;ch=1;end
                    6:begin cw=1;ch=9;end
                endcase
                compare_orientation=0;run(cw,ch,1,0,0);
                compare_orientation=1;run(w,h,0,0,0);
            end
        end
        $display("PASS SW3 fit: %0d frames, every RGB pixel checked against common-scale oracle, complete centered black bars, both BMP orientations identical, backpressure, mode frozen per file",cases);$finish;
    end
    initial begin #(64'd3000000000);$fatal(1,"bilinear timeout state%0d used%0d row%0d output%0d",dut.state,dut.used,dut.source_row,dut.out_y);end
endmodule

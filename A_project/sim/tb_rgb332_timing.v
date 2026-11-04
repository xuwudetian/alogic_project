`timescale 1ns/1fs
module tb_rgb332_timing;
    reg clk=0,rst=1,ack=0;wire req,hs,vs,de,toggle;
    integer frame,n,pixels,hs_low,vs_low,rows,width,requests,last_request;
    reg old_de,old_req,old_toggle;real start_time;
    always #7.6923075 clk=~clk;
    player_xga_native_timing dut(clk,rst,ack,req,hs,vs,de,toggle);
    always @(posedge clk) if(rst) ack<=0;else ack<=req;
    initial begin
        repeat(5) @(negedge clk);rst=0;
        old_toggle=toggle;wait(toggle!=old_toggle);@(negedge clk);
        for(frame=0;frame<2;frame=frame+1) begin
            pixels=0;hs_low=0;vs_low=0;rows=0;width=0;requests=0;old_de=0;old_req=0;start_time=$realtime;
            for(n=0;n<1083264;n=n+1) begin
                if(de) begin pixels=pixels+1;width=width+1;end
                if(!hs) hs_low=hs_low+1;if(!vs) vs_low=vs_low+1;
                if(old_de && !de) begin
                    if(width!=1024) $fatal(1,"XGA active width %0d",width);
                    width=0;rows=rows+1;
                end
                if(req && !old_req) begin
                    requests=requests+1;if(n<31 || n>34) $fatal(1,"frame metadata guard %0d",n);
                end
                old_de=de;old_req=req;@(negedge clk);
            end
            if(pixels!=786432 || rows!=768 || hs_low!=109616 || vs_low!=8064 || requests!=1)
                $fatal(1,"XGA totals %0d %0d %0d %0d requests%0d",pixels,rows,hs_low,vs_low,requests);
            if(($realtime-start_time)<16665400 || ($realtime-start_time)>16666000) $fatal(1,"XGA frame period");
        end
        $display("PASS native XGA raster: two complete 1344x806 frames at 65MHz, 1024x768 active pixels, HS136/VS6, metadata guard and request/ACK");$finish;
    end
    initial begin #55000000;$fatal(1,"timing timeout");end
endmodule

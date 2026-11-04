`timescale 1ns/1ps
module tb_rgb332_spectrum;
reg clk=0,rst=1,vs=1,av=0;
reg hs=1,de=0,enable=1,alarm=0;
reg [23:0] base=24'h123456;
reg [9:0] probe_y;
reg [3:0] probe_phase;
reg [23:0] palette,expected;
integer band,value,r,g,b;
reg signed [23:0] sample=0;
wire ho,vo,deo;
wire [23:0] rgb;
integer n,i,peak,maximum,oldlevel;
always #7.6923075 clk=~clk;
audio_spectrum_overlay #(.MODE_XGA(1)) dut(clk,rst,enable,hs,vs,de,base,av,sample,ho,vo,deo,rgb,alarm,24'd0,1'b0);
task check_pixel;
input [23:0] wanted;
begin
    @(posedge clk);#1;
    if({ho,vo,deo}!=={hs,vs,de} || rgb!==wanted)
        $fatal(1,"spectrum pixel expected=%h got=%h alarm=%b enable=%b x=%d y=%d phase=%d init=%b commit=%b addr=%d height=%d hit=%b panel=%b bottom=%d",wanted,rgb,alarm,enable,dut.x,dut.y,dut.bar_phase,dut.init_busy,dut.commit_busy,dut.height_address,dut.display_height,dut.bar_hit,dut.in_panel,dut.from_bottom);
    @(negedge clk);
end
endtask
task feed;
input integer bin;
begin
    wait(dut.state==2);
    for(n=0;n<512;n=n+1) begin
        @(negedge clk);
        sample=bin==0 ? 0 : $rtoi(3600000.0*$sin(6.283185307179586*bin*n/512));av=1;
        @(negedge clk);av=0;
        repeat(519) @(negedge clk);
    end
    wait(dut.state==4);
    @(negedge clk);
end
endtask
task commit;
begin
    vs=0;repeat(140) @(negedge clk);vs=1;repeat(3) @(negedge clk);
end
endtask
initial begin
    repeat(10) @(negedge clk);rst=0;
    // Initialization is serial; external pixels keep the original 20 px floor.
    force dut.x=10'd9;force dut.y=10'd470;
    force dut.bar_index=6'd0;force dut.bar_phase=4'd1;
    de=1;alarm=1;check_pixel(24'hff2020);
    release dut.x;release dut.y;release dut.bar_index;release dut.bar_phase;
    de=0;alarm=0;repeat(64) @(negedge clk);
    for(i=0;i<64;i=i+1)
        if(dut.displayed[i]!==6'd10) $fatal(1,"initial 20px spectrum floor missing");
    // Verify one-cycle 50% RGB blending, all channel values and all gradient bands.
    force dut.x=10'd9;force dut.y=probe_y;
    force dut.bar_index=6'd0;force dut.bar_phase=probe_phase;
    dut.displayed[0]=63;probe_phase=1;de=1;
    for(band=0;band<8;band=band+1) begin
        probe_y=475-band*16;
        case(band)
            0:palette=24'h2088c0;1:palette=24'h2498c4;2:palette=24'h28a8c4;
            3:palette=24'h30b4bc;4:palette=24'h38beb0;5:palette=24'h40c4a0;
            6:palette=24'h50c890;7:palette=24'h68cc88;
        endcase
        for(value=0;value<256;value=value+1) begin
            base={value[7:0],~value[7:0],value[7:0]^8'h55};hs=value[0];
            r=base[23:16]+palette[23:16];g=base[15:8]+palette[15:8];b=base[7:0]+palette[7:0];
            expected={r[8:1],g[8:1],b[8:1]};check_pixel(expected);
        end
        base=24'h000000;check_pixel({1'b0,palette[23:17],1'b0,palette[15:9],1'b0,palette[7:1]});
        base=24'hffffff;r=255+palette[23:16];g=255+palette[15:8];b=255+palette[7:0];
        check_pixel({r[8:1],g[8:1],b[8:1]});
        alarm=1;check_pixel(24'hff2020);
        enable=0;check_pixel(base);alarm=0;check_pixel(base);enable=1;
        probe_phase=0;check_pixel(base);probe_phase=8;check_pixel(base);probe_phase=1;
    end
    probe_y=476;check_pixel(base);probe_y=351;check_pixel(base);
    probe_y=470;de=0;check_pixel(base);
    release dut.x;release dut.y;release dut.bar_index;release dut.bar_phase;
    // Restore the capture initial state before exercising the real FFT path.
    rst=1;repeat(3) @(negedge clk);rst=0;hs=1;base=24'h123456;
    feed(17);
    peak=0;maximum=0;
    for(i=0;i<64;i=i+1) begin
        if(dut.pending[i]>maximum) begin maximum=dut.pending[i];peak=i;end
        if(dut.displayed[i]!=10) $fatal(1,"partial frame published");
    end
    if(peak!=16 || maximum<10) $fatal(1,"wrong tone band %0d half-height %0d",peak,maximum);
    commit;
    if(dut.displayed[16]!=maximum) $fatal(1,"frame commit failed");
    oldlevel=maximum;
    feed(60);
    peak=0;maximum=0;
    for(i=0;i<64;i=i+1)
        if(dut.pending[i]>maximum) begin maximum=dut.pending[i];peak=i;end
    if(peak!=59) $fatal(1,"second frame wrong band %0d",peak);
    if(dut.displayed[16]!=oldlevel) $fatal(1,"display changed mid-frame");
    commit;
    feed(105);
    for(i=0;i<64;i=i+1)
        if(dut.pending[i]>10) $fatal(1,"out of range tone folded into visible bands");
    commit;
    feed(0);
    for(i=0;i<64;i=i+1)
        if(dut.pending[i]!=0) $fatal(1,"silence leaves stale spectrum");
    commit;
    repeat(32) commit;
    for(i=0;i<64;i=i+1)
        if(dut.displayed[i]!==6'd10) $fatal(1,"silence 20px decay floor missing");
    $display("PASS native65MHz two-cycle spectrum: exact half-alpha RGB, gradient, opaque alarm, passthrough/sync, two tone bands, restart, silence, atomic frame commit");
    $finish;
end
initial begin #80000000;$fatal(1,"timeout");end
endmodule

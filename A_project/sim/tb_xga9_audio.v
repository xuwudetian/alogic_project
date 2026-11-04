`timescale 1ns/1ps
module tb_xga9_audio;
reg c=0,p=0,r=1;
always #7.6923075 p=~p;
always @(posedge p)c<=~c;
wire valid,acr,out_valid,out_acr;
wire [23:0] pcm,out_pcm;
wire [19:0] cts,n;
player_audio #(.CLK_HZ(32500000)) source(.clk(c),.rst(r),.picture(4'd8),.volume(4'd8),.mute(1'b0),
 .valid(valid),.left(pcm),.right(),.acr_valid(acr),.acr_cts(cts),.acr_n(n));
player_xga_audio bridge(c,r,valid,pcm,p,r,out_valid,out_pcm,out_acr);
integer sent=0,received=0,clocks=0,acrs=0;
reg [23:0] expected[0:1023];
always @(posedge c) if(!r) begin
 clocks=clocks+1;
 if(valid) begin expected[sent]=pcm;sent=sent+1;end
end
always @(negedge p) if(!r && out_valid) begin
 if(received>=sent || out_pcm!==expected[received])$fatal(1,"audio missing/reordered/corrupt");
 if(out_acr!==(received%128==0))$fatal(1,"ACR cadence");
 received=received+1;
 if(received==480) begin
  if(clocks<325000 || clocks>325004)$fatal(1,"48kHz sample rate clocks=%d",clocks);
  $display("PASS XGA audio CDC: 480 samples in 10 ms, exact PCM, 128-sample ACR cadence");$finish;
 end
end
initial begin #201;r=0;#12000000;$fatal(1,"timeout");end
endmodule

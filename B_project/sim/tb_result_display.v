`timescale 1ns/1ps
module tb_result_display;
 reg clk=0,video_clk=0,rst_n=0,video_rst_n=0,result_done=0,frame_commit=0;
 reg [1:0] result_class=0;
 wire display_valid;wire [1:0] display_class;
 always #10 clk=~clk;
 always #17 video_clk=~video_clk;
 damage_result_display dut(clk,rst_n,result_done,result_class,video_clk,video_rst_n,frame_commit,display_valid,display_class);
 task result;
   input [1:0] value;
   begin
     @(negedge clk);result_done=1;result_class=value;
     @(negedge clk);result_done=0;
   end
 endtask
 task commit;
   begin
     repeat(12) @(negedge video_clk);
     frame_commit=1;@(negedge video_clk);frame_commit=0;
   end
 endtask
 integer i;
 reg [1:0] old_display=0;
 reg old_valid=0;
 reg [1:0] saved_payload;
 reg saved_token;
 always @(posedge video_clk) begin
   if(video_rst_n) begin
     if(!frame_commit) begin
       old_display=display_class;old_valid=display_valid;
       #1;
       if(display_class!==old_display || display_valid!==old_valid) $fatal(1,"Mid-frame result changed");
     end
   end
 end
 initial begin
   #100;rst_n=1;video_rst_n=1;
   result(1);result(1);commit;
   if(display_valid) $fatal(1,"Initial result accepted without 3 confirmations");
   result(1);commit;
   if(!display_valid || display_class!=1) $fatal(1,"Initial confirmation failed");
   for(i=0;i<20;i=i+1) begin result(2);result(0);end
   commit;
   if(display_class!=1) $fatal(1,"Alternating noise changed display");
   result(2);result(2);result(3);result(2);commit;
   if(display_class!=1) $fatal(1,"Invalid class did not break confirmation");
   result(2);result(2);
   repeat(20) @(negedge clk);
   if(display_class!=1) $fatal(1,"Display updated before blanking");
   commit;
   if(display_class!=2) $fatal(1,"Damage transition failed");
   // Freeze destination acknowledgement, then attempt rapid source changes.
   saved_token=dut.acknowledge;
   force dut.acknowledge=saved_token;
   result(0);result(0);result(0);
   repeat(8) @(negedge clk);
   saved_payload=dut.published_class;
   result(1);result(1);result(1);
   repeat(8) @(negedge clk);
   if(dut.published_class!==saved_payload) $fatal(1,"Unacknowledged payload overwritten");
   release dut.acknowledge;
   commit;commit;
   if(display_class!=1) $fatal(1,"Latest confirmed result lost under backpressure");
   result(0);result(0);result(0);commit;
   if(display_class!=0) $fatal(1,"No-vehicle transition failed");
   rst_n=0;video_rst_n=0;#40;
   if(display_valid || display_class!=0) $fatal(1,"Reset left stale result");
   $display("PASS RESULT_DISPLAY: three confirmations, alternating/invalid rejection, held CDC payload, frame-only update and reset");
   $finish;
 end
 initial begin #100000;$fatal(1,"result display timeout");end
endmodule

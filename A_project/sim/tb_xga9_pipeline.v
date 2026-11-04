`timescale 1ns/1ps
module tb_xga9_pipeline;
reg clk=0;
always #10 clk=~clk;
tri1 scl,sda,mdio;
top #(.BOOT_HOLD_CYCLES(100)) dut(.clk(clk),.rst_n(1'b1),.key1(1'b1),.key2(1'b1),.key3(1'b1),
 .sw(4'b1000),.sd_miso(1'b1),.sensor_scl(scl),.sensor_sda(sda),
 .eth_rx_clk(1'b0),.eth_rx_ctl(1'b0),.eth_rxd(4'd0),.eth_mdio(mdio));
integer tags[0:2047];integer x=0,y=0,wy=0,pixels=0,i;
reg ld=0,lv=0,od=0;
initial for(i=0;i<2048;i=i+1)tags[i]=-1;
always @(posedge dut.video_clk) if(!dut.rst_video)begin
 if(lv&&!dut.ui_vs)wy=0;
 if(dut.ui_de)tags[{dut.output_scaler.write_bank,dut.output_scaler.wx}]=wy;
 if(ld&&!dut.ui_de)wy=wy+1;
 ld=dut.ui_de;lv=dut.ui_vs;
end
always @(posedge dut.pixel_clk) if(!dut.rst_pixel && dut.output_scaler.active)begin
 if(tags[{dut.output_scaler.read_bank,dut.output_scaler.sx}]!==y*5/8)
   $fatal(1,"scene row not ready/overwritten x=%d y=%d tag=%d",x,y,tags[{dut.output_scaler.read_bank,dut.output_scaler.sx}]);
end
always @(negedge dut.pixel_clk) if(!dut.rst_pixel)begin
 if(dut.xga_de)begin x=x+1;pixels=pixels+1;end
 if(od&&!dut.xga_de)begin
  if(x!=1024)$fatal(1,"pipeline line");x=0;y=y+1;
  if(y==768)begin
   if(pixels!=786432 || wy!=480)$fatal(1,"pipeline frame");
   $display("PASS actual top scene->two row cache->XGA: every output read has the correct completed source row, 786432 pixels");$finish;
  end
 end
 od=dut.xga_de;
end
initial begin #20000000;$fatal(1,"pipeline timeout");end
endmodule

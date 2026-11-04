`timescale 1ns/1ps
// Clause 22 management, PHY address 1 (HX4S20 schematic straps).
// Direct A/B mode: fixed 100BASE-TX full duplex, hardware auto-crossover off.
// A uses MDI; B starts MDIX and tries the other wiring after 75 failed polls.
// RTL8211E datasheet 7.12, 8.4.1, 8.4.15: auto-crossover otherwise forces AN;
// changing PHYCR needs reset, and BMCR defaults must then be overwritten.
// DIRECT_LINK=0 retains the original switch-compatible auto-negotiation mode.
module net_mdio #(parameter IS_B=0,DIRECT_LINK=1,HALF_CYCLES=25,
 BOOT_CYCLES=5000000,POLL_CYCLES=DIRECT_LINK?500000:5000000,POLARITY_POLLS=75)(
 input clk,input rst,output reg mdc,inout mdio,output reg link_ok);
 localparam D_BITS=HALF_CYCLES>1?$clog2(HALF_CYCLES):1;
 localparam W_BITS=$clog2(BOOT_CYCLES>POLL_CYCLES?BOOT_CYCLES+1:POLL_CYCLES+1);
 reg [D_BITS-1:0] divider;
 reg [W_BITS-1:0] wait_count;
 reg busy,reading,ta_ok;
 reg [3:0] step;
 localparam P_BITS=POLARITY_POLLS>1?$clog2(POLARITY_POLLS):1;
 reg [P_BITS-1:0] down_polls;
 reg crossover;
 reg [5:0] bit_index;
 reg [31:0] command;
 reg [15:0] read_value;
 (* async_reg="true" *) reg [1:0] mdio_sync;
 always @(posedge clk or posedge rst)
  if(rst) mdio_sync<=3;else mdio_sync<={mdio_sync[0],mdio};
 wire drive=busy && !(reading && bit_index>=46);
 wire bit_out=bit_index<32 ? 1'b1 : command[63-bit_index];
 wire direct_read=step==1 || step==4 || step==6 || step==7 || step==8;
 wire status_good=ta_ok && read_value[15:14]==2'b01 && read_value[13] && read_value[10];
 assign mdio=drive ? bit_out : 1'bz;
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   mdc<=0;divider<=0;wait_count<=BOOT_CYCLES;busy<=0;reading<=0;
   step<=0;bit_index<=0;command<=0;read_value<=0;ta_ok<=0;link_ok<=0;
   down_polls<=0;crossover<=IS_B!=0;
  end else if(!busy) begin
   mdc<=0;divider<=0;
   if(wait_count!=0) wait_count<=wait_count-1'b1;
   else begin
    busy<=1;bit_index<=0;reading<=DIRECT_LINK?direct_read:step==4;read_value<=0;ta_ok<=0;
    if(DIRECT_LINK) case(step)
     0:command<={2'b01,2'b01,5'd1,5'd31,2'b10,16'h0000};
     1:command<={2'b01,2'b10,5'd1,5'd16,2'b00,16'h0000};
     // Preserve reserved fields; never use Force Link Good to fake readiness.
     2:command<={2'b01,2'b01,5'd1,5'd16,2'b10,
                 (read_value & 16'hfb9f) | (crossover?16'h0020:16'h0000)};
     3:command<={2'b01,2'b01,5'd1,5'd0,2'b10,16'h8000};
     4:command<={2'b01,2'b10,5'd1,5'd0,2'b00,16'h0000};
     // Reset restores BMCR defaults. RESTART latches 100/full/ANE=0 after
     // reset completes; with auto-crossover disabled no AN handshake is used.
     5:command<={2'b01,2'b01,5'd1,5'd0,2'b10,16'h2300};
     6:command<={2'b01,2'b10,5'd1,5'd0,2'b00,16'h0000};
     7:command<={2'b01,2'b10,5'd1,5'd16,2'b00,16'h0000};
     default:command<={2'b01,2'b10,5'd1,5'd17,2'b00,16'h0000};
    endcase else case(step)
     0:command<={2'b01,2'b01,5'd1,5'd31,2'b10,16'h0000};
     1:command<={2'b01,2'b01,5'd1,5'd9, 2'b10,16'h0000};
     2:command<={2'b01,2'b01,5'd1,5'd4, 2'b10,16'h0101};
     3:command<={2'b01,2'b01,5'd1,5'd0, 2'b10,16'h1200};
     default:command<={2'b01,2'b10,5'd1,5'd17,2'b00,16'h0000};
    endcase
   end
  end else if(divider==HALF_CYCLES-1) begin
   divider<=0;mdc<=~mdc;
   if(!mdc) begin
    if(reading && bit_index==47) ta_ok<=!mdio_sync[1];
    if(reading && bit_index>=48) read_value<={read_value[14:0],mdio_sync[1]};
   end else if(bit_index==63) begin
    busy<=0;
    if(DIRECT_LINK) begin
     wait_count<=100;
     case(step)
      0,2,3,5:step<=step+1'b1;
      1:if(ta_ok) step<=2;else wait_count<=POLL_CYCLES;
      4:if(ta_ok && !read_value[15]) step<=5;else wait_count<=POLL_CYCLES;
      6:begin
       if(!ta_ok || read_value[15] || read_value[9]) wait_count<=POLL_CYCLES;
       else if((read_value & 16'h7f40)==16'h2100) step<=7;
       else step<=5;
      end
      7:begin
       if(!ta_ok) wait_count<=POLL_CYCLES;
       else if((read_value & 16'h0460)==(crossover?16'h0020:16'h0000)) step<=8;
       else step<=1;
      end
      default:begin
       // Forced mode does not wait for AN's "resolved" bit 11.
       link_ok<=status_good;wait_count<=POLL_CYCLES;
       if(status_good || !ta_ok) down_polls<=0;
       else if(IS_B) begin
        if(down_polls==POLARITY_POLLS-1) begin
         crossover<=~crossover;down_polls<=0;step<=1;
        end else down_polls<=down_polls+1'b1;
       end
      end
     endcase
    end else if(step<4) begin step<=step+1'b1;wait_count<=100;end
    else begin
     link_ok<=status_good && read_value[11];
     wait_count<=POLL_CYCLES;
    end
   end else bit_index<=bit_index+1'b1;
  end else divider<=divider+1'b1;
 end
endmodule

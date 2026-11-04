`timescale 1ns/1ps
// Narrow, fixed-peer IPv4/UDP endpoint, not a general-purpose network stack.
// Ethernet frame = 14+20+8+16+2 pad+4 FCS = 64 bytes. No buffers/BRAM/DSP.
// Peer MAC/IP/port, all IP fields (including checksum), UDP length, zero UDP
// checksum, magic/version/type/reserved bytes and Ethernet FCS are checked.
module net_frame_byte #(parameter IS_B=0)(input [5:0] index,output reg [7:0] value);
 always @* begin
  value=0;
  case(index)
   0,6:value=8'h02;
   5:value=IS_B?8'h0a:8'h0b;
   11:value=IS_B?8'h0b:8'h0a;
   12:value=8'h08;
   14:value=8'h45;
   17:value=8'h2c;
   20,22:value=8'h40;
   23:value=8'h11;
   24:value=8'hd9;25:value=8'h6b;
   26,30:value=8'hc0;
   27,31:value=8'ha8;
   28,32:value=8'hf0;
   29:value=IS_B?2:1;
   33:value=IS_B?1:2;
   34,36:value=8'h0f;
   35:value=IS_B?8'ha1:8'ha0;
   37:value=IS_B?8'ha0:8'ha1;
   39:value=8'h18;
   42:value=8'h52;43:value=8'h44;44:value=8'h45;45:value=8'h4d;
   46:value=1;47:value=IS_B?1:2;
   default:value=0;
  endcase
 end
endmodule

module net_udp_mac #(parameter IS_B=0)(
 input tx_clk,input rx_clk,input tx_rst,input rx_rst,input enabled,
 input send,input [23:0] payload,output ready,
 output reg [3:0] txd,output reg tx_en,
 input [3:0] rxd,input rx_dv,
 output reg received,output reg [23:0] received_payload);
 function [31:0] crc4;
  input [31:0] crc;input [3:0] data;
  reg [31:0] c;integer i;
  begin c=crc;for(i=0;i<4;i=i+1) c=(c>>1)^((c[0]^data[i])?32'hedb88320:0);crc4=c;end
 endfunction
 localparam IDLE=0,PRE=1,DATA=2,FCS=3,GAP=4;
 reg [2:0] state;
 reg [5:0] index;
 reg half;
 reg [23:0] held;
 reg [31:0] tx_crc;
 wire [7:0] header;
 wire [7:0] tx_byte=index==48?held[23:16]:index==49?held[15:8]:index==50?held[7:0]:header;
 wire [3:0] nibble=half?tx_byte[7:4]:tx_byte[3:0];
 net_frame_byte #(.IS_B(IS_B)) tx_header(index,header);
 assign ready=state==IDLE;
 always @(posedge tx_clk or posedge tx_rst) begin
  if(tx_rst) begin state<=IDLE;index<=0;half<=0;held<=0;tx_crc<=32'hffffffff;txd<=0;tx_en<=0;end
  else begin
   tx_en<=0;txd<=0;
   case(state)
    IDLE:if(send && enabled) begin held<=payload;state<=PRE;index<=0;end
    PRE:begin
     tx_en<=1;txd<=index==15?4'hd:4'h5;
     if(index==15) begin state<=DATA;index<=0;half<=0;tx_crc<=32'hffffffff;end
     else index<=index+1'b1;
    end
    DATA:begin
     tx_en<=1;txd<=nibble;tx_crc<=crc4(tx_crc,nibble);half<=~half;
     if(half) begin if(index==59) begin state<=FCS;index<=0;end else index<=index+1'b1;end
    end
    FCS:begin
     tx_en<=1;txd<=~tx_crc[3:0];tx_crc<={4'hf,tx_crc[31:4]};
     if(index==7) begin state<=GAP;index<=0;end else index<=index+1'b1;
    end
    GAP:if(index==23) state<=IDLE;else index<=index+1'b1;
    default:state<=IDLE;
   endcase
  end
 end
 // Nibbles arrive one per RX clock at 100BASE-TX, low nibble first.
 reg rx_half,rx_started,rx_good;
 reg [3:0] low;
 reg [6:0] rx_index;
 reg [3:0] pre_count;
 reg [31:0] rx_crc;
 reg [23:0] pending;
 wire [7:0] rx_byte={rxd,low};
 wire [7:0] expected;
 net_frame_byte #(.IS_B(!IS_B)) rx_header(rx_index[5:0],expected);
 always @(posedge rx_clk or posedge rx_rst) begin
  if(rx_rst) begin
   rx_half<=0;rx_started<=0;rx_good<=0;low<=0;rx_index<=0;
   pre_count<=0;rx_crc<=32'hffffffff;pending<=0;received<=0;received_payload<=0;
  end else begin
   received<=0;
   if(!rx_dv) begin
    if(rx_started && rx_good && !rx_half && rx_index==64 && rx_crc==32'hdebb20e3) begin
     received_payload<=pending;received<=1;
    end
    rx_half<=0;rx_started<=0;rx_good<=1;rx_index<=0;pre_count<=0;rx_crc<=32'hffffffff;
   end else if(!rx_started) begin
    if(rxd==5 && pre_count<15) pre_count<=pre_count+1'b1;
    else if(rxd==13 && pre_count==15) begin rx_started<=1;rx_half<=0;end
    else begin rx_good<=0;pre_count<=0;end
   end else begin
    rx_crc<=crc4(rx_crc,rxd);rx_half<=~rx_half;
    if(!rx_half) low<=rxd;
    else begin
     if(rx_index<65) rx_index<=rx_index+1'b1;
     if(rx_index<60) begin
      case(rx_index)
       48:pending[23:16]<=rx_byte;
       49:pending[15:8]<=rx_byte;
       50:begin pending[7:0]<=rx_byte;if(rx_byte[7:5]!=0 || rx_byte[4:3]==3) rx_good<=0;end
       default:if(rx_byte!=expected) rx_good<=0;
      endcase
     end else if(rx_index>=64) rx_good<=0;
    end
   end
  end
 end
endmodule

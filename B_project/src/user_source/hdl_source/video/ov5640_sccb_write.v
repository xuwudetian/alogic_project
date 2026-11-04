`timescale 1ns/1ps
// 16-bit register write; open-drain SDA; 250 kHz SCL at 50 MHz.
// OV5640 SCCB does not require clock stretching. ready is !busy.
module ov5640_sccb_write #(
    parameter integer QUARTER_CYCLES=50
)(input clk,input rst_n,input start,input [23:0] register_data,
    output reg busy,output reg done,output reg nack,
    output reg scl,inout sda);
    localparam IDLE=0,START=1,SEND=2,ACK=3,STOP=4;
    reg [2:0] state;
    reg [1:0] phase,byte_index;
    reg [2:0] bit_index;
    reg [7:0] tx_byte;
    reg [23:0] payload;
    reg [15:0] divider;
    reg sda_low;
    assign sda=sda_low ? 1'b0 : 1'bz;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;phase<=0;byte_index<=0;bit_index<=7;
            tx_byte<=0;payload<=0;divider<=0;sda_low<=0;scl<=1;
            busy<=0;done<=0;nack<=0;
        end else begin
            done<=0;
            if(state==IDLE) begin
                divider<=0;phase<=0;scl<=1;sda_low<=0;
                if(start) begin
                    busy<=1;nack<=0;payload<=register_data;byte_index<=0;
                    tx_byte<=8'h78;bit_index<=7;state<=START;
                end
            end else if(divider==QUARTER_CYCLES-1) begin
                divider<=0;phase<=phase+1'b1;
                case(state)
                    START: case(phase)
                        0: begin scl<=1;sda_low<=0;end
                        1: sda_low<=1;
                        3: begin scl<=0;state<=SEND;end
                        default: ;
                    endcase
                    SEND: case(phase)
                        0: begin scl<=0;sda_low<=~tx_byte[bit_index];end
                        1: scl<=1;
                        3: begin
                            scl<=0;
                            if(bit_index==0) state<=ACK;
                            else bit_index<=bit_index-1'b1;
                        end
                        default: ;
                    endcase
                    ACK: case(phase)
                        0: sda_low<=0;
                        1: scl<=1;
                        2: if(sda) nack<=1;
                        3: begin
                            scl<=0;bit_index<=7;
                            if(byte_index==3 || nack) state<=STOP;
                            else begin
                                byte_index<=byte_index+1'b1;
                                case(byte_index)
                                    0: tx_byte<=payload[23:16];
                                    1: tx_byte<=payload[15:8];
                                    default: tx_byte<=payload[7:0];
                                endcase
                                state<=SEND;
                            end
                        end
                    endcase
                    STOP: case(phase)
                        0: begin scl<=0;sda_low<=1;end
                        1: scl<=1;
                        2: sda_low<=0;
                        3: begin busy<=0;done<=1;state<=IDLE;end
                    endcase
                    default: begin state<=IDLE;busy<=0;end
                endcase
            end else divider<=divider+1'b1;
        end
    end
endmodule

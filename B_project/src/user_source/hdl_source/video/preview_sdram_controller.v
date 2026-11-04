`timescale 1ns/1ps
// Conservative 100 MHz SDR SDRAM controller, 2M x 32 organization:
// address={bank[1:0],row[10:0],column[7:0]}, BL8 sequential, CAS latency 3.
// Retain the open row between aligned BL8 requests. Changing rows and periodic
// refresh explicitly precharge and wait tRP; requests cannot cross a row.
// RAM uses the same clock and samples the previous cycle's registered commands.
// Command/data output and DQ input each have a full 10 ns timing window.
module preview_sdram_controller #(
    parameter integer INIT_CYCLES=20000,
    parameter integer REFRESH_CYCLES=750
)(
    input clk,input rst_n,
    input request,input write_request,input [20:0] address,input [255:0] write_words,
    output ready,output reg initialized,output reg clock_enable,output reg done,
    output reg read_valid,output reg [2:0] read_index,output reg [31:0] read_data,
    output reg ras_n,output reg cas_n,output reg we_n,
    output reg [10:0] sdram_address,output reg [1:0] bank,
    output reg [31:0] data_out,output reg data_output_enable,
    input [31:0] data_in);
    localparam POWER=0,INIT_PRE=1,INIT_PRE_WAIT=2,INIT_REF=3,INIT_REF_WAIT=4,
        INIT_MODE=5,INIT_MODE_WAIT=6,IDLE=7,ACTIVE=8,RCD=9,COMMAND=10,
        READ_WAIT=11,READ_DATA=12,WRITE_DATA=13,WRITE_RECOVERY=14,
        CLOSE=15,CLOSE_WAIT=16,FINISH=17,REF_PRE=18,REF_PRE_WAIT=19,
        REF_COMMAND=20,REF_WAIT=21,ROW_PRE=22,ROW_PRE_WAIT=23;
    reg [4:0] state;
    reg [14:0] power_count;
    reg [9:0] refresh_count;
    reg [3:0] wait_count;
    reg [3:0] init_refresh;
    reg [20:0] request_address;
    reg request_write;
    reg [255:0] words_q;
    reg [2:0] beat;
    reg row_open;
    reg [12:0] open_row_address;
    assign ready=(state==IDLE && refresh_count<REFRESH_CYCLES);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=POWER;power_count<=0;refresh_count<=0;wait_count<=0;init_refresh<=0;
            initialized<=0;clock_enable<=0;done<=0;read_valid<=0;read_index<=0;read_data<=0;
            ras_n<=1;cas_n<=1;we_n<=1;sdram_address<=0;bank<=0;
            data_out<=0;data_output_enable<=0;request_address<=0;request_write<=0;words_q<=0;beat<=0;
            row_open<=0;open_row_address<=0;
        end else begin
            // NOP and release DQ unless a write beat explicitly drives it.
            ras_n<=1;cas_n<=1;we_n<=1;data_output_enable<=0;done<=0;read_valid<=0;
            if(initialized && refresh_count<REFRESH_CYCLES) refresh_count<=refresh_count+1'b1;
            case(state)
                POWER: if(power_count==INIT_CYCLES-1) begin clock_enable<=1;state<=INIT_PRE;end
                       else power_count<=power_count+1'b1;
                INIT_PRE: begin ras_n<=0;we_n<=0;sdram_address<=11'h400;wait_count<=4;state<=INIT_PRE_WAIT;end
                INIT_PRE_WAIT: if(wait_count==1) state<=INIT_REF;else wait_count<=wait_count-1'b1;
                INIT_REF: begin ras_n<=0;cas_n<=0;init_refresh<=init_refresh+1'b1;wait_count<=8;state<=INIT_REF_WAIT;end
                INIT_REF_WAIT: if(wait_count==1) state<=(init_refresh==8)?INIT_MODE:INIT_REF;
                               else wait_count<=wait_count-1'b1;
                INIT_MODE: begin ras_n<=0;cas_n<=0;we_n<=0;bank<=0;sdram_address<=11'h033;wait_count<=2;state<=INIT_MODE_WAIT;end
                INIT_MODE_WAIT: if(wait_count==1) begin initialized<=1;refresh_count<=0;state<=IDLE;end
                                else wait_count<=wait_count-1'b1;
                IDLE: begin
                    if(refresh_count>=REFRESH_CYCLES) state<=REF_PRE;
                    else if(request) begin
                        request_address<=address;request_write<=write_request;words_q<=write_words;
                        if(row_open && open_row_address==address[20:8]) state<=COMMAND;
                        else if(row_open) state<=ROW_PRE;
                        else state<=ACTIVE;
                    end
                end
                ROW_PRE: begin
                    ras_n<=0;we_n<=0;sdram_address<=11'h400;row_open<=0;
                    wait_count<=4;state<=ROW_PRE_WAIT;
                end
                ROW_PRE_WAIT: if(wait_count==1) state<=ACTIVE;else wait_count<=wait_count-1'b1;
                ACTIVE: begin
                    ras_n<=0;sdram_address<=request_address[18:8];bank<=request_address[20:19];
                    row_open<=1;open_row_address<=request_address[20:8];
                    wait_count<=4;state<=RCD;
                end
                RCD: if(wait_count==1) state<=COMMAND;else wait_count<=wait_count-1'b1;
                COMMAND: begin
                    cas_n<=0;we_n<=!request_write;sdram_address<={3'd0,request_address[7:0]};beat<=0;
                    if(request_write) begin
                        data_output_enable<=1;data_out<=words_q[31:0];beat<=1;state<=WRITE_DATA;
                    // SDRAM accepts the registered command on the next edge.
                    // After CL3, PHY captures the previous beat on a rising
                    // edge; this FSM consumes that register on the next edge.
                    end else begin wait_count<=5;state<=READ_WAIT;end
                end
                READ_WAIT: if(wait_count==1) begin beat<=0;state<=READ_DATA;end
                           else wait_count<=wait_count-1'b1;
                READ_DATA: begin
                    read_valid<=1;read_index<=beat;read_data<=data_in;
                    if(beat==7) state<=FINISH;else beat<=beat+1'b1;
                end
                WRITE_DATA: begin
                    data_output_enable<=1;data_out<=words_q[beat*32+:32];
                    if(beat==7) begin wait_count<=4;state<=WRITE_RECOVERY;end
                    else beat<=beat+1'b1;
                end
                WRITE_RECOVERY: if(wait_count==1) state<=FINISH;else wait_count<=wait_count-1'b1;
                CLOSE: begin ras_n<=0;we_n<=0;sdram_address<=11'h400;wait_count<=4;state<=CLOSE_WAIT;end
                CLOSE_WAIT: if(wait_count==1) state<=FINISH;else wait_count<=wait_count-1'b1;
                FINISH: begin done<=1;state<=IDLE;end
                REF_PRE: begin ras_n<=0;we_n<=0;sdram_address<=11'h400;row_open<=0;wait_count<=4;state<=REF_PRE_WAIT;end
                REF_PRE_WAIT: if(wait_count==1) state<=REF_COMMAND;else wait_count<=wait_count-1'b1;
                REF_COMMAND: begin ras_n<=0;cas_n<=0;wait_count<=8;state<=REF_WAIT;end
                REF_WAIT: if(wait_count==1) begin refresh_count<=0;state<=IDLE;end
                          else wait_count<=wait_count-1'b1;
                default:state<=POWER;
            endcase
        end
    end
endmodule

`timescale 1ns/1ps
// 115200 8N1 at the existing 25 MHz pixel clock. No additional PLL or RAM.
module player_uart_rx #(parameter integer CLKS_PER_BIT=217)(
    input clk,input rst,input rx,output reg [7:0] data,
    output reg valid,output reg framing_error
);
    localparam BITS=$clog2(CLKS_PER_BIT+1);
    (* async_reg="true" *) reg [1:0] sync;
    reg [BITS-1:0] count;
    reg [2:0] state,bit_index;
    reg [7:0] shift;
    always @(posedge clk or posedge rst) begin
        if(rst) begin sync<=3;count<=0;state<=0;bit_index<=0;shift<=0;data<=0;valid<=0;framing_error<=0;end
        else begin
            sync<={sync[0],rx};valid<=0;framing_error<=0;
            case(state)
                0: if(!sync[1]) begin count<=CLKS_PER_BIT/2-1;state<=1;end
                1: if(count!=0) count<=count-1'b1;
                   else if(sync[1]) state<=0;
                   else begin count<=CLKS_PER_BIT-1;bit_index<=0;state<=2;end
                2: if(count!=0) count<=count-1'b1;
                   else begin
                       shift[bit_index]<=sync[1];count<=CLKS_PER_BIT-1;
                       if(bit_index==7) state<=3;else bit_index<=bit_index+1'b1;
                   end
                3: if(count!=0) count<=count-1'b1;
                   else if(sync[1]) begin data<=shift;valid<=1;state<=0;end
                   else begin framing_error<=1;state<=4;end
                4: if(sync[1]) state<=0; // A break is one error, not repeated commands.
                default: state<=0;
            endcase
        end
    end
endmodule

module player_uart_tx #(parameter integer CLKS_PER_BIT=217)(
    input clk,input rst,input start,input [7:0] data,
    output tx,output reg busy,output reg done
);
    localparam BITS=$clog2(CLKS_PER_BIT+1);
    reg [BITS-1:0] count;
    reg [9:0] shift;
    reg [3:0] bits_left;
    assign tx=shift[0];
    always @(posedge clk or posedge rst) begin
        if(rst) begin count<=0;shift<=10'h3ff;bits_left<=0;busy<=0;done<=0;end
        else begin
            done<=0;
            if(!busy) begin
                if(start) begin shift<={1'b1,data,1'b0};count<=CLKS_PER_BIT-1;bits_left<=10;busy<=1;end
            end else if(count!=0) count<=count-1'b1;
            else begin
                count<=CLKS_PER_BIT-1;shift<={1'b1,shift[9:1]};bits_left<=bits_left-1'b1;
                if(bits_left==1) begin busy<=0;done<=1;end
            end
        end
    end
endmodule

// A5 5A LEN SEQ CMD PAYLOAD CRC8; CRC covers LEN through PAYLOAD.
// Requests carry 0..3 payload bytes. One request may be outstanding at a time.
// Every response carries RESULT + 45 status bytes + 16-bit error count (48 bytes).
module player_uart #(
    parameter integer CLK_HZ=25000000,parameter integer BAUD=115200,
    parameter integer BYTE_TIMEOUT=CLK_HZ/50,parameter integer FRAME_TIMEOUT=CLK_HZ/5,
    parameter integer RESET_CYCLES=16
)(
    input clk,input rst,input rx,output tx,input frame_tick,
    input [359:0] status_payload,
    output reg command_valid,output [7:0] command,
    output [23:0] argument,input command_done,input [2:0] command_result,
    output reg soft_reset,output reg [15:0] rx_errors
);
    localparam CPB=(CLK_HZ+BAUD/2)/BAUD;
    wire [7:0] rx_data;
    wire rx_valid,rx_bad,tx_busy,tx_done;
    reg tx_start;
    reg [7:0] tx_data;
    player_uart_rx #(.CLKS_PER_BIT(CPB)) receiver(clk,rst,rx,rx_data,rx_valid,rx_bad);
    player_uart_tx #(.CLKS_PER_BIT(CPB)) transmitter(clk,rst,tx_start,tx_data,tx,tx_busy,tx_done);
    function [7:0] crc_byte;
        input [7:0] crc,data;
        reg [7:0] c;
        integer k;
        begin
            c=crc^data;
            for(k=0;k<8;k=k+1) c=c[7] ? (c<<1)^8'h07 : c<<1;
            crc_byte=c;
        end
    endfunction
    reg [2:0] parse_state;
    reg [1:0] length,payload_index;
    reg [7:0] request_seq,request_cmd,rx_crc;
    reg [23:0] request_arg;
    // The byte parser holds these through the one-cycle controller handshake.
    assign command=request_cmd;
    assign argument=request_arg;
    reg request_valid;
    localparam TIMER_MAX=FRAME_TIMEOUT>BYTE_TIMEOUT ? FRAME_TIMEOUT : BYTE_TIMEOUT;
    reg [$clog2(TIMER_MAX+1)-1:0] watchdog;
    reg [2:0] engine;
    localparam IDLE=0,CONTROL=1,FRAME=2,CAPTURE=3,SEND=4,DRAIN=5,RESET=6,FILL=7;
    wire accepting=engine==IDLE;
    // Parsing and command completion are mutually exclusive. Share one timer.
    always @(posedge clk or posedge rst) begin
        if(rst) watchdog<=0;
        else if(engine==CONTROL || engine==FRAME) begin
            if((engine==CONTROL && command_done) || (engine==FRAME && frame_tick)) watchdog<=0;
            else if(watchdog!=FRAME_TIMEOUT-1) watchdog<=watchdog+1'b1;
        end else if(accepting && parse_state!=0 && !rx_valid && !rx_bad) begin
            if(watchdog!=BYTE_TIMEOUT-1) watchdog<=watchdog+1'b1;
        end else watchdog<=0;
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            parse_state<=0;length<=0;payload_index<=0;request_seq<=0;request_cmd<=0;
            rx_crc<=0;request_arg<=0;request_valid<=0;rx_errors<=0;
        end else begin
            request_valid<=0;
            if(!accepting) begin
                parse_state<=0;
                if((rx_valid || rx_bad) && rx_errors!=16'hffff) rx_errors<=rx_errors+1'b1;
            end else if(rx_bad || (parse_state!=0 && !rx_valid && watchdog==BYTE_TIMEOUT-1)) begin
                parse_state<=0;
                if(rx_errors!=16'hffff) rx_errors<=rx_errors+1'b1;
            end else if(rx_valid) begin
                case(parse_state)
                    0: if(rx_data==8'ha5) parse_state<=1;
                    1: if(rx_data==8'h5a) parse_state<=2;
                       else if(rx_data!=8'ha5) parse_state<=0;
                    2: if(rx_data<=3) begin
                           length<=rx_data[1:0];rx_crc<=crc_byte(0,rx_data);
                           request_arg<=0;payload_index<=0;parse_state<=3;
                       end else begin
                           parse_state<=0;if(rx_errors!=16'hffff) rx_errors<=rx_errors+1'b1;
                       end
                    3: begin request_seq<=rx_data;rx_crc<=crc_byte(rx_crc,rx_data);parse_state<=4;end
                    4: begin request_cmd<=rx_data;rx_crc<=crc_byte(rx_crc,rx_data);parse_state<=length==0 ? 6 : 5;end
                    5: begin
                        case(payload_index)
                            0: request_arg[7:0]<=rx_data;
                            1: request_arg[15:8]<=rx_data;
                            2: request_arg[23:16]<=rx_data;
                        endcase
                        rx_crc<=crc_byte(rx_crc,rx_data);payload_index<=payload_index+1'b1;
                        if(payload_index==length-1) parse_state<=6;
                    end
                    6: begin
                        parse_state<=0;
                        if(rx_crc==rx_data && accepting) request_valid<=1;
                        else if(rx_errors!=16'hffff) rx_errors<=rx_errors+1'b1;
                    end
                    default: parse_state<=0;
                endcase
            end
        end
    end
    reg [7:0] response_seq,response_cmd;
    reg [2:0] result;
    reg reset_pending;
    // Copy the frame-published bundle into one small RAM in 48 clocks (1.92 us).
    // Avoid a 384-bit parallel-load/shift register on this nearly full device.
    // status_payload must remain stable for these 48 clocks after frame_tick.
    reg [7:0] reply_memory[0:63] /* fehdl force_ram=1, ram_style="bram" */;
    reg [7:0] memory_byte;
    reg [5:0] copy_index;
    reg [5:0] send_index;
    reg [15:0] snapshot_errors;
    wire [383:0] snapshot_input={snapshot_errors,status_payload,5'd0,result};
    wire [5:0] memory_read_address=send_index-6'd5;
    always @(posedge clk) begin
        if(engine==FILL) reply_memory[copy_index]<=snapshot_input[copy_index*8 +: 8];
        memory_byte<=reply_memory[memory_read_address];
    end
    reg [7:0] tx_crc;
    reg [$clog2(RESET_CYCLES+1)-1:0] reset_count;
    reg [7:0] next_byte;
    always @* begin
        case(send_index)
            0: next_byte=8'ha5;
            1: next_byte=8'h5a;
            2: next_byte=8'd48;
            3: next_byte=response_seq;
            4: next_byte=response_cmd;
            53: next_byte=tx_crc;
            default: next_byte=memory_byte;
        endcase
    end
    wire known_command=request_cmd==8'h01 || request_cmd==8'h02 ||
        (request_cmd>=8'h10 && request_cmd<=8'h16) || request_cmd==8'h7f;
    wire length_ok=(request_cmd==8'h10 || request_cmd==8'h12 || request_cmd==8'h13 || request_cmd==8'h14) ? length==1 :
        request_cmd==8'h11 ? length==3 : request_cmd==8'h15 ? length==2 : length==0;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            engine<=IDLE;command_valid<=0;soft_reset<=0;
            tx_start<=0;tx_data<=0;response_seq<=0;response_cmd<=0;result<=0;
            reset_pending<=0;copy_index<=0;snapshot_errors<=0;send_index<=0;tx_crc<=0;reset_count<=0;
        end else begin
            tx_start<=0;command_valid<=0;
            case(engine)
                IDLE: if(request_valid) begin
                    response_seq<=request_seq;response_cmd<=request_cmd|8'h80;
                    result<=0;reset_pending<=0;
                    if(!known_command) begin result<=1;engine<=FRAME;end
                    else if(!length_ok) begin result<=2;engine<=FRAME;end
                    else if(request_cmd==8'h01 || request_cmd==8'h02 || request_cmd==8'h7f) begin
                        reset_pending<=request_cmd==8'h7f;engine<=FRAME;
                    end else begin
                        command_valid<=1;engine<=CONTROL;
                    end
                end
                CONTROL: begin
                    if(command_done) begin result<=command_result;engine<=FRAME;end
                    else if(watchdog==FRAME_TIMEOUT-1) begin result<=6;engine<=CAPTURE;end
                end
                FRAME: begin
                    // Control edits publish at this edge. Capture on the following edge.
                    if(frame_tick) engine<=CAPTURE;
                    else if(watchdog==FRAME_TIMEOUT-1) begin result<=6;reset_pending<=0;engine<=CAPTURE;end
                end
                CAPTURE: begin
                    snapshot_errors<=rx_errors;copy_index<=0;engine<=FILL;
                end
                FILL: begin
                    if(copy_index==47) begin send_index<=0;tx_crc<=0;engine<=SEND;end
                    else copy_index<=copy_index+1'b1;
                end
                SEND: if(!tx_busy && !tx_start) begin
                    tx_data<=next_byte;tx_start<=1;
                    if(send_index>=2 && send_index<=52) tx_crc<=crc_byte(tx_crc,next_byte);
                    if(send_index==53) engine<=DRAIN;else send_index<=send_index+1'b1;
                end
                DRAIN: if(tx_done) begin
                    if(reset_pending) begin soft_reset<=1;reset_count<=RESET_CYCLES-1;engine<=RESET;end
                    else engine<=IDLE;
                end
                RESET: if(reset_count==0) begin soft_reset<=0;engine<=IDLE;end
                       else reset_count<=reset_count-1'b1;
                default: engine<=IDLE;
            endcase
        end
    end
endmodule

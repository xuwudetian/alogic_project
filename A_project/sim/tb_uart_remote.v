`timescale 1ns/1ps
module tb_uart_remote;
    reg clk=0,rst=1,rx=1,tick=0;
    always #5 clk=~clk;
    integer frame_count=0;
    always @(negedge clk) begin frame_count=frame_count+1;tick=(frame_count%100)==0;end
    wire tx,valid,done,soft_reset;
    wire [7:0] command;
    wire [23:0] argument;
    wire [2:0] result;
    wire [15:0] rx_errors;
    wire signed [8:0] bright;
    wire [8:0] contrast;
    wire [3:0] volume,interval_seconds,modes,transition,mask,override_value,physical;
    wire [2:0] menu;
    wire [3:0] focus,selected;
    wire [1:0] run_mode,dir_focus;
    wire directory,settings,alarm,browse,nt,at,select_toggle;
    reg [8:0] available=511,ready=511;
    reg [3:0] switches=0;
    reg sensor_set=0,sensor_clear=0;
    wire [359:0] payload;
    assign payload[0+:24]=24'h014142;
    assign payload[24+:8]={2'b01,alarm,settings,directory,browse,run_mode==2,1'b1};
    assign payload[32+:8]=0;
    assign payload[40+:8]={4'd0,focus};
    assign payload[48+:8]={5'd0,menu};
    assign payload[56+:8]={6'd0,dir_focus};
    assign payload[64+:8]={6'd0,run_mode};
    assign payload[72+:8]={4'd0,transition};
    assign payload[80+:8]={4'd0,volume};
    assign payload[88+:8]={4'd0,interval_seconds};
    assign payload[96+:16]={{7{bright[8]}},bright};
    assign payload[112+:16]={7'd0,contrast};
    assign payload[128+:16]={{7{bright[8]}},bright};
    assign payload[144+:8]={4'd0,modes};
    assign payload[152+:8]={4'd0,physical};
    assign payload[160+:8]={4'd0,mask};
    assign payload[168+:8]={4'd0,override_value};
    assign payload[176+:8]=available[7:0];
    assign payload[184+:8]=ready[7:0];
    assign payload[192+:168]=0;
    player_uart #(.CLK_HZ(8000),.BAUD(1000),.BYTE_TIMEOUT(300),.FRAME_TIMEOUT(2000),.RESET_CYCLES(16))
        dut(.clk(clk),.rst(rst),.rx(rx),.tx(tx),.frame_tick(tick),.status_payload(payload),
        .command_valid(valid),.command(command),.argument(argument),.command_done(done),
        .command_result(result),.soft_reset(soft_reset),.rx_errors(rx_errors));
    player_control #(.SENSOR_ENABLE(1),.REMOTE_ENABLE(1),.DEBOUNCE_CYCLES(3),.LONG_CYCLES(20)) control(
        .clk(clk),.rst(rst || soft_reset),.frame_tick(tick),.key_next(1'b1),.key_auto(1'b1),.key_menu(1'b1),
        .switches(switches),.next_toggle(nt),.auto_toggle(at),.brightness(bright),.contrast(contrast),
        .volume(volume),.interval_seconds(interval_seconds),.menu(menu),.modes(modes),
        .available(available),.thumbnail_valid(ready),.browse(browse),.focus(focus),
        .select_toggle(select_toggle),.select_index(selected),.directory(directory),.directory_focus(dir_focus),
        .status_panel(settings),.alarm(alarm),.auto_active(run_mode==2),.run_mode(run_mode),
        .sensor_alarm(sensor_set),.sensor_alarm_clear(sensor_clear),.transition_mode(transition),.playback_fault(1'b0),
        .remote_valid(valid),.remote_command(command),.remote_argument(argument),.remote_done(done),
        .remote_result(result),.remote_switch_mask(mask),.remote_switch_value(override_value),.physical_switches(physical));
    function [7:0] crc;
        input [7:0] value,byte_value;
        reg [7:0] v;integer n;
        begin v=value^byte_value;for(n=0;n<8;n=n+1) v=v[7] ? (v<<1)^7 : v<<1;crc=v;end
    endfunction
    task send_byte;
        input [7:0] b;integer bit_no;
        begin
            @(negedge clk);rx=0;repeat(8) @(negedge clk);
            for(bit_no=0;bit_no<8;bit_no=bit_no+1) begin rx=b[bit_no];repeat(8) @(negedge clk);end
            rx=1;repeat(8) @(negedge clk);
        end
    endtask
    reg [7:0] reply[0:53];
    integer reply_count=0,reply_index=0,j;
    reg [7:0] b,check;
    // Independent wire-level receiver: sample each data bit near its center.
    initial forever begin
        @(negedge tx);repeat(12) @(posedge clk);
        for(j=0;j<8;j=j+1) begin b[j]=tx;repeat(8) @(posedge clk);end
        if(tx!==1) $fatal(1,"UART TX stop bit invalid");
        reply[reply_index]=b;
        if(reply_index==53) begin
            if(reply[0]!==8'ha5 || reply[1]!==8'h5a || reply[2]!==48) $fatal(1,"reply framing invalid");
            check=0;
            for(j=2;j<53;j=j+1) check=crc(check,reply[j]);
            if(check!==reply[53]) $fatal(1,"reply CRC invalid");
            $write("WIRE:");for(j=0;j<54;j=j+1) $write("%02x",reply[j]);$write("\n");
            reply_count=reply_count+1;reply_index=0;
        end else reply_index=reply_index+1;
    end
    reg [7:0] seq=0;
    task request;
        input [7:0] op,len;input [23:0] arg;input integer expected;
        reg [7:0] c;integer i,old_count;
        begin
            old_count=reply_count;seq=seq+1;c=crc(crc(crc(0,len),seq),op);
            send_byte(8'ha5);send_byte(8'h5a);send_byte(len);send_byte(seq);send_byte(op);
            for(i=0;i<len;i=i+1) begin send_byte(arg[i*8+:8]);c=crc(c,arg[i*8+:8]);end
            send_byte(c);
            wait(reply_count==old_count+1);
            if(reply[3]!==seq || reply[4]!==(op|8'h80) || reply[5]!==expected)
                $fatal(1,"command %h result %0d expected %0d",op,reply[5],expected);
            repeat(30) @(negedge clk);
        end
    endtask
    integer n,before_bad;
    initial begin
        repeat(5) @(negedge clk);rst=0;
        request(1,0,0,0);
        if(reply[6]!==8'h42 || reply[7]!==8'h41 || reply[8]!==1) $fatal(1,"signature invalid");
        request(8'h11,3,24'hff0100,0);
        if(bright!==-9'sd255 || {reply[19],reply[18]}!==16'hff01) $fatal(1,"signed brightness or snapshot invalid");
        request(8'h11,3,24'h010000,3); // +256 rejected
        if(bright!==-9'sd255) $fatal(1,"invalid SET mutated state");
        request(8'h11,3,24'h017f01,0); // contrast 383
        request(8'h12,1,3,0);request(8'h10,1,1,0); // settings, select contrast
        request(8'h10,1,0,0);if(contrast!==384) $fatal(1,"physical-style increment overflow");
        request(8'h11,3,24'h000101,0);request(8'h10,1,3,0);
        if(contrast!==0) $fatal(1,"physical-style decrement underflow");
        request(8'h11,3,24'h000802,0);if(volume!==8) $fatal(1,"volume failed");
        request(8'h11,3,24'h000903,0);if(interval_seconds!==9) $fatal(1,"interval failed");
        for(n=0;n<9;n=n+1) begin
            request(8'h11,3,(n<<8)|4,0);if(transition!==n) $fatal(1,"transition failed");
        end
        request(8'h11,3,24'h000105,0);if(run_mode!==1) $fatal(1,"MAN failed");
        request(8'h11,3,24'h000205,0);if(run_mode!==2) $fatal(1,"AUTO failed");
        request(8'h15,2,24'h000505,0);if((modes&5)!==5 || mask!==5) $fatal(1,"override failed");
        request(8'h15,2,24'h000002,3);
        switches=4'b0100;request(8'h15,2,0,0);if(modes[2]!==1 || modes[0]!==0) $fatal(1,"release to board switches failed");
        request(8'h12,1,2,0);if(!browse) $fatal(1,"preview failed");
        ready=31;request(8'h13,1,5,5);ready=63;
        request(8'h13,1,5,0);if(selected!==5 || browse || directory || settings) $fatal(1,"image select failed");
        ready=511;request(8'h13,1,8,0);
        if(selected!==8 || focus!==8) $fatal(1,"PIC9 remote selection truncated");
        request(8'h13,1,9,3);request(8'h13,1,15,3);
        if(selected!==8) $fatal(1,"invalid image changed selection");
        request(8'h14,1,1,0);if(!alarm) $fatal(1,"alarm on failed");
        request(8'h12,1,1,4);request(8'h13,1,0,4);request(8'h16,0,0,4);
        request(8'h10,1,3,0);if(alarm) $fatal(1,"KEY4 alarm off failed");
        request(8'h12,1,1,0);if(!directory) $fatal(1,"directory failed");
        request(8'h10,1,1,0);request(8'h10,1,3,0);if(directory || browse) $fatal(1,"resume directory path failed");
        request(8'h16,0,0,0);
        request(8'h11,1,0,2);request(8'h66,0,0,1);request(8'h10,1,9,3);
        @(negedge clk);sensor_set=1;@(negedge clk);sensor_set=0;
        repeat(110) @(negedge clk);if(!alarm) $fatal(1,"sensor alarm not active");
        fork
            request(8'h11,3,24'h000402,0);
            begin
                wait(valid && command==8'h11);@(negedge clk);sensor_clear=1;
                @(negedge clk);sensor_clear=0;
            end
        join
        if(alarm || volume!==4) $fatal(1,"remote SET swallowed sensor quiet-exit pulse");
        before_bad=reply_count;
        send_byte(8'ha5);send_byte(8'h5a);send_byte(0);send_byte(8'h55);send_byte(8'h7f);send_byte(0);
        repeat(500) @(negedge clk);
        if(reply_count!=before_bad || soft_reset) $fatal(1,"bad CRC executed or ACKed");
        send_byte(8'ha5);send_byte(8'h5a);send_byte(3);repeat(400) @(negedge clk);
        request(2,0,0,0);if(rx_errors<2) $fatal(1,"CRC/interbyte timeout not counted");
        request(8'h7f,0,0,0);
        repeat(150) @(negedge clk);
        if(bright!==0 || volume!==4 || interval_seconds!==3 || mask!==0 || run_mode!==2) $fatal(1,"reset defaults failed");
        request(2,0,0,0);
        $display("PASS uart_remote: real UART framing, CRC, all commands, bounds, gestures, frame ACK, reset, recovery");
        $finish;
    end
    always @(posedge soft_reset) if(reply_index!=0) $fatal(1,"reset interrupted ACK packet");
    initial begin #10000000;$fatal(1,"UART test timeout");end
endmodule

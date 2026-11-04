`timescale 1ns/1ps
module tb_light_sensor;
    reg clk=0,rst=1,frame_tick=0,slave_low=0,clock_low=0;
    tri1 scl,sda;
    wire valid,online;
    wire [15:0] raw;
    integer results=0;
    reg [7:0] rx;
    assign sda=slave_low ? 1'b0 : 1'bz;
    assign scl=clock_low ? 1'b0 : 1'bz;
    always #20 clk=~clk;
    player_light_sensor #(.QUARTER_CYCLES(8),.POLL_FRAMES(1)) dut(
        .clk(clk),.rst(rst),.frame_tick(frame_tick),.scl(scl),.sda(sda),.valid(valid),.online(online),.raw(raw));
    always @(posedge clk) if(valid) results=results+1;
    task start;
        begin @(negedge sda);while(scl!==1) @(negedge sda);end
    endtask
    task stop;
        begin @(posedge sda);while(scl!==1) @(posedge sda);repeat(20) @(negedge clk);end
    endtask
    task frame;
        begin @(negedge clk);frame_tick=1;@(negedge clk);frame_tick=0;end
    endtask
    task receive(input [7:0] expected,input ack);
        integer n;
        begin
            for(n=7;n>=0;n=n-1) begin @(posedge scl);rx[n]=sda;end
            if(rx!==expected) $fatal(1,"I2C got %h expected %h",rx,expected);
            @(negedge scl);slave_low=ack;@(posedge scl);@(negedge scl);slave_low=0;
        end
    endtask
    task send(input [7:0] value,input expected_ack);
        integer n;
        begin
            for(n=7;n>=0;n=n-1) begin slave_low=!value[n];@(posedge scl);@(negedge scl);end
            slave_low=0;@(posedge scl);
            if(sda!==!expected_ack) $fatal(1,"I2C master ACK/NACK wrong");
            @(negedge scl);
        end
    endtask
    task configure;
        begin frame;start;receive(8'h20,1);receive(0,1);receive(0,1);receive(0,1);stop;end
    endtask
    task reading;
        begin
            frame;start;receive(8'h20,1);receive(4,1);start;receive(8'h21,1);
            send(8'ha5,1);send(8'h12,0);stop;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        // No device: address NACK, no false light sample, retry remains possible.
        frame;start;receive(8'h20,0);stop;
        if(online || results!=0) $fatal(1,"missing sensor reported valid");
        configure;if(online || results!=0 || !dut.configured) $fatal(1,"configuration published stale light");
        reading;if(!online || results!=1 || raw!=16'h12a5) $fatal(1,"ALS little-endian read failed");
        // NACK during the command must invalidate online state and force reconfiguration.
        frame;start;receive(8'h20,1);receive(4,0);stop;
        if(online || results!=1 || dut.configured) $fatal(1,"disconnect did not invalidate sensor");
        // SDA stuck low: nine recovery pulses, then bounded failure.
        slave_low=1;frame;repeat(2400) @(negedge clk);
        if(dut.state!=0 || online || dut.scl_low || dut.sda_low) $fatal(1,"SDA stuck did not recover to idle");
        slave_low=0;repeat(20) @(negedge clk);
        // SCL stuck low cannot lock the video clock domain.
        clock_low=1;frame;repeat(1000) @(negedge clk);
        if(dut.state!=0 || online || dut.scl_low || dut.sda_low) $fatal(1,"SCL timeout did not release outputs");
        clock_low=0;repeat(20) @(negedge clk);
        configure;reading;
        if(!online || results!=2) $fatal(1,"hot reconnect did not recover");
        $display("PASS light sensor: open drain, config 0000, address 10, register04, repeated START, LSB first, ACK/NACK, missing/stuck/reconnect");$finish;
    end
    initial begin #2000000;$fatal(1,"I2C timeout state %0d byte %0d phase %0d",dut.state,dut.phase_byte,dut.phase);end
endmodule

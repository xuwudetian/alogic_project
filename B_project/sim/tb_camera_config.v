`timescale 1ns/1ps
// Decode the actual SCCB pins: all configuration writes, a transient NACK,
// permanent NACK termination, and the final AWB/format/timing register state.
module tb_camera_config;
    reg clk=0,pclk=0,rst_n=0;
    always #10 clk=~clk;
    always #11 pclk=~pclk;
    wire scl,config_done,config_error;
    tri1 sda;
    reg ack_low=0;
    assign sda=ack_low ? 1'b0 : 1'bz;
    ov5640_camera_frontend dut(.clk50(clk),.rst_n(rst_n),.cam_pclk(pclk),
        .cam_vsync(1'b0),.cam_href(1'b0),.cam_data(8'd0),
        .cam_scl(scl),.cam_sda(sda),.config_done(config_done),.config_error(config_error));
    defparam dut.bus_master.QUARTER_CYCLES=2;

    wire bad_scl,bad_done,bad_error;
    tri1 bad_sda; // no camera: every address must NACK
    ov5640_camera_frontend #(.SIMPLE_AWB(0)) bad(.clk50(clk),.rst_n(rst_n),.cam_pclk(pclk),
        .cam_vsync(1'b0),.cam_href(1'b0),.cam_data(8'd0),
        .cam_scl(bad_scl),.cam_sda(bad_sda),.config_done(bad_done),.config_error(bad_error));
    defparam bad.bus_master.QUARTER_CYCLES=2;

    integer errors=0,attempts=0,accepted=0,bad_attempts=0;
    reg [7:0] expected_index=2,rom_index=0;
    wire [23:0] expected_word,simple_word,legacy_word;
    ov5640_register_table expected_rom(.index(expected_index),.data(expected_word));
    ov5640_register_table simple_rom(.index(rom_index),.data(simple_word));
    ov5640_register_table #(.SIMPLE_AWB(0)) legacy_rom(.index(rom_index),.data(legacy_word));
    reg [7:0] registers[0:65535];
    reg seen[0:65535];
    integer n,b,k;
    reg [7:0] bytes[0:3];
    reg nack_this,nack_injected=0;

    task check; input okay; input [511:0] message;
        begin
            if(okay!==1'b1) begin $display("FAIL: %0s",message);errors=errors+1;end
        end
    endtask
    task check_reg; input [15:0] address; input [7:0] value;
        begin
            if(!seen[address] || registers[address]!==value) begin
                $display("FAIL: final register %04x expected %02x got %02x seen=%b",
                    address,value,registers[address],seen[address]);
                errors=errors+1;
            end
        end
    endtask
    task check_profile; input [7:0] index; input [15:0] address; input [7:0] simple_value,legacy_value;
        begin
            rom_index=index;#1;
            check(simple_word=={address,simple_value},"simple AWB profile entry");
            check(legacy_word=={address,legacy_value},"original advanced AWB profile entry");
        end
    endtask

    initial begin
        for(n=0;n<65536;n=n+1) begin registers[n]=0;seen[n]=0;end
        #51;rst_n=1;
    end

    // Slave ACK timing derives only from SDA/SCL, independent of master state.
    initial begin
        wait(rst_n);
        forever begin
            @(negedge sda);
            if(scl===1'b1) begin
                attempts=attempts+1;nack_this=0;
                for(b=0;b<4;b=b+1) begin
                    bytes[b]=0;
                    for(k=0;k<8;k=k+1) begin
                        @(posedge scl);bytes[b]={bytes[b][6:0],sda};
                    end
                    @(negedge scl);
                    if(b==3 && {bytes[1],bytes[2]}==16'h3406 && !nack_injected) begin
                        nack_this=1;nack_injected=1;
                    end
                    ack_low=!nack_this;
                    @(posedge scl);
                    @(negedge scl);ack_low=0;
                end
                check(bytes[0]==8'h78,"SCCB sensor write address");
                check({bytes[1],bytes[2],bytes[3]}==expected_word,"ordered complete register writes/retry");
                if(!nack_this) begin
                    registers[{bytes[1],bytes[2]}]=bytes[3];
                    seen[{bytes[1],bytes[2]}]=1;
                    accepted=accepted+1;
                    if(expected_index<254) expected_index=expected_index+1'b1;
                end
            end
        end
    end
    always @(negedge bad_sda) if(rst_n && bad_scl===1'b1) bad_attempts=bad_attempts+1;

    initial begin
        // Independent, published profile values; all unrelated table entries
        // must remain identical between the two selectable AWB profiles.
        check_profile(127,16'h5181,8'h58,8'hf2);
        check_profile(128,16'h5182,8'h11,8'h00);
        check_profile(129,16'h5183,8'h80,8'h14);
        check_profile(132,16'h5186,8'h10,8'h09);
        check_profile(133,16'h5187,8'h10,8'h09);
        check_profile(134,16'h5188,8'h10,8'h09);
        check_profile(135,16'h5189,8'h40,8'h75);
        check_profile(136,16'h518a,8'h40,8'h54);
        check_profile(137,16'h518b,8'h00,8'he0);
        check_profile(138,16'h518c,8'h00,8'hb2);
        check_profile(139,16'h518d,8'h00,8'h42);
        check_profile(140,16'h518e,8'h00,8'h3d);
        check_profile(141,16'h518f,8'h20,8'h56);
        check_profile(142,16'h5190,8'h20,8'h46);
        check_profile(143,16'h5191,8'hff,8'hf8);
        check_profile(144,16'h5192,8'h00,8'h04);
        for(n=2;n<=254;n=n+1) begin
            rom_index=n;#1;
            if(!(n>=127 && n<=129) && !(n>=132 && n<=144))
                check(simple_word==legacy_word,"AWB selector preserves other configuration");
        end
        check(bad.table_rom.SIMPLE_AWB==0,"frontend propagates AWB selection");
        wait(config_done && bad_error);#1;
        check(!config_error && !bad_done,"success/error flags exclude each other");
        check(attempts==254 && accepted==253,"all 253 writes plus one transient retry");
        check(nack_injected,"transient NACK exercised near table end");
        check(bad_attempts==4,"permanent NACK stops after four attempts");
        check(dut.reg_index==254,"frontend includes final configuration register");
        check_reg(16'h3406,8'h00); // automatic AWB gain
        check_reg(16'h5181,8'h58);check_reg(16'h5182,8'h11);
        check_reg(16'h5183,8'h80);check_reg(16'h5184,8'h25);
        check_reg(16'h5186,8'h10);check_reg(16'h5187,8'h10);check_reg(16'h5188,8'h10);
        check_reg(16'h5189,8'h40);check_reg(16'h518a,8'h40);
        check_reg(16'h518b,8'h00);check_reg(16'h518c,8'h00);
        check_reg(16'h518d,8'h00);check_reg(16'h518e,8'h00);
        check_reg(16'h518f,8'h20);check_reg(16'h5190,8'h20);
        check_reg(16'h5191,8'hff);check_reg(16'h5192,8'h00);
        check_reg(16'h5001,8'ha3); // retain scaling, color matrix, SDE and AWB
        check_reg(16'h5588,8'h01);check_reg(16'h5583,8'h40);check_reg(16'h5584,8'h10);
        check_reg(16'h3503,8'h00);check_reg(16'h5308,8'h65); // existing B sharpening profile
        check_reg(16'h4300,8'h61);check_reg(16'h501f,8'h01); // RGB565 MSB first
        check_reg(16'h3808,8'h04);check_reg(16'h3809,8'h00); // 1024 pixels
        check_reg(16'h380a,8'h03);check_reg(16'h380b,8'h00); // 768 lines
        check_reg(16'h380c,8'h08);check_reg(16'h380d,8'hc0); // HTS 2240
        check_reg(16'h380e,8'h04);check_reg(16'h380f,8'hf8); // VTS 1272
        check_reg(16'h3034,8'h1a);check_reg(16'h3035,8'h11);check_reg(16'h3036,8'h3c);
        check_reg(16'h503d,8'h00); // live camera rather than test pattern
        repeat(100) @(posedge clk);
        check(attempts==254 && bad_attempts==4,"both terminal states stop SCCB traffic");
        if(errors) $fatal(1,"CAMERA_CONFIG failed: %0d errors",errors);
        $display("PASS CAMERA_CONFIG: 253 writes, simple/legacy AWB, transient/permanent NACK, format/timing preserved");
        $finish;
    end
    initial begin #80000000;$fatal(1,"CAMERA_CONFIG timeout");end
endmodule

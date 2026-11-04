`timescale 1ns/1ps
module top_sensor_binding_check;
    initial begin
        #1;
        if(tb_rgb332_top.dut.sensors.SAMPLE_TIMEOUT_CYCLES!=1024 ||
           tb_rgb332_top.dut.sensors.WINDOW_LOG2!=13 ||
           tb_rgb332_top.dut.sensors.SOUND_HIGH!=700 || tb_rgb332_top.dut.sensors.SOUND_LOW!=350 ||
           tb_rgb332_top.dut.sensors.QUIET_WINDOWS!=24 || tb_rgb332_top.dut.sensors.COOLDOWN_WINDOWS!=120 ||
           tb_rgb332_top.dut.sensors.EXIT_QUIET_WINDOWS!=72)
            $fatal(1,"A top-level sensor configuration mismatch");
        $display("PASS A top sensor binding: timeout1024; window8192; high700/low350; quiet24/exit72/cooldown120 unchanged");
    end
endmodule

`timescale 1ns/1ps
module tb_bilinear_large;
    tb_bilinear #(.OW(640),.OH(480),.LARGE(1)) full_frame_golden();
endmodule

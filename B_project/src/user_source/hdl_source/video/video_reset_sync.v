`timescale 1ns/1ps
// Asynchronous assertion; two destination edges to release reset.
module video_reset_sync(input clk, input arst_n, output rst_n);
    (* async_reg = "true" *) reg [1:0] release_ff;
    always @(posedge clk or negedge arst_n)
        if (!arst_n) release_ff <= 2'b00;
        else release_ff <= {release_ff[0],1'b1};
    assign rst_n = release_ff[1];
endmodule

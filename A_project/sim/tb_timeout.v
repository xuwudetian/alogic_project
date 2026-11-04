`timescale 1ns/1ps
module tb_timeout;
    reg clk=0,rst=1;
    wire [3:0] state;
    wire [7:0] error;
    wire commit,wr,cs;
    sd_card_bmp #(.CLK_FREQ_HZ(10)) dut(
        .clk(clk),.rst(rst),.next_toggle(1'b0),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(1'b0),.write_finish_toggle(1'b0),.write_overflow(1'b0),.write_ready(1'b1),
        .commit_toggle(commit),.write_buf_idx(),.disp_buf_idx(),.picture_id(),.state_code(state),
        .error_code(error),.auto_play(),.scaled_image(),.available_images(),.write_req(wr),
        .write_req_ack(1'b0),.write_en(),.write_data(),.write_v_flip(),
        .SD_nCS(cs),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1));
    always #5 clk=~clk;
    initial begin
        force dut.card_ready=0;
        repeat(3) @(negedge clk);rst=0;
        repeat(65) @(negedge clk);
        if(state!=10 || error!=8'h11 || commit || wr || !cs) $fatal(1,"no-card containment");
        rst=1;@(negedge clk);rst=0;
        repeat(4) @(negedge clk);
        if(error!=0 || state!=0) $fatal(1,"external reset recovery");
        $display("PASS timeout: missing card is contained, no incomplete frame commit, reset recovery");
        $finish;
    end
endmodule

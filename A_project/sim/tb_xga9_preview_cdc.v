`timescale 1ns/1ps
module tb_xga9_preview_cdc;
    reg clk=0,rst_n=1,source_request=0,ack=0,frame=0,browse=0,selection=0;
    reg [3:0] source_picture=0,target=0,shown=0;
    tri1 sensor_scl,sensor_sda,eth_mdio;
    integer i;
    always #10 clk=~clk;
    top #(.BOOT_HOLD_CYCLES(100)) dut(.clk(clk),.rst_n(rst_n),.key1(1'b1),.key2(1'b1),.key3(1'b1),.sw(4'd0),
        .sd_miso(1'b1),.sensor_scl(sensor_scl),.sensor_sda(sensor_sda),
        .eth_rx_clk(1'b0),.eth_rx_ctl(1'b0),.eth_rxd(4'd0),.eth_mdio(eth_mdio));
    task publish(input [3:0] next_picture);
        reg [3:0] previous_picture;reg previous_token;integer edge_count;
        begin
            previous_picture=source_picture;previous_token=source_request;
            @(negedge dut.video_clk);#3;source_picture=next_picture;source_request=!source_request;
            for(edge_count=1;edge_count<=3;edge_count=edge_count+1) begin
                @(posedge dut.video_clk);#1;
                if(dut.expand_card.pending_picture!==(edge_count<2 ? previous_picture : next_picture))
                    $fatal(1,"preview metadata not staged in2 pixel clocks, edge%0d",edge_count);
                if(dut.expand_card.request_toggle!==(edge_count<3 ? previous_token : source_request))
                    $fatal(1,"preview request not staged in3 pixel clocks, edge%0d",edge_count);
            end
        end
    endtask
    task frame_boundary;
        begin @(negedge dut.video_clk);frame=1;@(negedge dut.video_clk);frame=0;end
    endtask
    task select_picture(input [3:0] requested);
        begin
            @(negedge dut.video_clk);browse=1;repeat(3) @(negedge dut.video_clk);
            target=requested;selection=!selection;browse=0;repeat(3) @(negedge dut.video_clk);
            if(!dut.expand_active || dut.expand_moving || dut.expand_target!=requested) $fatal(1,"thumbnail selection precondition");
        end
    endtask
    initial begin
        wait(!dut.rst_video);
        force dut.commit_request=source_request;force dut.pending_picture=source_picture;force dut.commit_ack=ack;
        force dut.frame_tick=frame;force dut.browse=browse;force dut.select_toggle=selection;force dut.select_index=target;
        force dut.ready_frame=9'h1ff;force dut.directory=0;force dut.status_panel=0;force dut.alarm=0;
        force dut.physical_switches=4'd0;force dut.active_picture=shown;force dut.display_valid=1;
        repeat(8) @(negedge dut.video_clk);
        select_picture(5);publish(5);
        repeat(6) @(negedge dut.video_clk);
        if(dut.expand_moving || dut.expand_phase!=0) $fatal(1,"pending metadata caused mid-frame expansion");
        frame_boundary;if(dut.expand_moving) $fatal(1,"expansion began before display commit");
        shown=5;ack=source_request;repeat(3) @(negedge dut.video_clk);
        if(dut.expand_moving) $fatal(1,"commit changed animation before frame");
        frame_boundary;if(!dut.expand_moving || dut.expand_phase!=0) $fatal(1,"committed picture did not start on same next frame");
        // A different pending target cancels only at the next frame boundary.
        publish(8);repeat(4) @(negedge dut.video_clk);
        if(!dut.expand_active || !dut.expand_moving || dut.expand_phase!=0) $fatal(1,"new request changed active frame");
        frame_boundary;if(dut.expand_active || dut.expand_moving) $fatal(1,"new target not cancelled at frame");
        select_picture(8);shown=8;ack=source_request;frame_boundary;
        if(!dut.expand_moving) $fatal(1,"PIC9 synchronized commit failed");
        repeat(19) frame_boundary;
        if(!dut.expand_active || dut.expand_phase!=19) $fatal(1,"native expansion frame sequence changed");
        frame_boundary;if(dut.expand_active || dut.expand_moving) $fatal(1,"native expansion completion changed");
        @(negedge clk);#2;rst_n=0;#1;
        if(dut.preview_request_sync!==0 || dut.preview_picture_meta!==0 || dut.preview_picture_sync!==0)
            $fatal(1,"preview CDC reset");
        $display("PASS preview top CDC: metadata2 pixel clocks precedes request3, PIC6/PIC9 values, no mid-frame changes, commit begins on next frame, pending target cancellation and original20-frame finish, asynchronous reset; digital boundary models");$finish;
    end
    initial begin #100000;$fatal(1,"preview CDC timeout");end
endmodule

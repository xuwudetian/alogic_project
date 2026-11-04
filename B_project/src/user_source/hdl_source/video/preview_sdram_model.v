`timescale 1ns/1ps
`ifdef SIMULATION
// Command-level SDRAM model used by the preview regression, not a framebuffer
// shortcut. Checks EM638325 timing at 100 MHz, initialization, BL8, CL3, refresh,
// row ownership, DQ contention, and byte masks. Delays are integer SDRAM clocks.
module preview_sdram_model(
    input clk,input rst_n,input ras_n,input cas_n,input we_n,
    input [10:0] addr,input [1:0] ba,inout [31:0] dq,
    input cs_n,input [3:0] dm,input cke);
    reg [31:0] memory[0:2097151];
    reg [10:0] open_row[0:3];
    reg [3:0] row_open;
    integer activated[0:3],precharged[0:3],last_write[0:3];
    integer cycle,low_cke_cycles,last_refresh,refresh_commands,mode_cycle;
    integer writes,reads,read_delay,read_left,write_left;
    reg [20:0] read_pointer,write_pointer;
    reg [31:0] dq_out;
    reg dq_enable,mode_set,cke_seen;
    integer i,j;
    wire [3:0] command={cs_n,ras_n,cas_n,we_n};
    // EM638325 slow-grade CL3 tAC max is 5.4 ns. The controller must still
    // capture DQ one full SDRAM clock later (10 ns), then consume that register.
    assign #(5.4) dq=dq_enable ? dq_out : 32'bz;
    task store_word;
        input [20:0] pointer;
        begin
            if((^dq)===1'bx) $fatal(1,"SDRAM write has floating/contended DQ at %0t",$time);
            for(j=0;j<4;j=j+1) if(!dm[j]) memory[pointer][j*8+:8]=dq[j*8+:8];
            writes=writes+1;
        end
    endtask
    always @(posedge clk or negedge rst_n) begin
        // At time zero the top-level reset synchronizer may still be X for a
        // delta cycle, while the inverted memory clock already has an edge.
        // The device is not out of reset until reset is explicitly high.
        if(rst_n!==1'b1) begin
            cycle=0;low_cke_cycles=0;last_refresh=0;refresh_commands=0;mode_cycle=0;
            row_open=0;writes=0;reads=0;read_delay=0;read_left=0;write_left=0;
            dq_enable=0;dq_out=0;mode_set=0;cke_seen=0;read_pointer=0;write_pointer=0;
            for(i=0;i<4;i=i+1) begin
                open_row[i]=0;activated[i]=-100;precharged[i]=-100;last_write[i]=-100;
            end
        end else begin
            cycle=cycle+1;
            dq_enable=0;
            if(!cke) begin
                if(cke_seen) $fatal(1,"SDRAM unexpected clock suspend");
                low_cke_cycles=low_cke_cycles+1;
                if(dm!==4'hf || command!==4'b0111) $fatal(1,"SDRAM power wait must use CKE low, DQM high, NOP");
            end else begin
                if(!cke_seen) begin
                    if(low_cke_cycles<20000) $fatal(1,"SDRAM requires 200 us CKE-low initialization");
                    cke_seen=1;
                end
                if(mode_set && cycle-last_refresh>1560) $fatal(1,"SDRAM refresh deadline exceeded");
                if(write_left>0) begin
                    if(command!==4'b0111) $fatal(1,"SDRAM command interrupts write burst");
                    store_word(write_pointer);last_write[write_pointer[20:19]]=cycle;
                    write_pointer=write_pointer+1'b1;write_left=write_left-1;
                end
                if(read_delay>0) read_delay=read_delay-1;
                if(read_left>0 && read_delay==0) begin
                    dq_out=memory[read_pointer];dq_enable=1;
                    read_pointer=read_pointer+1'b1;read_left=read_left-1;reads=reads+1;
                end
                case(command)
                    4'b0011: begin
                        if(!mode_set || cycle-mode_cycle<2) $fatal(1,"SDRAM ACT before mode-register wait");
                        if(row_open[ba] || cycle-precharged[ba]<2 || cycle-last_refresh<7)
                            $fatal(1,"SDRAM invalid ACT/tRP/tRFC");
                        row_open[ba]=1;open_row[ba]=addr;activated[ba]=cycle;
                    end
                    4'b0100,4'b0101: begin
                        if(!row_open[ba] || cycle-activated[ba]<2) $fatal(1,"SDRAM column command before ACT/tRCD");
                        if(addr[10:8]!=0 || addr[2:0]!=0) $fatal(1,"SDRAM requires aligned BL8, manual precharge");
                        if(read_left!=0 || write_left!=0) $fatal(1,"SDRAM overlapping bursts");
                        if(command==4'b0100) begin
                            write_pointer={ba,open_row[ba],addr[7:0]};store_word(write_pointer);
                            last_write[ba]=cycle;write_pointer=write_pointer+1'b1;write_left=7;
                        end else begin
                            read_pointer={ba,open_row[ba],addr[7:0]};read_delay=3;read_left=8;
                        end
                    end
                    4'b0010: begin
                        if(read_left!=0 || write_left!=0) $fatal(1,"SDRAM PRE truncates burst");
                        for(i=0;i<4;i=i+1) if(addr[10] || ba==i) begin
                            if(row_open[i] && (cycle-activated[i]<5 || cycle-last_write[i]<2))
                                $fatal(1,"SDRAM PRE violates tRAS/tWR");
                            row_open[i]=0;precharged[i]=cycle;
                        end
                    end
                    4'b0001: begin
                        if(row_open!=0 || cycle-last_refresh<7) $fatal(1,"SDRAM refresh with open row/tRFC");
                        for(i=0;i<4;i=i+1) if(cycle-precharged[i]<2) $fatal(1,"SDRAM refresh before tRP");
                        last_refresh=cycle;refresh_commands=refresh_commands+1;
                    end
                    4'b0000: begin
                        if(row_open!=0 || addr!=11'h033 || ba!=0 || refresh_commands<2 || cycle-last_refresh<7)
                            $fatal(1,"SDRAM invalid initialization/MRS (expected BL8 CAS3)");
                        mode_set=1;mode_cycle=cycle;
                    end
                    4'b0111: ;
                    default:$fatal(1,"SDRAM unsupported command %b",command);
                endcase
            end
        end
    end
endmodule
`endif

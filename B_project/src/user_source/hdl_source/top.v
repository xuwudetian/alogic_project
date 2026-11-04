`include "model_status.vh"
module top(
 input clk,input rst_n,
 input cam_pclk,input cam_vsync,input cam_href,input [7:0] cam_data,
 output cam_rst_n,output cam_pwdn,output cam_scl,inout cam_sda,
 output HDMI_CLK_P,output HDMI_D2_P,output HDMI_D1_P,output HDMI_D0_P,
 input eth_rx_clk,input eth_rx_ctl,input [3:0] eth_rxd,
 output eth_tx_clk,output eth_tx_ctl,output [3:0] eth_txd,
 output eth_mdc,inout eth_mdio,output [1:0] net_led_n
);
 wire video_clk,serial_clk,mem_clk,mem_forward_clk,pll_locked,sys_rst_n,cam_domain_rst_n,video_rst_n,mem_rst_n;
 hx4s20_video_pll u_video_pll(.refclk(clk),.reset(!rst_n),
   .pixel_clk(video_clk),.serial_clk(serial_clk),.locked(pll_locked),.mem_clk(mem_clk),.mem_forward_clk(mem_forward_clk));
 wire clocks_ready=rst_n && pll_locked;
 reset_release sys_reset(clk,clocks_ready,sys_rst_n);
 reset_release cam_reset(cam_pclk,clocks_ready,cam_domain_rst_n);
 reset_release video_reset(video_clk,clocks_ready,video_rst_n);
 reset_release memory_reset(mem_clk,clocks_ready,mem_rst_n);
 wire camera_ok,camera_error,pixel_valid,frame_start;
 wire [15:0] pixel_rgb565;wire [9:0] pixel_x;wire [8:0] pixel_y;
 wire native_valid,native_frame_start;
 wire [15:0] native_rgb565;wire [9:0] native_x,native_y;
 ov5640_camera_frontend camera(
   .clk50(clk),.rst_n(sys_rst_n),.cam_pclk(cam_pclk),.cam_vsync(cam_vsync),
   .cam_href(cam_href),.cam_data(cam_data),.cam_rst_n(cam_rst_n),.cam_pwdn(cam_pwdn),
   .cam_scl(cam_scl),.cam_sda(cam_sda),.config_done(camera_ok),.config_error(camera_error),
   .pixel_valid(pixel_valid),.pixel_rgb565(pixel_rgb565),.pixel_x(pixel_x),.pixel_y(pixel_y),.frame_start(frame_start),
   .native_valid(native_valid),.native_rgb565(native_rgb565),.native_x(native_x),.native_y(native_y),
   .native_frame_start(native_frame_start));
 wire [23:0] preview_rgb,overlay_rgb;wire hs,vs,de,frame_valid;
 wire [9:0] vx,vy;
 camera_preview preview(
   .camera_clk(cam_pclk),.camera_rst_n(cam_domain_rst_n),.pixel_valid(native_valid),
   .pixel_rgb565(native_rgb565),.pixel_x(native_x),.pixel_y(native_y),.frame_start(native_frame_start),
   .mem_clk(mem_clk),.mem_rst_n(mem_rst_n),.mem_forward_clk(mem_forward_clk),
   .video_clk(video_clk),.video_rst_n(video_rst_n),.rgb(preview_rgb),.hs(hs),.vs(vs),.de(de),
   .x(vx),.y(vy),.frame_valid(frame_valid));
 wire load_valid,load_ready,start,busy,done;wire [11:0] load_addr;wire [23:0] load_rgb;
 wire [1:0] class_id;wire [31:0] frames_loaded,cycle_count;
 wire signed [31:0] logits0,logits1,logits2;
 roi_capture roi(
   .camera_clk(cam_pclk),.camera_rst_n(cam_domain_rst_n),.frame_start(frame_start),.pixel_valid(pixel_valid),
   .pixel_rgb565(pixel_rgb565),.pixel_x(pixel_x),.pixel_y(pixel_y),
   .clk(clk),.rst_n(sys_rst_n),.cnn_busy(busy),.load_ready(load_ready),
   .load_valid(load_valid),.load_addr(load_addr),.load_rgb(load_rgb),.start(start),.frames_loaded(frames_loaded));
 damage_mobilenet_int8 #(.REFINE(`MODEL_REFINE),.REFINE_KERNEL(`MODEL_REFINE_KERNEL),.TAIL_CHANNELS(`MODEL_TAIL_CHANNELS),.WEIGHTS_FILE(`MODEL_WEIGHTS_FILE),.BIAS_FILE(`MODEL_BIAS_FILE),.SHIFTS_FILE(`MODEL_SHIFTS_FILE)) cnn(
   .clk(clk),.rst_n(sys_rst_n),.load_valid(load_valid),.load_ready(load_ready),.load_addr(load_addr),
   .load_rgb(load_rgb),.start(start && `MODEL_TRAINED),.busy(busy),.done(done),.class_id(class_id),
   .logits0(logits0),.logits1(logits1),.logits2(logits2),.cycle_count(cycle_count));
 wire damage_alarm,damage_valid;wire [1:0] alarm_class;
 wire network_online,network_link,unused_remote_alarm,unused_remote_valid;
 wire camera_good=camera_ok && !camera_error && `MODEL_TRAINED;
 net_damage_filter detection_timer(.clk(clk),.rst(!sys_rst_n),.camera_good(camera_good),
   .result_done(done),.result_class(class_id),.alarm(damage_alarm),.valid(damage_valid),.last_class(alarm_class));
 net_endpoint #(.IS_B(1)) network(.clk(clk),.rst(!sys_rst_n),
   .local_flags({3'b000,alarm_class,camera_good,damage_valid,damage_alarm}),
   .eth_rx_clk(eth_rx_clk),.eth_rx_ctl(eth_rx_ctl),.eth_rxd(eth_rxd),
   .eth_tx_clk(eth_tx_clk),.eth_tx_ctl(eth_tx_ctl),.eth_txd(eth_txd),
   .eth_mdc(eth_mdc),.eth_mdio(eth_mdio),.remote_alarm(unused_remote_alarm),
   .online(network_online),.remote_valid(unused_remote_valid),.link_ok(network_link));
 // Keep immediate state-change transmission; retry the current state every
 // 10 ms so a lost first alarm packet does not wait a 100 ms heartbeat.
 // Only this B instance changes cadence. Shared wire protocol, A receiver,
 // inference freshness and the 3-second healthy-clear qualification are intact.
 defparam network.session.HEARTBEAT_MS=10;
 assign net_led_n={!(network_online && damage_valid),!network_link};
 wire display_valid;wire [1:0] display_class;
 (* async_reg="true" *) reg [1:0] camera_ok_sync,camera_error_sync;
 reg previous_vs,display_camera_ok,display_camera_error;
 wire frame_commit=previous_vs && !vs; // Beginning of vertical blanking.
 damage_result_display result_display(
   .clk(clk),.rst_n(sys_rst_n),.result_done(done),.result_class(class_id),
   .video_clk(video_clk),.video_rst_n(video_rst_n),.frame_commit(frame_commit),
   .display_valid(display_valid),.display_class(display_class));
 always @(posedge video_clk or negedge video_rst_n) begin
   if(!video_rst_n) begin
     camera_ok_sync<=0;camera_error_sync<=0;
     previous_vs<=1;display_camera_ok<=0;display_camera_error<=0;
   end else begin
     previous_vs<=vs;
     camera_ok_sync<={camera_ok_sync[0],camera_ok};
     camera_error_sync<={camera_error_sync[0],camera_error};
     if(frame_commit) begin display_camera_ok<=camera_ok_sync[1];display_camera_error<=camera_error_sync[1];end
   end
 end
 damage_overlay #(.MODEL_TRAINED(`MODEL_TRAINED),.MODEL_ACCEPTED(`MODEL_ACCEPTED),.WIDTH(1024),.HEIGHT(768)) osd(
   .rgb(preview_rgb),.de(de),.x(vx),.y(vy),.camera_ok(display_camera_ok),.camera_error(display_camera_error),
   .result_valid(display_valid),.severity(display_class),.rgb_out(overlay_rgb));
 // Register OSD and matching syncs together to keep the TMDS input path short.
 reg [23:0] tx_rgb;reg tx_hs,tx_vs,tx_de;
 always @(posedge video_clk or negedge video_rst_n) begin
   if(!video_rst_n) begin tx_rgb<=0;tx_hs<=1;tx_vs<=1;tx_de<=0;end
   else begin tx_rgb<=overlay_rgb;tx_hs<=hs;tx_vs<=vs;tx_de<=de;end
 end
 hdmi_dvi_tx hdmi(.pixel_clk(video_clk),.serial_clk(serial_clk),.rst_n(video_rst_n),
   .rgb(tx_rgb),.hs(tx_hs),.vs(tx_vs),.de(tx_de),
   .HDMI_CLK_P(HDMI_CLK_P),.HDMI_D2_P(HDMI_D2_P),.HDMI_D1_P(HDMI_D1_P),.HDMI_D0_P(HDMI_D0_P));
endmodule

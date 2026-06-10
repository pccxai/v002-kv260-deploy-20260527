`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "npu_interfaces.svh"

module tb_npu_core_wrapper_stage0_host_to_l2;
  logic clk_core = 1'b0;
  logic clk_axi = 1'b0;
  logic rst_n_core = 1'b0;
  logic rst_axi_n = 1'b0;
  logic i_clear = 1'b0;

  logic [11:0] s_axil_awaddr;
  logic        s_axil_awvalid;
  logic        s_axil_awready;
  logic [63:0] s_axil_wdata;
  logic [7:0]  s_axil_wstrb;
  logic        s_axil_wvalid;
  logic        s_axil_wready;
  logic [1:0]  s_axil_bresp;
  logic        s_axil_bvalid;
  logic        s_axil_bready;
  logic [11:0] s_axil_araddr;
  logic        s_axil_arvalid;
  logic        s_axil_arready;
  logic [63:0] s_axil_rdata;
  logic [1:0]  s_axil_rresp;
  logic        s_axil_rvalid;
  logic        s_axil_rready;

  logic [127:0] s_axis_hp0_tdata;
  logic         s_axis_hp0_tvalid;
  logic         s_axis_hp0_tready;
  logic [127:0] s_axis_hp1_tdata;
  logic         s_axis_hp1_tvalid;
  logic         s_axis_hp1_tready;
  logic [127:0] s_axis_hp2_tdata;
  logic         s_axis_hp2_tvalid;
  logic         s_axis_hp2_tready;
  logic [127:0] s_axis_hp3_tdata;
  logic         s_axis_hp3_tvalid;
  logic         s_axis_hp3_tready;

  logic [127:0] s_axis_acp_fmap_tdata;
  logic         s_axis_acp_fmap_tvalid;
  logic         s_axis_acp_fmap_tready;
  logic         s_axis_acp_fmap_tlast;
  logic [15:0]  s_axis_acp_fmap_tkeep;
  logic [127:0] m_axis_acp_result_tdata;
  logic         m_axis_acp_result_tvalid;
  logic         m_axis_acp_result_tready;
  logic         m_axis_acp_result_tlast;
  logic [15:0]  m_axis_acp_result_tkeep;

  int pass_count = 0;
  int fail_count = 0;

  always #1.25 clk_core = ~clk_core;
  always #2.00 clk_axi = ~clk_axi;

  npu_core_wrapper dut (
      .clk_core(clk_core),
      .rst_n_core(rst_n_core),
      .clk_axi(clk_axi),
      .rst_axi_n(rst_axi_n),
      .i_clear(i_clear),
      .s_axil_awaddr(s_axil_awaddr),
      .s_axil_awvalid(s_axil_awvalid),
      .s_axil_awready(s_axil_awready),
      .s_axil_wdata(s_axil_wdata),
      .s_axil_wstrb(s_axil_wstrb),
      .s_axil_wvalid(s_axil_wvalid),
      .s_axil_wready(s_axil_wready),
      .s_axil_bresp(s_axil_bresp),
      .s_axil_bvalid(s_axil_bvalid),
      .s_axil_bready(s_axil_bready),
      .s_axil_araddr(s_axil_araddr),
      .s_axil_arvalid(s_axil_arvalid),
      .s_axil_arready(s_axil_arready),
      .s_axil_rdata(s_axil_rdata),
      .s_axil_rresp(s_axil_rresp),
      .s_axil_rvalid(s_axil_rvalid),
      .s_axil_rready(s_axil_rready),
      .s_axis_hp0_tdata(s_axis_hp0_tdata),
      .s_axis_hp0_tvalid(s_axis_hp0_tvalid),
      .s_axis_hp0_tready(s_axis_hp0_tready),
      .s_axis_hp1_tdata(s_axis_hp1_tdata),
      .s_axis_hp1_tvalid(s_axis_hp1_tvalid),
      .s_axis_hp1_tready(s_axis_hp1_tready),
      .s_axis_hp2_tdata(s_axis_hp2_tdata),
      .s_axis_hp2_tvalid(s_axis_hp2_tvalid),
      .s_axis_hp2_tready(s_axis_hp2_tready),
      .s_axis_hp3_tdata(s_axis_hp3_tdata),
      .s_axis_hp3_tvalid(s_axis_hp3_tvalid),
      .s_axis_hp3_tready(s_axis_hp3_tready),
      .s_axis_acp_fmap_tdata(s_axis_acp_fmap_tdata),
      .s_axis_acp_fmap_tvalid(s_axis_acp_fmap_tvalid),
      .s_axis_acp_fmap_tready(s_axis_acp_fmap_tready),
      .s_axis_acp_fmap_tlast(s_axis_acp_fmap_tlast),
      .s_axis_acp_fmap_tkeep(s_axis_acp_fmap_tkeep),
      .m_axis_acp_result_tdata(m_axis_acp_result_tdata),
      .m_axis_acp_result_tvalid(m_axis_acp_result_tvalid),
      .m_axis_acp_result_tready(m_axis_acp_result_tready),
      .m_axis_acp_result_tlast(m_axis_acp_result_tlast),
      .m_axis_acp_result_tkeep(m_axis_acp_result_tkeep)
  );

  function automatic logic [63:0] encode_memset(
      input logic [1:0] dest_cache,
      input logic [5:0] dest_addr,
      input logic [15:0] a_value,
      input logic [15:0] b_value,
      input logic [15:0] c_value
  );
    encode_memset = {4'h3, dest_cache, dest_addr, a_value, b_value, c_value, 4'h0};
  endfunction

  function automatic logic [63:0] encode_memcpy(
      input logic from_device,
      input logic to_device,
      input logic [16:0] dest_addr,
      input logic [16:0] src_addr,
      input logic [16:0] aux_addr,
      input logic [5:0] shape_ptr_addr,
      input logic async_op
  );
    encode_memcpy = {
      4'h2, from_device, to_device, dest_addr, src_addr, aux_addr, shape_ptr_addr, async_op
    };
  endfunction

  task automatic check(input string name, input bit ok);
    begin
      if (ok) begin
        $display("PASS [%s]", name);
        pass_count++;
      end else begin
        $display("FAIL [%s]", name);
        fail_count++;
      end
    end
  endtask

  task automatic axil_write64(input logic [11:0] addr, input logic [63:0] data);
    begin
      @(negedge clk_core);
      s_axil_awaddr  = addr;
      s_axil_awvalid = 1'b1;
      s_axil_wdata   = data;
      s_axil_wstrb   = '1;
      s_axil_wvalid  = 1'b0;

      do @(posedge clk_core); while (s_axil_awready !== 1'b1);
      @(negedge clk_core);
      s_axil_awvalid = 1'b0;
      s_axil_wvalid  = 1'b1;

      do @(posedge clk_core); while (s_axil_wready !== 1'b1);
      @(negedge clk_core);
      s_axil_wvalid = 1'b0;
      s_axil_wdata  = '0;

      do @(posedge clk_core); while (s_axil_bvalid !== 1'b1);
      @(negedge clk_core);
    end
  endtask

  task automatic submit_program(input logic [63:0] word);
    begin
      axil_write64(12'h000, word);
      axil_write64(12'h008, 64'h1);
    end
  endtask

  task automatic send_acp_word(input logic [127:0] data);
    int cycles;
    begin
      cycles = 0;
      @(negedge clk_axi);
      s_axis_acp_fmap_tdata  = data;
      s_axis_acp_fmap_tkeep  = '1;
      s_axis_acp_fmap_tlast  = 1'b1;
      s_axis_acp_fmap_tvalid = 1'b1;

      do begin
        @(posedge clk_axi);
        cycles++;
        if (cycles > 1000) begin
          $display("ACP source handshake timeout ext_valid=%0b ext_ready=%0b wrapper_valid=%0b top_bridge_valid=%0b disp_wire_valid=%0b global_wire_valid=%0b buffer_local_valid=%0b buffer_local_ready=%0b cdc_s_valid=%0b",
                   s_axis_acp_fmap_tvalid,
                   s_axis_acp_fmap_tready,
                   dut.acp_fmap_inst.tvalid,
                   dut.u_pccx_npu_top.S_AXIS_ACP_FMAP.tvalid,
                   dut.u_pccx_npu_top.u_mem_dispatcher.S_AXIS_ACP_FMAP.tvalid,
                   dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.S_AXIS_ACP_FMAP.tvalid,
                   dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.s_acp_fmap_tvalid,
                   dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.s_acp_fmap_tready,
                   dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.S_AXIS_ACP_FMAP.tvalid);
          check("ACP source handshake", 1'b0);
          return;
        end
      end while (!(s_axis_acp_fmap_tvalid === 1'b1 && s_axis_acp_fmap_tready === 1'b1));
      $display("ACP source beat accepted after %0d axi cycles ext_valid=%0b ext_ready=%0b wrapper_valid=%0b top_port_valid=%0b top_bridge_valid=%0b disp_port_valid=%0b disp_wire_valid=%0b global_port_valid=%0b global_wire_valid=%0b buffer_local_valid=%0b buffer_local_ready=%0b cdc_s_valid=%0b cdc_s_ready=%0b",
               cycles,
               s_axis_acp_fmap_tvalid,
               s_axis_acp_fmap_tready,
               dut.acp_fmap_inst.tvalid,
               dut.u_pccx_npu_top.S_AXIS_ACP_FMAP.tvalid,
               dut.u_pccx_npu_top.S_AXIS_ACP_FMAP.tvalid,
               dut.u_pccx_npu_top.u_mem_dispatcher.S_AXIS_ACP_FMAP.tvalid,
               dut.u_pccx_npu_top.u_mem_dispatcher.S_AXIS_ACP_FMAP.tvalid,
               dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.S_AXIS_ACP_FMAP.tvalid,
               dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.S_AXIS_ACP_FMAP.tvalid,
               dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.s_acp_fmap_tvalid,
               dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.s_acp_fmap_tready,
               dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.S_AXIS_ACP_FMAP.tvalid,
               dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.S_AXIS_ACP_FMAP.tready);
      @(negedge clk_axi);
      s_axis_acp_fmap_tvalid = 1'b0;
      s_axis_acp_fmap_tlast  = 1'b0;
      s_axis_acp_fmap_tdata  = '0;
      for (int post = 0; post < 6; post++) begin
        @(posedge clk_axi);
        $display("ACP post[%0d] fifo_rst=%0b rx_wr_en=%0b rx_wr_ack=%0b rx_wcnt=%0d rx_rcnt=%0d rx_full=%0b rx_empty=%0b rx_dv=%0b rx_ovf=%0b rx_udf=%0b rx_wr_busy=%0b rx_rd_busy=%0b wrapper_rx_valid=%0b wrapper_rx_present=%0b wrapper_rx_last=%0b wrapper_rx_keep=%04x wrapper_valid=%0b top_bridge_valid=%0b top_bridge_last=%0b top_bridge_keep=%04x disp_wire_valid=%0b disp_wire_last=%0b disp_wire_keep=%04x global_wire_valid=%0b global_wire_last=%0b global_wire_keep=%04x buffer_local_valid=%0b buffer_local_last=%0b buffer_local_keep=%04x buffer_rx_valid=%0b buffer_rx_present=%0b buffer_rx_last=%0b buffer_rx_keep=%04x buffer_m_valid=%0b rx_tvalid=%0b rx_fire=%0b",
                 post,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.fifo_rst,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_wr_en,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_wr_ack,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_wr_data_count,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_rd_data_count,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_full,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_empty,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_data_valid,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_overflow,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_underflow,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_wr_rst_busy,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_rd_rst_busy,
                 dut.acp_fmap_rx_tvalid,
                 dut.acp_fmap_rx_present,
                 dut.acp_fmap_rx_tlast,
                 dut.acp_fmap_rx_tkeep,
                 dut.acp_fmap_inst.tvalid,
                 dut.u_pccx_npu_top.S_AXIS_ACP_FMAP.tvalid,
                 dut.u_pccx_npu_top.S_AXIS_ACP_FMAP.tlast,
                 dut.u_pccx_npu_top.S_AXIS_ACP_FMAP.tkeep,
                 dut.u_pccx_npu_top.u_mem_dispatcher.S_AXIS_ACP_FMAP.tvalid,
                 dut.u_pccx_npu_top.u_mem_dispatcher.S_AXIS_ACP_FMAP.tlast,
                 dut.u_pccx_npu_top.u_mem_dispatcher.S_AXIS_ACP_FMAP.tkeep,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.S_AXIS_ACP_FMAP.tvalid,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.S_AXIS_ACP_FMAP.tlast,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.S_AXIS_ACP_FMAP.tkeep,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.s_acp_fmap_tvalid,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.s_acp_fmap_tlast,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.s_acp_fmap_tkeep,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_slice_tvalid,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_slice_present,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_slice_tlast,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_slice_tkeep,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.m_core_acp_rx_tvalid,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.core_acp_rx_bus.tvalid,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.acp_rx_fire);
      end
      for (int cpost = 0; cpost < 80; cpost++) begin
        @(posedge clk_core);
        $display("ACP corepost[%0d] busy=%0b acp_ptr=%0d rx_empty=%0b rx_dv=%0b rx_wcnt=%0d rx_rcnt=%0d rx_rd_en=%0b rx_core_load=%0b rx_hold_valid=%0b buffer_m_valid=%0b bus_valid=%0b bus_ready=%0b rx_fire=%0b rx_rd_busy=%0b rx_dout=%032x rx_hold=%032x",
                 cpost,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.acp_is_busy,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.acp_ptr,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_empty,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_data_valid,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_wr_data_count,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_rd_data_count,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_rd_en,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_core_load,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_core_hold_tvalid,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.m_core_acp_rx_tvalid,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.core_acp_rx_bus.tvalid,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.core_acp_rx_bus.tready,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.acp_rx_fire,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_rd_rst_busy,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_dout,
                 dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_core_hold_tdata);
        if (dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.acp_rx_fire) begin
          $display("ACP corepost fire observed at %0d", cpost);
        end
      end
    end
  endtask

  task automatic dump_state(input string label);
    begin
      $display(
          "%s: mem_debug=0x%04x l2_debug=0x%04x acp_busy=%0b acp_ptr=%0d acp_end=%0d acp_we=%0b ext_valid=%0b ext_ready=%0b wrapper_valid=%0b top_port_valid=%0b top_bridge_valid=%0b disp_port_valid=%0b disp_wire_valid=%0b global_port_valid=%0b global_wire_valid=%0b buffer_local_valid=%0b buffer_local_ready=%0b rx_wr_en=%0b rx_wr_ack=%0b rx_wcnt=%0d rx_rcnt=%0d rx_empty=%0b rx_dv=%0b buffer_m_valid=%0b cdc_s_valid=%0b cdc_s_ready=%0b rx_tvalid=%0b rx_tready=%0b rx_fire=%0b",
          label,
          dut.u_pccx_npu_top.u_mem_dispatcher.OUT_debug_status,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.OUT_debug_status,
          dut.u_pccx_npu_top.u_mem_dispatcher.acp_is_busy_wire,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.acp_ptr,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.acp_end_addr,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.acp_write_en,
          s_axis_acp_fmap_tvalid,
          s_axis_acp_fmap_tready,
          dut.acp_fmap_inst.tvalid,
          dut.u_pccx_npu_top.S_AXIS_ACP_FMAP.tvalid,
          dut.u_pccx_npu_top.S_AXIS_ACP_FMAP.tvalid,
          dut.u_pccx_npu_top.u_mem_dispatcher.S_AXIS_ACP_FMAP.tvalid,
          dut.u_pccx_npu_top.u_mem_dispatcher.S_AXIS_ACP_FMAP.tvalid,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.S_AXIS_ACP_FMAP.tvalid,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.S_AXIS_ACP_FMAP.tvalid,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.s_acp_fmap_tvalid,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.s_acp_fmap_tready,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_wr_en,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_wr_ack,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_wr_data_count,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_rd_data_count,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_empty,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.rx_fifo_data_valid,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.m_core_acp_rx_tvalid,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.S_AXIS_ACP_FMAP.tvalid,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.u_acp_cdc.S_AXIS_ACP_FMAP.tready,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.core_acp_rx_bus.tvalid,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.core_acp_rx_bus.tready,
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.acp_rx_fire
      );
    end
  endtask

  initial begin
    $display("=== tb_npu_core_wrapper_stage0_host_to_l2 start ===");

    s_axil_awaddr = '0;
    s_axil_awvalid = 1'b0;
    s_axil_wdata = '0;
    s_axil_wstrb = '0;
    s_axil_wvalid = 1'b0;
    s_axil_bready = 1'b1;
    s_axil_araddr = '0;
    s_axil_arvalid = 1'b0;
    s_axil_rready = 1'b1;

    s_axis_hp0_tdata = '0;
    s_axis_hp0_tvalid = 1'b0;
    s_axis_hp1_tdata = '0;
    s_axis_hp1_tvalid = 1'b0;
    s_axis_hp2_tdata = '0;
    s_axis_hp2_tvalid = 1'b0;
    s_axis_hp3_tdata = '0;
    s_axis_hp3_tvalid = 1'b0;

    s_axis_acp_fmap_tdata = '0;
    s_axis_acp_fmap_tvalid = 1'b0;
    s_axis_acp_fmap_tlast = 1'b0;
    s_axis_acp_fmap_tkeep = '1;
    m_axis_acp_result_tready = 1'b1;

    #100;
    rst_n_core = 1'b1;
    rst_axi_n  = 1'b1;
    repeat (20) @(posedge clk_core);
    repeat (20) @(posedge clk_axi);

    submit_program(encode_memset(2'd0, 6'd0, 16'd8, 16'd1, 16'd1));
    repeat (40) @(posedge clk_core);
    dump_state("after memset");

    submit_program(encode_memcpy(1'b1, 1'b0, 17'h00100, 17'd0, 17'd0, 6'd0, 1'b0));

    for (int i = 0; i < 200; i++) begin
      @(posedge clk_core);
      if (dut.u_pccx_npu_top.u_mem_dispatcher.acp_is_busy_wire === 1'b1) begin
        $display("ACP busy asserted after %0d core cycles", i);
        break;
      end
      if (i == 199) begin
        dump_state("descriptor timeout");
        check("ACP descriptor starts", 1'b0);
      end
    end

    for (int i = 0; i < 200; i++) begin
      @(posedge clk_core);
      if (dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.acp_write_en === 1'b1 &&
          dut.u_pccx_npu_top.u_mem_dispatcher.u_l2_cache.core_acp_rx_bus.tready === 1'b1) begin
        $display("ACP write datapath ready after %0d core cycles", i);
        break;
      end
      if (i == 199) begin
        dump_state("write datapath ready timeout");
        check("ACP write datapath becomes ready", 1'b0);
      end
    end

    dump_state("before acp beat");
    send_acp_word(128'h0123_4567_89ab_cdef_0011_2233_4455_6677);
    repeat (20) @(posedge clk_core);
    dump_state("after acp beat");

    for (int i = 0; i < 2000; i++) begin
      @(posedge clk_core);
      if (dut.u_pccx_npu_top.u_mem_dispatcher.acp_is_busy_wire === 1'b0) begin
        $display("ACP busy deasserted after %0d core cycles", i);
        check("HOST->L2 one-word ACP write completes", 1'b1);
        break;
      end
      if (i == 1999) begin
        dump_state("busy timeout");
        check("HOST->L2 one-word ACP write completes", 1'b0);
      end
    end

    $display("");
    $display("=== Summary ===");
    $display("PASS: %0d / %0d", pass_count, pass_count + fail_count);
    $display("FAIL: %0d", fail_count);
    if (fail_count == 0) begin
      $display("OVERALL: PASS");
      $finish;
    end
    $display("OVERALL: FAIL");
    $finish;
  end

  initial begin
    #2ms;
    dump_state("watchdog");
    check("watchdog", 1'b0);
    $display("OVERALL: FAIL");
    $finish;
  end
endmodule

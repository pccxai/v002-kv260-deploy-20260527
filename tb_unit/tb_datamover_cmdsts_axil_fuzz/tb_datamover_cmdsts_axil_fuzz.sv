`timescale 1ns / 1ps

module tb_datamover_cmdsts_axil_fuzz;
  localparam int AXIL_ADDR_W = 12;
  localparam int AXIL_DATA_W = 32;
  localparam int CMD_WIDTH   = 80;
  localparam int STS_WIDTH   = 8;
  localparam int FIFO_DEPTH  = 4;
  localparam int TOTAL_CMDS  = 96;
  localparam int STATUS_ROUNDS = 24;

  localparam logic [11:0] CMD_LO   = 12'h000;
  localparam logic [11:0] CMD_HI   = 12'h004;
  localparam logic [11:0] CMD_EXT  = 12'h008;
  localparam logic [11:0] CMD_PUSH = 12'h00c;
  localparam logic [11:0] STS_POP  = 12'h010;
  localparam logic [11:0] FLAGS    = 12'h014;
  localparam logic [11:0] CMD_LVL  = 12'h018;
  localparam logic [11:0] STS_LVL  = 12'h01c;
  localparam logic [11:0] ERR_W1C  = 12'h020;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  logic [AXIL_ADDR_W-1:0]     awaddr;
  logic                       awvalid;
  logic                       awready;
  logic [AXIL_DATA_W-1:0]     wdata;
  logic [(AXIL_DATA_W/8)-1:0] wstrb;
  logic                       wvalid;
  logic                       wready;
  logic [1:0]                 bresp;
  logic                       bvalid;
  logic                       bready;
  logic [AXIL_ADDR_W-1:0]     araddr;
  logic                       arvalid;
  logic                       arready;
  logic [AXIL_DATA_W-1:0]     rdata;
  logic [1:0]                 rresp;
  logic                       rvalid;
  logic                       rready;

  logic [CMD_WIDTH-1:0]       cmd_tdata;
  logic                       cmd_tvalid;
  logic                       cmd_tready;

  logic [STS_WIDTH-1:0]       sts_tdata;
  logic                       sts_tvalid;
  logic                       sts_tready;
  logic                       sts_tlast;
  logic [(STS_WIDTH+7)/8-1:0] sts_tkeep;

  logic [CMD_WIDTH-1:0]       expected_cmd [0:TOTAL_CMDS-1];
  int                         exp_cmd_wr;
  int                         exp_cmd_rd;
  int                         cmd_ready_cycle;
  int                         timeout_cycles;
  logic                       hold_cmd_active;
  logic [CMD_WIDTH-1:0]       hold_cmd_data;

  always #5 clk = ~clk;

  datamover_cmdsts_axil #(
      .AXIL_ADDR_W(AXIL_ADDR_W),
      .AXIL_DATA_W(AXIL_DATA_W),
      .CMD_WIDTH(CMD_WIDTH),
      .STS_WIDTH(STS_WIDTH),
      .FIFO_DEPTH(FIFO_DEPTH)
  ) dut (
      .s_axil_aclk(clk),
      .s_axil_aresetn(rst_n),
      .s_axil_awaddr(awaddr),
      .s_axil_awvalid(awvalid),
      .s_axil_awready(awready),
      .s_axil_wdata(wdata),
      .s_axil_wstrb(wstrb),
      .s_axil_wvalid(wvalid),
      .s_axil_wready(wready),
      .s_axil_bresp(bresp),
      .s_axil_bvalid(bvalid),
      .s_axil_bready(bready),
      .s_axil_araddr(araddr),
      .s_axil_arvalid(arvalid),
      .s_axil_arready(arready),
      .s_axil_rdata(rdata),
      .s_axil_rresp(rresp),
      .s_axil_rvalid(rvalid),
      .s_axil_rready(rready),
      .m_axis_cmd_tdata(cmd_tdata),
      .m_axis_cmd_tvalid(cmd_tvalid),
      .m_axis_cmd_tready(cmd_tready),
      .s_axis_sts_tdata(sts_tdata),
      .s_axis_sts_tvalid(sts_tvalid),
      .s_axis_sts_tready(sts_tready),
      .s_axis_sts_tlast(sts_tlast),
      .s_axis_sts_tkeep(sts_tkeep)
  );

  task automatic fail(input string msg);
    begin
      $display("OVERALL: FAIL - %s", msg);
      $fatal(1, "%s", msg);
    end
  endtask

  task automatic expect_eq(input string name, input logic [127:0] got, input logic [127:0] exp);
    begin
      if (got !== exp) begin
        $display("FAIL: %s got=0x%032x expected=0x%032x", name, got, exp);
        fail(name);
      end
    end
  endtask

  function automatic logic [CMD_WIDTH-1:0] make_cmd(input int idx);
    begin
      make_cmd = '0;
      make_cmd[79:72] = 8'h80 | idx[7:0];
      make_cmd[71:64] = 8'h10 | idx[7:0];
      make_cmd[63:32] = 32'h2000_0000 ^ (idx[31:0] * 32'h0001_0101);
      make_cmd[31:0]  = 32'h4080_0000 + (idx[31:0] << 4);
    end
  endfunction

  task automatic axil_write(input logic [11:0] addr, input logic [31:0] data,
                            input logic [3:0] strb = 4'hf);
    begin
      @(negedge clk);
      awaddr  = addr;
      wdata   = data;
      wstrb   = strb;
      awvalid = 1'b1;
      wvalid  = 1'b1;
      bready  = 1'b1;
      wait (awready && wready);
      @(posedge clk);
      @(negedge clk);
      awvalid = 1'b0;
      wvalid  = 1'b0;
      wait (bvalid);
      if (bresp !== 2'b00) fail("AXI-Lite write BRESP");
      @(posedge clk);
      @(negedge clk);
      bready = 1'b0;
    end
  endtask

  task automatic axil_read(input logic [11:0] addr, output logic [31:0] data);
    begin
      @(negedge clk);
      araddr  = addr;
      arvalid = 1'b1;
      rready  = 1'b1;
      wait (arready);
      @(posedge clk);
      @(negedge clk);
      arvalid = 1'b0;
      wait (rvalid);
      if (rresp !== 2'b00) fail("AXI-Lite read RRESP");
      data = rdata;
      @(posedge clk);
      @(negedge clk);
      rready = 1'b0;
    end
  endtask

  task automatic reset_dut();
    begin
      awaddr = '0;
      awvalid = 1'b0;
      wdata = '0;
      wstrb = '0;
      wvalid = 1'b0;
      bready = 1'b0;
      araddr = '0;
      arvalid = 1'b0;
      rready = 1'b0;
      sts_tdata = '0;
      sts_tvalid = 1'b0;
      sts_tlast = 1'b0;
      sts_tkeep = '1;
      exp_cmd_wr = 0;
      exp_cmd_rd = 0;
      cmd_ready_cycle = 0;
      hold_cmd_active = 1'b0;
      hold_cmd_data = '0;
      rst_n = 1'b0;
      repeat (5) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic enqueue_expected_cmd(input logic [CMD_WIDTH-1:0] cmd);
    begin
      if (exp_cmd_wr >= TOTAL_CMDS) fail("expected command scoreboard overflow");
      expected_cmd[exp_cmd_wr] = cmd;
      exp_cmd_wr++;
    end
  endtask

  task automatic wait_cmd_space();
    logic [31:0] level;
    int guard;
    begin
      guard = 0;
      axil_read(CMD_LVL, level);
      while (level >= FIFO_DEPTH[31:0]) begin
        repeat (2) @(negedge clk);
        axil_read(CMD_LVL, level);
        guard++;
        if (guard > 64) fail("command FIFO did not drain");
      end
    end
  endtask

  task automatic push_cmd(input logic [CMD_WIDTH-1:0] cmd);
    begin
      wait_cmd_space();
      axil_write(CMD_LO,  cmd[31:0]);
      axil_write(CMD_HI,  cmd[63:32]);
      axil_write(CMD_EXT, cmd[79:64]);
      enqueue_expected_cmd(cmd);
      axil_write(CMD_PUSH, 32'h1);
    end
  endtask

  task automatic send_status(input logic [STS_WIDTH-1:0] status);
    int guard;
    begin
      guard = 0;
      @(negedge clk);
      sts_tdata  = status;
      sts_tvalid = 1'b1;
      sts_tlast  = 1'b1;
      sts_tkeep  = '1;
      while (!sts_tready) begin
        @(posedge clk);
        @(negedge clk);
        guard++;
        if (guard > 64) fail("status sink did not become ready");
      end
      @(posedge clk);
      @(negedge clk);
      sts_tvalid = 1'b0;
      sts_tdata  = '0;
      sts_tlast  = 1'b0;
    end
  endtask

  task automatic expect_status_pop(input logic [STS_WIDTH-1:0] exp);
    logic [31:0] rd;
    begin
      axil_read(STS_POP, rd);
      expect_eq("status ordered pop", rd[STS_WIDTH-1:0], exp);
    end
  endtask

  task automatic pending_status_release(input logic [STS_WIDTH-1:0] pending,
                                        input logic [STS_WIDTH-1:0] old_head);
    int guard;
    begin
      @(negedge clk);
      sts_tdata  = pending;
      sts_tvalid = 1'b1;
      sts_tlast  = 1'b1;
      sts_tkeep  = '1;
      if (sts_tready !== 1'b0) fail("status FIFO should be full before pending release");

      fork
        begin
          expect_status_pop(old_head);
        end
        begin
          guard = 0;
          while (!sts_tready) begin
            @(posedge clk);
            @(negedge clk);
            guard++;
            if (guard > 64) fail("pending status did not see ready");
          end
          @(posedge clk);
          @(negedge clk);
          sts_tvalid = 1'b0;
          sts_tdata  = '0;
          sts_tlast  = 1'b0;
        end
      join
    end
  endtask

  always @(negedge clk) begin
    if (!rst_n) begin
      cmd_tready <= 1'b0;
      cmd_ready_cycle <= 0;
    end else begin
      cmd_tready <= ((cmd_ready_cycle[1:0] != 2'b01) &&
                     (cmd_ready_cycle[3:0] != 4'hd));
      cmd_ready_cycle <= cmd_ready_cycle + 1;
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      exp_cmd_rd <= 0;
      hold_cmd_active <= 1'b0;
      hold_cmd_data <= '0;
    end else begin
      if (cmd_tvalid && !cmd_tready) begin
        if (hold_cmd_active && (cmd_tdata !== hold_cmd_data)) begin
          fail("command data changed while backpressured");
        end
        hold_cmd_active <= 1'b1;
        hold_cmd_data <= cmd_tdata;
      end else begin
        hold_cmd_active <= 1'b0;
      end

      if (cmd_tvalid && cmd_tready) begin
        if (exp_cmd_rd >= exp_cmd_wr) fail("unexpected command pop");
        if (cmd_tdata !== expected_cmd[exp_cmd_rd]) begin
          $display("FAIL: command pop order idx=%0d got=0x%020x expected=0x%020x",
                   exp_cmd_rd, cmd_tdata, expected_cmd[exp_cmd_rd]);
          fail("command pop order");
        end
        exp_cmd_rd <= exp_cmd_rd + 1;
      end
    end
  end

  initial begin
    logic [31:0] rd;
    logic [CMD_WIDTH-1:0] cmd;
    logic [7:0] base_status;
    logic [7:0] pending_status;

    reset_dut();

    axil_write(CMD_EXT, 32'h0000_abcd);
    axil_write(CMD_EXT, 32'h0000_0012, 4'b0001);
    axil_read(CMD_EXT, rd);
    expect_eq("partial CMD_EXT write strobe", rd, 32'h0000_ab12);

    for (int i = 0; i < TOTAL_CMDS; i++) begin
      cmd = make_cmd(i);
      push_cmd(cmd);
      if ((i % 9) == 4) begin
        axil_read(CMD_LVL, rd);
        if (rd > FIFO_DEPTH[31:0]) fail("CMD_LVL exceeded FIFO depth");
      end
    end

    timeout_cycles = 0;
    while (exp_cmd_rd < TOTAL_CMDS) begin
      @(negedge clk);
      timeout_cycles++;
      if (timeout_cycles > 1000) fail("command stream did not fully drain");
    end
    axil_read(CMD_LVL, rd);
    expect_eq("CMD_LVL after long-run drain", rd, 32'h0000_0000);

    for (int round = 0; round < STATUS_ROUNDS; round++) begin
      base_status = 8'h20 + (round[7:0] * 8'd8);
      for (int i = 0; i < FIFO_DEPTH; i++) begin
        send_status(base_status + i[7:0]);
      end

      axil_read(STS_LVL, rd);
      expect_eq("STS_LVL full during wrap fuzz", rd, FIFO_DEPTH[31:0]);
      if (sts_tready !== 1'b0) fail("status FIFO full did not deassert ready");

      if ((round % 3) == 1) begin
        pending_status = base_status + 8'h40;
        pending_status_release(pending_status, base_status);
        for (int i = 1; i < FIFO_DEPTH; i++) begin
          expect_status_pop(base_status + i[7:0]);
        end
        expect_status_pop(pending_status);
      end else begin
        for (int i = 0; i < FIFO_DEPTH; i++) begin
          expect_status_pop(base_status + i[7:0]);
        end
      end

      axil_read(STS_LVL, rd);
      expect_eq("STS_LVL empty after wrap round", rd, 32'h0000_0000);
    end

    axil_read(FLAGS, rd);
    if (rd[7:4] !== 4'h0) begin
      $display("FAIL: unexpected sticky error after legal fuzz raw=0x%08x", rd);
      fail("unexpected sticky error after legal fuzz");
    end

    $display("PASS: datamover_cmdsts_axil long-run command/status fuzz");
    $display("OVERALL: PASS");
    $finish;
  end
endmodule

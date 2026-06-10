`timescale 1ns / 1ps

module tb_datamover_cmdsts_axil;
  localparam int AXIL_ADDR_W = 12;
  localparam int AXIL_DATA_W = 32;
  localparam int CMD_WIDTH   = 80;
  localparam int STS_WIDTH   = 8;
  localparam int FIFO_DEPTH  = 4;

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
      $display("PASS: %s = 0x%032x", name, got);
    end
  endtask

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

  task automatic push_status(input logic [7:0] status);
    begin
      @(negedge clk);
      sts_tdata  = status;
      sts_tvalid = 1'b1;
      sts_tlast  = 1'b1;
      sts_tkeep  = '1;
      @(posedge clk);
      @(negedge clk);
      sts_tvalid = 1'b0;
      sts_tdata  = '0;
      sts_tlast  = 1'b0;
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
      cmd_tready = 1'b0;
      sts_tdata = '0;
      sts_tvalid = 1'b0;
      sts_tlast = 1'b0;
      sts_tkeep = '1;
      rst_n = 1'b0;
      repeat (5) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
    end
  endtask

  initial begin
    logic [31:0] rd;
    logic [79:0] expected_cmd;
    logic [79:0] expected_cmds [0:FIFO_DEPTH-1];

    reset_dut();

    axil_read(FLAGS, rd);
    expect_eq("reset flags cmd_empty/sts_empty", rd, 32'h0000_0005);

    axil_write(CMD_LO,  32'h4080_0040);
    axil_write(CMD_HI,  32'h1234_5678);
    axil_write(CMD_EXT, 32'h0000_ff0a);
    axil_read(CMD_EXT, rd);
    expect_eq("CMD_EXT readback preserves xUSER/xCACHE/tag", rd, 32'h0000_ff0a);

    expected_cmd = 80'hff0a_1234_5678_4080_0040;
    axil_write(CMD_PUSH, 32'h0000_0001);
    repeat (2) @(negedge clk);
    expect_eq("command AXIS valid", cmd_tvalid, 1'b1);
    expect_eq("80-bit command word", cmd_tdata, expected_cmd);
    axil_read(CMD_LVL, rd);
    expect_eq("CMD_LVL after one push", rd, 32'h0000_0001);

    @(negedge clk);
    cmd_tready = 1'b1;
    @(negedge clk);
    cmd_tready = 1'b0;
    axil_read(CMD_LVL, rd);
    expect_eq("CMD_LVL after one pop", rd, 32'h0000_0000);

    push_status(8'h1a);
    axil_read(STS_LVL, rd);
    expect_eq("STS_LVL after status push", rd, 32'h0000_0001);
    axil_read(STS_POP, rd);
    expect_eq("STS_POP returns full status byte", rd, 32'h0000_001a);
    axil_read(STS_LVL, rd);
    expect_eq("STS_LVL after status pop", rd, 32'h0000_0000);

    for (int i = 0; i < FIFO_DEPTH; i++) begin
      axil_write(CMD_LO, 32'h4080_0010 + i[31:0]);
      axil_write(CMD_HI, 32'h2000_0000 + i[31:0]);
      axil_write(CMD_EXT, {16'h0, 12'hab0, i[3:0]});
      axil_write(CMD_PUSH, 32'h1);
    end
    axil_read(CMD_LVL, rd);
    expect_eq("CMD_LVL full", rd, FIFO_DEPTH[31:0]);
    axil_write(CMD_PUSH, 32'h1);
    axil_read(FLAGS, rd);
    if (!(rd[1] && rd[4])) begin
      $display("FAIL: full/overflow flags raw=0x%08x", rd);
      fail("command overflow flags");
    end
    $display("PASS: command overflow sets cmd_full and err_sticky[0]");

    @(negedge clk);
    cmd_tready = 1'b1;
    repeat (FIFO_DEPTH + 1) @(negedge clk);
    cmd_tready = 1'b0;
    axil_write(ERR_W1C, 32'h0000_000f);
    axil_read(ERR_W1C, rd);
    expect_eq("ERR_W1C clears sticky flags", rd, 32'h0000_0000);

    for (int i = 0; i < FIFO_DEPTH; i++) begin
      push_status(8'h10 | i[3:0]);
    end
    @(negedge clk);
    if (sts_tready !== 1'b0) fail("status FIFO full should deassert tready");
    sts_tdata  = 8'h7e;
    sts_tvalid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sts_tvalid = 1'b0;
    axil_read(FLAGS, rd);
    if (rd[5]) begin
      $display("FAIL: status backpressure should not set overflow sticky raw=0x%08x", rd);
      fail("status backpressure sticky flag");
    end
    $display("PASS: status full deasserts ready without sticky overflow");

    for (int i = 0; i < FIFO_DEPTH; i++) begin
      axil_read(STS_POP, rd);
      expect_eq("status FIFO ordered pop", rd[7:0], (8'h10 | i[3:0]));
    end
    axil_write(ERR_W1C, 32'h0000_000f);
    axil_read(STS_POP, rd);
    axil_read(ERR_W1C, rd);
    if (!rd[2]) fail("empty status pop should set err_sticky[2]");
    $display("PASS: empty status pop sets err_sticky[2]");

    reset_dut();
    for (int i = 0; i < FIFO_DEPTH; i++) begin
      expected_cmds[i] = {16'hcd00 | i[15:0], 32'h3000_0000 + i[31:0],
                          32'h4080_0020 + i[31:0]};
      axil_write(CMD_LO,  expected_cmds[i][31:0]);
      axil_write(CMD_HI,  expected_cmds[i][63:32]);
      axil_write(CMD_EXT, expected_cmds[i][79:64]);
      axil_write(CMD_PUSH, 32'h1);
    end
    repeat (4) @(negedge clk);
    expect_eq("command stays valid under backpressure", cmd_tvalid, 1'b1);
    expect_eq("command data stable under backpressure", cmd_tdata, expected_cmds[0]);
    for (int i = 0; i < FIFO_DEPTH; i++) begin
      expect_eq("command FIFO pop order under ready gaps", cmd_tdata, expected_cmds[i]);
      @(negedge clk);
      cmd_tready = 1'b1;
      @(negedge clk);
      cmd_tready = 1'b0;
      repeat (2) @(negedge clk);
    end
    axil_read(CMD_LVL, rd);
    expect_eq("CMD_LVL after gapped ready pops", rd, 32'h0000_0000);

    reset_dut();
    for (int i = 0; i < FIFO_DEPTH; i++) begin
      push_status(8'h40 | i[3:0]);
    end
    @(negedge clk);
    if (sts_tready !== 1'b0) fail("status backpressure should hold tready low when full");
    sts_tdata  = 8'h7e;
    sts_tvalid = 1'b1;
    sts_tlast  = 1'b1;
    sts_tkeep  = '1;
    repeat (2) @(negedge clk);
    if (sts_tready !== 1'b0) fail("pending status must not handshake while FIFO full");
    axil_read(STS_POP, rd);
    expect_eq("status pop opens one slot", rd[7:0], 8'h40);
    @(negedge clk);
    sts_tvalid = 1'b0;
    sts_tdata  = '0;
    sts_tlast  = 1'b0;
    for (int i = 1; i < FIFO_DEPTH; i++) begin
      axil_read(STS_POP, rd);
      expect_eq("status FIFO preserves old entries before pending accepted", rd[7:0], (8'h40 | i[3:0]));
    end
    axil_read(STS_POP, rd);
    expect_eq("pending status accepted after backpressure releases", rd[7:0], 8'h7e);

    $display("OVERALL: PASS");
    $finish;
  end
endmodule

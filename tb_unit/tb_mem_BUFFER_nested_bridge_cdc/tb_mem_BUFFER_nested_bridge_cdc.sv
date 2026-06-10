`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"
`include "npu_interfaces.svh"

module tb_mem_BUFFER_nested_bridge_cdc;
  localparam int SINGLE_BEATS = 1;
  localparam int BURST_BEATS = 16;

  logic clk_core = 1'b0;
  logic clk_axi = 1'b0;
  logic rst_n_core = 1'b0;
  logic rst_axi_n = 1'b0;

  axis_if #(.DATA_WIDTH(128)) rx_src();
  axis_if #(.DATA_WIDTH(128)) rx_b0();
  axis_if #(.DATA_WIDTH(128)) rx_b1();
  axis_if #(.DATA_WIDTH(128)) rx_b2();
  axis_if #(.DATA_WIDTH(128)) rx_dut();

  axis_if #(.DATA_WIDTH(128)) tx_core();
  axis_if #(.DATA_WIDTH(128)) tx_dut();
  axis_if #(.DATA_WIDTH(128)) tx_b0();
  axis_if #(.DATA_WIDTH(128)) tx_b1();
  axis_if #(.DATA_WIDTH(128)) tx_sink();

  axis_if #(.DATA_WIDTH(128)) core_rx();

  int pass_count = 0;
  int fail_count = 0;

  always #1.25 clk_core = ~clk_core;  // 400 MHz
  always #2.00 clk_axi = ~clk_axi;    // 250 MHz

  assign rx_b0.tdata = rx_src.tdata;
  assign rx_b0.tvalid = rx_src.tvalid;
  assign rx_b0.tlast = rx_src.tlast;
  assign rx_b0.tkeep = rx_src.tkeep;
  assign rx_src.tready = rx_b0.tready;

  assign rx_b1.tdata = rx_b0.tdata;
  assign rx_b1.tvalid = rx_b0.tvalid;
  assign rx_b1.tlast = rx_b0.tlast;
  assign rx_b1.tkeep = rx_b0.tkeep;
  assign rx_b0.tready = rx_b1.tready;

  assign rx_b2.tdata = rx_b1.tdata;
  assign rx_b2.tvalid = rx_b1.tvalid;
  assign rx_b2.tlast = rx_b1.tlast;
  assign rx_b2.tkeep = rx_b1.tkeep;
  assign rx_b1.tready = rx_b2.tready;

  assign rx_dut.tdata = rx_b2.tdata;
  assign rx_dut.tvalid = rx_b2.tvalid;
  assign rx_dut.tlast = rx_b2.tlast;
  assign rx_dut.tkeep = rx_b2.tkeep;
  assign rx_b2.tready = rx_dut.tready;

  assign tx_b0.tdata = tx_dut.tdata;
  assign tx_b0.tvalid = tx_dut.tvalid;
  assign tx_b0.tlast = tx_dut.tlast;
  assign tx_b0.tkeep = tx_dut.tkeep;
  assign tx_dut.tready = tx_b0.tready;

  assign tx_b1.tdata = tx_b0.tdata;
  assign tx_b1.tvalid = tx_b0.tvalid;
  assign tx_b1.tlast = tx_b0.tlast;
  assign tx_b1.tkeep = tx_b0.tkeep;
  assign tx_b0.tready = tx_b1.tready;

  assign tx_sink.tdata = tx_b1.tdata;
  assign tx_sink.tvalid = tx_b1.tvalid;
  assign tx_sink.tlast = tx_b1.tlast;
  assign tx_sink.tkeep = tx_b1.tkeep;
  assign tx_b1.tready = tx_sink.tready;

  mem_BUFFER dut (
      .clk_core(clk_core),
      .rst_n_core(rst_n_core),
      .clk_axi(clk_axi),
      .rst_axi_n(rst_axi_n),
      .S_AXIS_ACP_FMAP(rx_dut),
      .M_AXIS_ACP_RESULT(tx_dut),
      .M_CORE_ACP_RX(core_rx),
      .S_CORE_ACP_TX(tx_core)
  );

  function automatic logic [127:0] test_word(input int idx);
    logic [31:0] idx32;
    begin
      idx32 = idx;
      test_word = {
        32'hc001_0000 ^ idx32,
        32'hf00d_1000 + idx32,
        32'h1357_2468,
        32'h5a5a_0000 | idx32
      };
    end
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

  task automatic fail_now(input string msg);
    begin
      check(msg, 1'b0);
      $display("OVERALL: FAIL");
      $fatal(1, "%s", msg);
    end
  endtask

  task automatic axis_idle();
    begin
      rx_src.tdata = '0;
      rx_src.tvalid = 1'b0;
      rx_src.tlast = 1'b0;
      rx_src.tkeep = '1;
      core_rx.tready = 1'b0;
      tx_core.tdata = '0;
      tx_core.tvalid = 1'b0;
      tx_core.tlast = 1'b0;
      tx_core.tkeep = '1;
      tx_sink.tready = 1'b0;
    end
  endtask

  task automatic reset_dut();
    begin
      axis_idle();
      rst_n_core = 1'b0;
      rst_axi_n = 1'b0;
      #100;
      rst_n_core = 1'b1;
      rst_axi_n = 1'b1;
      repeat (20) @(posedge clk_core);
      repeat (20) @(posedge clk_axi);
      check("reset clears RX FIFO", dut.rx_fifo_empty && !dut.rx_fifo_wr_rst_busy && !dut.rx_fifo_rd_rst_busy);
      check("reset clears TX FIFO", dut.tx_fifo_empty && !dut.tx_fifo_wr_rst_busy && !dut.tx_fifo_rd_rst_busy);
    end
  endtask

  task automatic send_rx_burst(input int beats);
    int idx;
    int cycles;
    begin
      idx = 0;
      cycles = 0;
      @(negedge clk_axi);
      rx_src.tdata = test_word(0);
      rx_src.tkeep = '1;
      rx_src.tlast = (beats == 1);
      rx_src.tvalid = 1'b1;

      while (idx < beats) begin
        @(posedge clk_axi);
        cycles++;
        if (rx_src.tvalid && rx_src.tready) begin
          idx++;
          @(negedge clk_axi);
          if (idx < beats) begin
            rx_src.tdata = test_word(idx);
            rx_src.tlast = (idx == beats - 1);
          end else begin
            rx_src.tvalid = 1'b0;
            rx_src.tlast = 1'b0;
            rx_src.tdata = '0;
          end
        end

        if (cycles > 2000) begin
          $display("RX send timeout accepted=%0d/%0d src_ready=%0b dut_ready=%0b wr_en=%0b wr_ack=%0b full=%0b empty=%0b wcnt=%0d",
                   idx, beats, rx_src.tready, rx_dut.tready, dut.rx_fifo_wr_en, dut.rx_fifo_wr_ack,
                   dut.rx_fifo_full, dut.rx_fifo_empty, dut.rx_fifo_wr_data_count);
          fail_now("RX source handshake timeout");
        end
      end
      $display("PASS: RX source accepted %0d beats in %0d axi cycles", idx, cycles);
      pass_count++;
    end
  endtask

  task automatic expect_core_rx_burst(input int beats);
    int idx;
    int cycles;
    logic expected_last;
    begin
      idx = 0;
      cycles = 0;
      core_rx.tready = 1'b1;
      while (idx < beats) begin
        @(posedge clk_core);
        cycles++;
        if (core_rx.tvalid && core_rx.tready) begin
          expected_last = (idx == beats - 1);
          if (core_rx.tdata !== test_word(idx) ||
              core_rx.tkeep !== 16'hffff ||
              core_rx.tlast !== expected_last) begin
            $display("RX core mismatch idx=%0d data=0x%032x exp=0x%032x keep=%04x last=%0b exp_last=%0b",
                     idx, core_rx.tdata, test_word(idx), core_rx.tkeep, core_rx.tlast,
                     expected_last);
            fail_now("RX core payload mismatch");
          end
          idx++;
        end

        if (cycles > 4000) begin
          $display("RX core timeout seen=%0d/%0d valid=%0b ready=%0b empty=%0b data_valid=%0b wcnt=%0d rcnt=%0d",
                   idx, beats, core_rx.tvalid, core_rx.tready, dut.rx_fifo_empty,
                   dut.rx_fifo_data_valid, dut.rx_fifo_wr_data_count, dut.rx_fifo_rd_data_count);
          fail_now("RX core output timeout");
        end
      end
      core_rx.tready = 1'b0;
      $display("PASS: RX core produced %0d beats in %0d core cycles", idx, cycles);
      pass_count++;
    end
  endtask

  task automatic drive_tx_core_word(input logic [127:0] data);
    int cycles;
    begin
      cycles = 0;
      @(negedge clk_core);
      tx_core.tdata = data;
      tx_core.tkeep = 16'hffff;
      tx_core.tlast = 1'b1;
      tx_core.tvalid = 1'b1;

      do begin
        @(posedge clk_core);
        cycles++;
        if (cycles > 1000) begin
          $display("TX core timeout ready=%0b wr_en=%0b wr_ack=%0b full=%0b",
                   tx_core.tready, dut.tx_fifo_wr_en, dut.tx_fifo_wr_ack, dut.tx_fifo_full);
          fail_now("TX core handshake timeout");
        end
      end while (!(tx_core.tvalid && tx_core.tready));

      @(negedge clk_core);
      tx_core.tvalid = 1'b0;
      tx_core.tlast = 1'b0;
      tx_core.tdata = '0;
      $display("PASS: TX core accepted one beat in %0d core cycles", cycles);
      pass_count++;
    end
  endtask

  task automatic expect_tx_sink_word(input logic [127:0] expected);
    int cycles;
    begin
      cycles = 0;
      tx_sink.tready = 1'b1;
      do begin
        @(posedge clk_axi);
        cycles++;
        if (tx_sink.tvalid && tx_sink.tready) begin
          if (tx_sink.tdata !== expected || tx_sink.tkeep !== 16'hffff || tx_sink.tlast !== 1'b1) begin
            $display("TX sink mismatch data=0x%032x exp=0x%032x keep=%04x last=%0b",
                     tx_sink.tdata, expected, tx_sink.tkeep, tx_sink.tlast);
            fail_now("TX sink payload mismatch");
          end
          tx_sink.tready = 1'b0;
          $display("PASS: TX sink produced one beat in %0d axi cycles", cycles);
          pass_count++;
          return;
        end

        if (cycles > 2000) begin
          $display("TX sink timeout valid=%0b empty=%0b data_valid=%0b wcnt=%0d rcnt=%0d",
                   tx_sink.tvalid, dut.tx_fifo_empty, dut.tx_fifo_data_valid,
                   dut.tx_fifo_wr_data_count, dut.tx_fifo_rd_data_count);
          fail_now("TX sink output timeout");
        end
      end while (1);
    end
  endtask

  initial begin
    $display("=== tb_mem_BUFFER_nested_bridge_cdc start ===");
    reset_dut();

    send_rx_burst(SINGLE_BEATS);
    expect_core_rx_burst(SINGLE_BEATS);

    send_rx_burst(BURST_BEATS);
    expect_core_rx_burst(BURST_BEATS);

    drive_tx_core_word(128'hdeed_beef_0123_4567_fedc_ba98_7654_3210);
    expect_tx_sink_word(128'hdeed_beef_0123_4567_fedc_ba98_7654_3210);

    repeat (10) @(posedge clk_core);
    check("RX no overflow", !dut.rx_fifo_overflow);
    check("RX no underflow", !dut.rx_fifo_underflow);
    check("TX no overflow", !dut.tx_fifo_overflow);
    check("TX no underflow", !dut.tx_fifo_underflow);

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
    $display("watchdog timeout rx_empty=%0b rx_dv=%0b tx_empty=%0b tx_dv=%0b",
             dut.rx_fifo_empty, dut.rx_fifo_data_valid, dut.tx_fifo_empty, dut.tx_fifo_data_valid);
    fail_now("simulation watchdog timeout");
  end
endmodule

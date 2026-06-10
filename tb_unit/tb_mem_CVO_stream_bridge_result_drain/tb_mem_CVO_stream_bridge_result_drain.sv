`timescale 1ns / 1ps
`include "GLOBAL_CONST.svh"

module tb_mem_CVO_stream_bridge_result_drain;
  import isa_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  cvo_control_uop_t in_cvo_uop;
  logic             in_cvo_uop_valid;
  logic             out_busy;
  logic             out_done;

  logic             out_l2_valid;
  logic             out_l2_we;
  logic [16:0]      out_l2_addr;
  logic [127:0]     out_l2_wdata;
  logic [127:0]     in_l2_rdata;

  logic [15:0]      out_cvo_data;
  logic             out_cvo_valid;
  logic             in_cvo_data_ready;

  logic [15:0]      in_cvo_result;
  logic             in_cvo_result_valid;
  logic             out_cvo_result_ready;

  int pass_count = 0;
  int fail_count = 0;

  always #1.25 clk = ~clk;  // 400 MHz

  mem_CVO_stream_bridge dut (
      .clk(clk),
      .rst_n(rst_n),
      .IN_cvo_uop(in_cvo_uop),
      .IN_cvo_uop_valid(in_cvo_uop_valid),
      .OUT_busy(out_busy),
      .OUT_done(out_done),
      .OUT_l2_valid(out_l2_valid),
      .OUT_l2_we(out_l2_we),
      .OUT_l2_addr(out_l2_addr),
      .OUT_l2_wdata(out_l2_wdata),
      .IN_l2_rdata(in_l2_rdata),
      .OUT_cvo_data(out_cvo_data),
      .OUT_cvo_valid(out_cvo_valid),
      .IN_cvo_data_ready(in_cvo_data_ready),
      .IN_cvo_result(in_cvo_result),
      .IN_cvo_result_valid(in_cvo_result_valid),
      .OUT_cvo_result_ready(out_cvo_result_ready)
  );

  function automatic logic [15:0] result_word(input int idx);
    result_word = 16'h1000 + 16'(idx);
  endfunction

  function automatic logic [127:0] packed_descending(input int base_idx, input int count);
    logic [127:0] word;
    begin
      word = '0;
      for (int i = 0; i < count; i++) begin
        word[127-(i*16)-:16] = result_word(base_idx + count - 1 - i);
      end
      packed_descending = word;
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

  task automatic tick;
    @(posedge clk);
    #0.1;
  endtask

  task automatic reset_dut;
    begin
      in_cvo_uop = '0;
      in_cvo_uop_valid = 1'b0;
      in_l2_rdata = 128'h0007_0006_0005_0004_0003_0002_0001_0000;
      in_cvo_data_ready = 1'b1;
      in_cvo_result = '0;
      in_cvo_result_valid = 1'b0;
      rst_n = 1'b0;
      repeat (12) tick();
      rst_n = 1'b1;
      repeat (8) tick();
      check("reset leaves bridge idle", !out_busy && !out_l2_valid && !out_done);
    end
  endtask

  task automatic launch_uop(input cvo_func_e func, input logic [16:0] src_addr,
                            input logic [16:0] dst_addr, input logic [15:0] length);
    begin
      in_cvo_uop = '0;
      in_cvo_uop.cvo_func = func;
      in_cvo_uop.src_addr = src_addr;
      in_cvo_uop.dst_addr = dst_addr;
      in_cvo_uop.length = length;
      tick();
      in_cvo_uop_valid = 1'b1;
      tick();
      in_cvo_uop_valid = 1'b0;
      check("uop accepted busy", out_busy);
    end
  endtask

  task automatic wait_inputs_fed(input int expected);
    int seen;
    int cycles;
    begin
      seen = 0;
      cycles = 0;
      while (seen < expected) begin
        tick();
        cycles++;
        if (out_cvo_valid && in_cvo_data_ready) begin
          seen++;
        end
        if (cycles > 2000) begin
          $display("input feed timeout seen=%0d/%0d valid=%0b busy=%0b l2_valid=%0b l2_we=%0b",
                   seen, expected, out_cvo_valid, out_busy, out_l2_valid, out_l2_we);
          fail_now("CVO input feed timeout");
        end
      end
      $display("PASS: CVO input stream fed %0d elements in %0d cycles", seen, cycles);
      pass_count++;
    end
  endtask

  task automatic send_result(input int idx);
    int cycles;
    bit accepted;
    begin
      cycles = 0;
      accepted = 1'b0;
      in_cvo_result = result_word(idx);
      in_cvo_result_valid = 1'b1;
      do begin
        @(negedge clk);
        accepted = in_cvo_result_valid && out_cvo_result_ready;
        tick();
        cycles++;
        if (cycles > 2000) begin
          $display("result handshake timeout idx=%0d ready=%0b busy=%0b state=%0d total=%0d captured=%0d elems_result=%0d fifo_empty=%0b",
                   idx, out_cvo_result_ready, out_busy, dut.state, dut.total_results,
                   dut.results_captured, dut.elems_result, dut.fifo_empty);
          fail_now("CVO result handshake timeout");
        end
      end while (!accepted);
      $display("PASS: result[%0d] accepted state=%0d total=%0d captured=%0d",
               idx, dut.state, dut.total_results, dut.results_captured);
      in_cvo_result_valid = 1'b0;
      in_cvo_result = '0;
    end
  endtask

  task automatic expect_write(input int write_idx, input logic [127:0] expected);
    int cycles;
    begin
      cycles = 0;
      do begin
        tick();
        cycles++;
        if (out_l2_valid && out_l2_we) begin
          if (out_l2_wdata !== expected) begin
            $display("write[%0d] mismatch got=0x%032x exp=0x%032x addr=%0d",
                     write_idx, out_l2_wdata, expected, out_l2_addr);
            fail_now("L2 write payload mismatch");
          end
          $display("PASS: L2 write[%0d] data=0x%032x addr=%0d", write_idx, out_l2_wdata,
                   out_l2_addr);
          pass_count++;
          return;
        end
        if (cycles > 2000) begin
          fail_now("L2 write timeout");
        end
      end while (1);
    end
  endtask

  task automatic expect_done;
    int cycles;
    begin
      cycles = 0;
      while (!out_done) begin
        tick();
        cycles++;
        if (cycles > 2000) begin
          fail_now("bridge done timeout");
        end
      end
      check("bridge done pulse", out_done);
      tick();
      check("bridge returns idle", !out_busy);
    end
  endtask

  initial begin
    $display("=== tb_mem_CVO_stream_bridge_result_drain start ===");
    reset_dut();

    launch_uop(CVO_EXP, 17'd0, 17'd128, 16'd16);
    wait_inputs_fed(16);
    send_result(0);
    tick();
    check("bridge keeps accepting delayed results after first result",
          out_busy && out_cvo_result_ready && !out_l2_valid);
    for (int i = 1; i < 16; i++) begin
      send_result(i);
    end
    expect_write(0, packed_descending(0, 8));
    expect_write(1, packed_descending(8, 8));
    expect_done();

    launch_uop(CVO_EXP, 17'd0, 17'd160, 16'd5);
    wait_inputs_fed(5);
    for (int i = 0; i < 5; i++) begin
      send_result(i);
    end
    expect_write(0, packed_descending(0, 5));
    expect_done();

    launch_uop(CVO_REDUCE_SUM, 17'd0, 17'd192, 16'd16);
    wait_inputs_fed(16);
    send_result(0);
    expect_write(0, packed_descending(0, 1));
    expect_done();

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
    fail_now("simulation watchdog timeout");
  end
endmodule

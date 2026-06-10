`timescale 1ns / 1ps

module tb_CVO_top_result_backpressure_contract;
  import isa_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic i_clear = 1'b0;

  cvo_control_uop_t in_uop;
  logic             in_uop_valid;
  logic             out_uop_ready;

  logic [15:0]      in_data;
  logic             in_data_valid;
  logic             out_data_ready;

  logic [15:0]      out_result;
  logic             out_result_valid;
  logic             in_result_ready;

  logic [15:0]      in_e_max;
  logic             out_busy;
  logic             out_done;
  logic             out_accm;

  int pass_count = 0;
  int fail_count = 0;

  always #1.25 clk = ~clk;

  CVO_top dut (
      .clk(clk),
      .rst_n(rst_n),
      .i_clear(i_clear),
      .IN_uop(in_uop),
      .IN_uop_valid(in_uop_valid),
      .OUT_uop_ready(out_uop_ready),
      .IN_data(in_data),
      .IN_data_valid(in_data_valid),
      .OUT_data_ready(out_data_ready),
      .OUT_result(out_result),
      .OUT_result_valid(out_result_valid),
      .IN_result_ready(in_result_ready),
      .IN_e_max(in_e_max),
      .OUT_busy(out_busy),
      .OUT_done(out_done),
      .OUT_accm(out_accm)
  );

  task automatic tick;
    @(posedge clk);
    #0.1;
  endtask

  task automatic pass(input string name);
    begin
      pass_count++;
      $display("PASS: %s", name);
    end
  endtask

  task automatic fail(input string msg);
    begin
      fail_count++;
      $display("FAIL: %s", msg);
    end
  endtask

  task automatic finish_check;
    begin
      $display("PASS: %0d / %0d FAIL: %0d", pass_count, pass_count + fail_count, fail_count);
      if (fail_count == 0) begin
        $display("OVERALL: PASS");
      end else begin
        $display("OVERALL: FAIL");
      end
      $finish;
    end
  endtask

  task automatic reset_dut;
    begin
      in_uop = '0;
      in_uop.cvo_func = CVO_SQRT;
      in_uop.length = 16'd1;
      in_uop_valid = 1'b0;
      in_data = 16'h3f80;  // BF16 1.0
      in_data_valid = 1'b0;
      in_result_ready = 1'b1;
      in_e_max = 16'd0;
      i_clear = 1'b0;
      rst_n = 1'b0;
      repeat (8) tick();
      rst_n = 1'b1;
      repeat (4) tick();
    end
  endtask

  task automatic launch_one(input logic [15:0] data_word);
    int guard;
    begin
      guard = 0;
      while (!out_uop_ready) begin
        tick();
        guard++;
        if (guard > 64) begin
          fail("uop ready timeout");
          return;
        end
      end

      in_uop_valid = 1'b1;
      tick();
      in_uop_valid = 1'b0;

      in_data = data_word;
      in_data_valid = 1'b1;
      guard = 0;
      while (!out_data_ready) begin
        tick();
        guard++;
        if (guard > 64) begin
          fail("data ready timeout");
          in_data_valid = 1'b0;
          return;
        end
      end
      tick();
      in_data_valid = 1'b0;
    end
  endtask

  task automatic wait_result(output logic [15:0] result, output int wait_cycles);
    begin
      wait_cycles = 0;
      while (!out_result_valid && wait_cycles < 128) begin
        tick();
        wait_cycles++;
      end
      if (!out_result_valid) begin
        fail("result valid timeout");
        result = '0;
      end else begin
        result = out_result;
        pass("result valid observed");
      end
      tick();
    end
  endtask

  initial begin
    logic [15:0] baseline_result;
    logic [15:0] stalled_result;
    int baseline_wait;
    int stalled_wait;

    reset_dut();

    launch_one(16'h3f80);
    wait_result(baseline_result, baseline_wait);
    if (baseline_result == 16'd0) begin
      fail("baseline SQRT result should be non-zero");
    end else begin
      pass("baseline SQRT result is non-zero");
    end

    repeat (16) tick();

    launch_one(16'h3f80);
    in_result_ready = 1'b0;
    repeat (baseline_wait + 8) tick();
    if (out_result_valid) begin
      pass("result valid is held while result_ready is low");
    end else begin
      fail("result valid was not held under result_ready backpressure");
    end

    in_result_ready = 1'b1;
    wait_result(stalled_result, stalled_wait);
    if (stalled_result === baseline_result) begin
      pass("backpressured result matches baseline");
    end else begin
      fail($sformatf("backpressured result mismatch got=0x%04x expected=0x%04x",
                     stalled_result, baseline_result));
    end

    finish_check();
  end
endmodule

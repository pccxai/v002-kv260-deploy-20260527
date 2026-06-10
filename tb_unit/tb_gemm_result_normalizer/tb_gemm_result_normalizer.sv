`timescale 1ns / 1ps

module tb_gemm_result_normalizer;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic clear;
  logic [47:0] data_in;
  logic [7:0] e_max;
  logic valid_in;
  logic [15:0] data_out;
  logic valid_out;

  int pass_count = 0;
  int fail_count = 0;

  always #5 clk = ~clk;

  gemm_result_normalizer dut (
      .clk(clk),
      .rst_n(rst_n),
      .clear(clear),
      .data_in(data_in),
      .e_max(e_max),
      .valid_in(valid_in),
      .data_out(data_out),
      .valid_out(valid_out)
  );

  task automatic tick;
    begin
      @(posedge clk);
      #1;
    end
  endtask

  function automatic logic [15:0] expected_norm(input logic signed [47:0] din,
                                                input logic [7:0] emax);
    logic sign;
    logic [47:0] mag;
    int pos;
    logic [7:0] exp;
    logic [6:0] mant;
    begin
      sign = din[47];
      mag = sign ? (~din + 48'd1) : din;
      if (mag == 48'd0) begin
        expected_norm = 16'd0;
      end else begin
        pos = 0;
        for (int i = 46; i >= 0; i--) begin
          if (mag[i]) begin
            pos = i;
            break;
          end
        end
        exp = emax + pos[7:0] - 8'd26;
        if (pos >= 7) mant = (mag >> (pos - 7)) & 7'h7f;
        else          mant = (mag[6:0] << (7 - pos)) & 7'h7f;
        expected_norm = {sign, exp, mant};
      end
    end
  endfunction

  task automatic check_case(input string name, input logic signed [47:0] din,
                            input logic [7:0] emax);
    logic [15:0] exp;
    begin
      exp = expected_norm(din, emax);
      data_in = din;
      e_max = emax;
      valid_in = 1'b1;
      tick();
      valid_in = 1'b0;
      data_in = '0;
      e_max = '0;
      repeat (3) tick();
      if (valid_out !== 1'b1) begin
        $display("FAIL [%s]: valid_out not asserted", name);
        fail_count++;
      end else if (data_out !== exp) begin
        $display("FAIL [%s]: data_out=%h expected=%h", name, data_out, exp);
        fail_count++;
      end else begin
        $display("PASS [%s]: data_out=%h", name, data_out);
        pass_count++;
      end
      tick();
    end
  endtask

  initial begin
    $display("=== tb_gemm_result_normalizer start ===");
    clear = 1'b0;
    data_in = '0;
    e_max = '0;
    valid_in = 1'b0;
    repeat (4) tick();
    rst_n = 1'b1;
    repeat (2) tick();

    if (valid_out !== 1'b0 || data_out !== 16'd0) begin
      $display("FAIL [reset]: data_out=%h valid_out=%b", data_out, valid_out);
      fail_count++;
    end else begin
      $display("PASS [reset]");
      pass_count++;
    end

    check_case("zero", 48'sd0, 8'h80);
    check_case("one_bias80", 48'sd1, 8'h80);
    check_case("frac_pattern", 48'sd3, 8'h80);
    check_case("bit26_identity_exp", 48'sd67108864, 8'h80);
    check_case("negative_bit26", -48'sd67108864, 8'h80);
    check_case("large_positive", 48'sh0000_1234_5678, 8'h91);
    check_case("large_negative", -48'sh0000_0012_3456, 8'h88);

    data_in = 48'sd67108864;
    e_max = 8'h80;
    valid_in = 1'b1;
    tick();
    valid_in = 1'b0;
    data_in = '0;
    e_max = '0;
    clear = 1'b1;
    tick();
    clear = 1'b0;
    repeat (4) tick();
    if (valid_out !== 1'b0 || data_out !== 16'd0) begin
      $display("FAIL [clear_flush]: data_out=%h valid_out=%b", data_out, valid_out);
      fail_count++;
    end else begin
      $display("PASS [clear_flush]");
      pass_count++;
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
endmodule

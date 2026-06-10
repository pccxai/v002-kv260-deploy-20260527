# v002 Unit Testbench Results

**최종 실행**: 2026-06-03 03:34:57

| 모듈 | 결과 | 비고 |
|---|---|---|
| tb_AXIL_CMD_IN_inst_kick_one_shot | ✅ PASS | PASS: INST/KICK emits MEMCPY once and KICK once OVERALL: PASS  |
| tb_CVO_top_result_backpressure_contract | ✅ PASS | PASS: baseline SQRT result is non-zero PASS: result valid is held while result_ready is low PASS: result valid observed PASS: backpressured result matches baseline PASS: 5 / 5 FAIL: 0 OVERALL: PASS  |
| tb_FROM_gemm_result_packer | ✅ PASS | PASS: 8 / 8 FAIL: 0 OVERALL: PASS  |
| tb_GEMM_accumulator | ✅ PASS | PASS: 7 / 7 FAIL: 0 OVERALL: PASS  |
| tb_GEMM_dsp_packer | ✅ PASS | PASS: 4108 / 4108 FAIL: 0 OVERALL: PASS  |
| tb_GEMM_dsp_unit_smoke | ✅ PASS | PASS: 14 / 14 FAIL: 0 OVERALL: PASS  |
| tb_GEMM_fmap_staggered_dispatch | ✅ PASS | PASS: 63 / 63 FAIL: 0 OVERALL: PASS  |
| tb_GEMM_sign_recovery | ✅ PASS | PASS: 109 / 109 FAIL: 0 OVERALL: PASS  |
| tb_GEMM_systolic_weight_valid_contract | ✅ PASS | PASS: 5 / 5 FAIL: 0 OVERALL: PASS  |
| tb_GEMM_weight_dispatcher | ✅ PASS | PASS: 5 / 5 FAIL: 0 OVERALL: PASS  |
| tb_GEMV_accumulate_contract | ✅ PASS | PASS: post-completion idle keeps OUT_acc_valid low = 0 PASS: post-completion idle keeps OUT_acc_valid low = 0 PASS: post-completion idle keeps OUT_acc_valid low = 0 PASS: post-completion idle keeps OUT_acc_valid low = 0 PASS: 19 / 19 FAIL: 0 OVERALL: PASS  |
| tb_GEMV_reduction_contract | ✅ PASS | PASS: signed mixed LUT idle has no duplicate valid = 0 PASS: signed mixed LUT idle has no duplicate valid = 0 PASS: signed mixed LUT idle has no duplicate valid = 0 PASS: signed mixed LUT idle has no duplicate valid = 0 PASS: 44 / 44 FAIL: 0 OVERALL: PASS  |
| tb_GEMV_top_contract | ✅ PASS | PASS: post batches no duplicate valid = 0 PASS: post batches no duplicate valid = 0 PASS: post batches no duplicate valid = 0 PASS: post batches no duplicate valid = 0 PASS: 43 / 43 FAIL: 0 OVERALL: PASS  |
| tb_datamover_cmdsts_axil | ✅ PASS | PASS: status pop opens one slot = 0x00000000000000000000000000000040 PASS: status FIFO preserves old entries before pending accepted = 0x00000000000000000000000000000041 PASS: status FIFO preserves old entries before pending accepted = 0x00000000000000000000000000000042 PASS: status FIFO preserves old entries before pending accepted = 0x00000000000000000000000000000043 PASS: pending status accepted after backpressure releases = 0x0000000000000000000000000000007e OVERALL: PASS  |
| tb_datamover_cmdsts_axil_fuzz | ✅ PASS | PASS: datamover_cmdsts_axil long-run command/status fuzz OVERALL: PASS  |
| tb_gemm_result_normalizer | ✅ PASS | PASS: 8 / 8 FAIL: 0 OVERALL: PASS  |
| tb_mem_BUFFER_nested_bridge_cdc | ✅ PASS | PASS: 12 / 12 FAIL: 0 OVERALL: PASS  |
| tb_mem_CVO_stream_bridge_result_drain | ✅ PASS | PASS: 18 / 18 FAIL: 0 OVERALL: PASS  |
| tb_mem_GLOBAL_cache | ✅ PASS | PASS: ACP 4096B write ACP busy asserted after 0 cycles PASS: ACP 4096B write ACP busy deasserted after 12 cycles PASS: ACP 4096B read ACP busy asserted after 0 cycles PASS: ACP burst readback 256 beats PASS: ACP 4096B read ACP busy deasserted after 0 cycles OVERALL: PASS  |
| tb_mem_GLOBAL_cache_xpm_cdc_burst | ✅ PASS | PASS: ACP input accepted 256 beats in 511 axi cycles PASS: ACP 4096B write busy deasserted after 13 core cycles PASS: ACP 4096B read busy asserted after 0 core cycles PASS: ACP result produced 256 beats in 269 axi cycles PASS: ACP 4096B read busy deasserted after 0 core cycles OVERALL: PASS  |
| tb_mem_HP_buffer_sideband_contract | ✅ PASS | PASS: 24 / 24 FAIL: 0 OVERALL: PASS  |
| tb_mem_dispatcher_cvo_store_arbitration | ✅ PASS | PASS: 9 / 9 FAIL: 0 OVERALL: PASS  |
| tb_mem_dispatcher_route_contract | ✅ PASS | PASS: stage0 L2_to_host 4096B base = 256 PASS: stage0 L2_to_host 4096B end = 512 PASS: stage0 L2_to_host 4096B descriptor observed PASS: ACP burst readback 256 beats PASS: stage0 L2_to_host 4096B idle after 0 cycles OVERALL: PASS  |
| tb_npu_core_wrapper_stage0_host_to_l2 | ✅ PASS | PASS: 1 / 1 FAIL: 0 OVERALL: PASS  |
| tb_pccx_npu_top_idle_contract | ✅ PASS | PASS: 5 / 5 FAIL: 0 OVERALL: PASS  |
| tb_pccx_npu_top_stage0_host_to_l2 | ✅ PASS | PASS: 1 / 1 FAIL: 0 OVERALL: PASS  |
| tb_preprocess_bf16_fixed_pipeline | ✅ PASS | OVERALL: PASS  |
| tb_preprocess_fmap_merge_gating | ✅ PASS | OVERALL: PASS  |

**총계**: PASS 28 / FAIL 0


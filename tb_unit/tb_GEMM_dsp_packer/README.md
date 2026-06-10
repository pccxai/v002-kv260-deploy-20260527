# tb_GEMM_dsp_packer

**DUT**: `hw/rtl/MAT_CORE/GEMM_dsp_packer.sv` (84 lines, pure combinational)

## 모듈 요약

W4A8 dual-MAC pre-packer. 2개 INT4 weight + 1개 INT8 activation → DSP48E2 A/B port.

```
in_w_upper (4-bit signed) ──┐
                            ├──→ a_packed = (w_upper << 21) + w_lower  (30-bit signed, A-port)
in_w_lower (4-bit signed) ──┘
in_act (8-bit signed) ─────→ b_extended = sign-ext(act)  (18-bit signed, B-port)
```

## 테스트 전략 — Round-trip 검증

DUT만 보면 단순 packing이지만, **실제 사용 흐름 검증**이 더 강함:

```
[w_upper, w_lower] → packer → a_packed
                              × b_extended → P (48-bit) → sign_recovery → [unpack_lower, unpack_upper]
                                                                              ║
                                                          expected (w_lower*act, w_upper*act)
                                                                              ║
                                                                          비교 PASS
```

즉 tb 안에서 DSP48E2 multiply를 emulate (`signed' * signed'`)하고 sign_recovery 로직도 emulate해서 round-trip이 wlower*act + wupper*act와 일치하는지 확인.

## 테스트 케이스

- 12 directed (zero/positive/negative 조합 + extreme min/max)
- Exhaustive sample: INT4 × INT4 × INT8 (every 16th act) ≈ 4096 cases

## 의존성

`GLOBAL_CONST.svh` (DEVICE_DSP_A_WIDTH=30, DEVICE_DSP_B_WIDTH=18, INT4_WIDTH=4).
tb는 localparam override로 self-contained.

## PASS 기준

모든 4096+ vector에서 unpack_lower == w_lower * in_act && unpack_upper == w_upper * in_act.

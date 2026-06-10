# tb_GEMM_sign_recovery

**DUT**: `hw/rtl/MAT_CORE/GEMM_sign_recovery.sv` (73 lines, pure combinational)

## 모듈 요약

DSP48E2의 48-bit P 출력 → 2개 signed accumulator (lower + upper)로 분리.
W4A8 dual-MAC 패킹 (1 DSP = 2 MAC) post-unpacker.

```
in_p_accum [47:0]
  ├─ lower (21-bit signed) = P[20:0]
  └─ upper (21-bit signed) = P[41:21] + (lower_negative ? +1 : 0)
                                          ↑ borrow correction
```

## 테스트 시나리오

| # | 시나리오 | input P (hex) | expected lower | expected upper |
|---|---|---|---|---|
| 1 | 둘 다 0 | 0x00000000_0000_0000 | 0 | 0 |
| 2 | lower=+1, upper=0 | 0x00000000_0000_0001 | +1 | 0 |
| 3 | lower=0, upper=+1 (raw bit) | 0x00000000_0020_0000 | 0 | +1 |
| 4 | lower=-1, upper=+5 (raw +4 in field, borrow→+5) | (upper field = 0x4) | -1 | +5 |
| 5 | lower=max+ (2^20-1), upper=0 | 0x00000000_000F_FFFF | 0x0FFFFF | 0 |
| 6 | lower=min- (-2^20), upper=0 (raw, borrow→+1) | 0x00000000_0010_0000 | 0x100000 (-2^20) | +1 |
| 7 | upper=max+ (2^20-1) | (upper field = 0x0FFFFF) | 0 | +0x0FFFFF |
| 8 | lower=-2, upper=-3 (raw -4 field, borrow→-3) | calculated | -2 | -3 |
| 9 | Random 1000회 | Python에서 생성 | NumPy reference | 비교 |

## Reference 모델 (NumPy)

```python
def sign_recovery(p_accum_48bit):
    """RTL spec exactly."""
    lower_raw = p_accum_48bit & 0x1FFFFF  # bits [20:0]
    upper_raw = (p_accum_48bit >> 21) & 0x1FFFFF  # bits [41:21]
    # to signed 21-bit
    lower = lower_raw - (1 << 21) if (lower_raw >> 20) else lower_raw
    upper = upper_raw - (1 << 21) if (upper_raw >> 20) else upper_raw
    # borrow correction: if lower negative, upper += 1
    if lower < 0:
        upper += 1
        # may wrap if upper was at max
        if upper > (1 << 20) - 1:
            upper -= (1 << 21)
    return lower, upper
```

## Pass/Fail 기준

- 9개 케이스 모두 expected와 일치 → PASS
- 1개라도 mismatch → FAIL + 해당 input 로그

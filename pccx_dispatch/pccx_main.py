"""PCCX v002 NPU dispatch entry — Gemma 3N E4B on KV260 FPGA.

main.py와 분리된 entry point. host ISA (RESET_KV_CACHE/LOAD_WEIGHT/LOAD_PROMPT/
NEXT_TOKEN) 4개 command 만으로 NPU에 모든 forward pass dispatch.

PCCX NPU 가치 prop: per-layer GEMM/GEMV/CVO는 HW 내부 자동, host는 high-level
command만 발행. NumPy/Vulkan/CPU 무관, FPGA 직접 dispatch.

사용:
    sudo env "PYTHONPATH=/home/ubuntu/.local/lib/python3.10/site-packages" \\
        python3 pccx_main.py

전제:
- bitstream pccx_npu_bd loaded (xmutil loadapp 완료)
- /dev/uio4 = pccx-npu (find_fabric_uio 자동 탐지)
- transformers + tokenizers + sentencepiece 설치
- 가중치 manifest는 host-to-L2 DMA (Phase 2 — 현재 manifest_id=0 placeholder)
"""
from __future__ import annotations

import os
import sys
import time

from transformers import AutoTokenizer

from pccx_npu import isa
from pccx_npu.uio import NpuMmio


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.join(BASE_DIR, "local_gemma_3n_int4")

STOP_TOKENS = {1, 106}  # Gemma EOT / end-of-turn (main.py와 동일)
MAX_NEW_TOKENS = 64


def load_tokenizer() -> AutoTokenizer:
    print("[1/4] Loading tokenizer from", MODEL_DIR, "...")
    t = AutoTokenizer.from_pretrained(MODEL_DIR, local_files_only=True, use_fast=False)
    print(f"      ✓ {type(t).__name__} (vocab={t.vocab_size})")
    return t


def open_npu() -> NpuMmio:
    print("[2/4] Opening NPU UIO device ...")
    mmio = NpuMmio()  # auto-finds /dev/uioN with 'fabric' in name
    print(f"      ✓ {mmio.path} (window={mmio.size:#x})")
    return mmio


def submit_and_wait(mmio: NpuMmio, word64: int, label: str, timeout_s: float = 5.0) -> int:
    """Push one ISA word + KICK + poll DONE, return final 64-bit status."""
    t0 = time.perf_counter()
    mmio.submit_program([word64])
    ok = mmio.wait_done(timeout_s=timeout_s)
    dt_ms = (time.perf_counter() - t0) * 1000
    status = mmio.read64(0x000)
    flag = "DONE" if ok else "TIMEOUT"
    print(f"      [{label}] {flag} in {dt_ms:.1f}ms, status=0x{status:016x}")
    if not ok:
        raise TimeoutError(f"{label} did not complete within {timeout_s}s (status=0x{status:016x})")
    if isa.status_error(status):
        raise RuntimeError(f"{label} reported ERROR (status=0x{status:016x})")
    return status


def load_weights_once(mmio: NpuMmio, *, manifest_id: int = 0) -> None:
    print("[3/4] LOAD_WEIGHT (host-to-L2 manifest descriptor) ...")
    submit_and_wait(
        mmio,
        isa.encode_load_weight(manifest_id=manifest_id),
        "LOAD_WEIGHT",
        timeout_s=10.0,
    )


def reset_kv_cache(mmio: NpuMmio, *, session_id: int = 0) -> None:
    submit_and_wait(
        mmio,
        isa.encode_reset_kv_cache(session_id=session_id),
        "RESET_KV_CACHE",
        timeout_s=2.0,
    )


def load_prompt(mmio: NpuMmio, tokens: list[int]) -> None:
    print(f"      LOAD_PROMPT ({len(tokens)} tokens) ...")
    t0 = time.perf_counter()
    for pos, tok in enumerate(tokens):
        submit_and_wait(
            mmio,
            isa.encode_load_prompt(position=pos, token_id=int(tok)),
            f"LOAD_PROMPT[{pos}]",
            timeout_s=2.0,
        )
    dt = time.perf_counter() - t0
    print(f"      ✓ prefill {len(tokens)} tokens in {dt:.2f}s ({len(tokens)/dt:.1f} tok/s)")


def next_token(mmio: NpuMmio, *, request_id: int = 0) -> int | None:
    word = isa.encode_next_token(request_id=request_id)
    mmio.submit_program([word])
    ok = mmio.wait_done(timeout_s=3.0)
    if not ok:
        return None
    status = mmio.read64(0x000)
    if isa.status_error(status):
        raise RuntimeError(f"NEXT_TOKEN ERROR status=0x{status:016x}")
    return isa.status_token(status)  # returns None if TOKEN_VALID bit not set


def chat_loop(tokenizer: AutoTokenizer, mmio: NpuMmio) -> None:
    print("[4/4] Chat mode ready. Type 'exit' to quit.\n")
    while True:
        try:
            user = input("User: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n[exit]")
            return
        if not user or user.lower() in ("exit", "quit"):
            return

        # tokenize
        tokens = tokenizer(user, return_tensors="np")["input_ids"][0].tolist()
        print(f"[CPU] tokenized {len(tokens)} ids: {tokens[:20]}{' ...' if len(tokens) > 20 else ''}")

        # NPU prefill
        reset_kv_cache(mmio)
        load_prompt(mmio, tokens)

        # NPU decode
        print("Model:", end=" ", flush=True)
        generated: list[int] = []
        t0 = time.perf_counter()
        for step in range(MAX_NEW_TOKENS):
            tok = next_token(mmio, request_id=step & 0xFFFF)
            if tok is None:
                print(f"\n[warn] step {step}: TOKEN_VALID not set, stopping")
                break
            if tok in STOP_TOKENS:
                break
            generated.append(tok)
            piece = tokenizer.decode([tok], skip_special_tokens=True)
            print(piece, end="", flush=True)
        dt = time.perf_counter() - t0
        n = len(generated)
        rate = (n / dt) if dt > 0 else 0
        print(f"\n[NPU] {n} tokens in {dt:.2f}s ({rate:.1f} tok/s)\n")


def main() -> int:
    print("=" * 60)
    print("  PCCX v002 NPU Inference — Gemma 3N E4B on KV260 FPGA")
    print("=" * 60)
    tokenizer = load_tokenizer()
    with open_npu() as mmio:
        load_weights_once(mmio)
        chat_loop(tokenizer, mmio)
    print("[done] bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())

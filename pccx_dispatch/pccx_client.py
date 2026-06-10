"""PCCX v002 host client (runs on Master).

Architecture :
- Master(PC): Tokenizer + chat UI (this file)
- KV260 (Device): NPU dispatch + KV cache (pccx_server.py)
- Communication: TCP socket port 9001

Usage:
    python3 pccx_client.py [host_ip]

Default host_ip = 192.168.219.108 (KV260 Ethernet)
"""
from __future__ import annotations

import socket
import struct
import sys
import time

MAGIC = b"PCCX"
HEADER_FMT = "<4sBBH"
HEADER_LEN = struct.calcsize(HEADER_FMT)

CMD_RESET = 0x01
CMD_LOAD_WEIGHTS = 0x02
CMD_LOAD_PROMPT = 0x03
CMD_NEXT_TOKEN = 0x04
CMD_PING = 0x05

STAT_OK = 0x00


class PCCXClient:
    def __init__(self, host: str = "192.168.219.108", port: int = 9001):
        self.host = host
        self.port = port
        self.sock: socket.socket | None = None

    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.connect((self.host, self.port))
        print(f"Connected to {self.host}:{self.port}")

    def close(self) -> None:
        if self.sock is not None:
            self.sock.close()
            self.sock = None

    def _call(self, cmd: int, payload: bytes = b"") -> tuple[int, bytes]:
        if self.sock is None:
            raise RuntimeError("not connected")
        hdr = struct.pack(HEADER_FMT, MAGIC, cmd, 0, len(payload))
        self.sock.sendall(hdr + payload)
        resp_hdr = self.sock.recv(HEADER_LEN, socket.MSG_WAITALL)
        if len(resp_hdr) != HEADER_LEN:
            raise RuntimeError("short response header")
        magic, rcmd, status, plen = struct.unpack(HEADER_FMT, resp_hdr)
        if magic != MAGIC:
            raise RuntimeError(f"bad response magic: {magic!r}")
        resp_payload = b""
        if plen > 0:
            resp_payload = self.sock.recv(plen, socket.MSG_WAITALL)
        return status, resp_payload

    def ping(self) -> bool:
        status, payload = self._call(CMD_PING)
        return status == STAT_OK and payload == b"PONG"

    def reset(self) -> None:
        status, _ = self._call(CMD_RESET)
        if status != STAT_OK:
            raise RuntimeError(f"RESET failed: status=0x{status:02x}")

    def load_weights(self, manifest_id: int) -> None:
        payload = struct.pack("<I", manifest_id)
        status, _ = self._call(CMD_LOAD_WEIGHTS, payload)
        if status != STAT_OK:
            raise RuntimeError(f"LOAD_WEIGHTS failed: status=0x{status:02x}")

    def load_prompt(self, position: int, token_id: int) -> None:
        payload = struct.pack("<II", position, token_id)
        status, _ = self._call(CMD_LOAD_PROMPT, payload)
        if status != STAT_OK:
            raise RuntimeError(f"LOAD_PROMPT failed: status=0x{status:02x}")

    def next_token(self, request_id: int = 0) -> int:
        payload = struct.pack("<I", request_id)
        status, resp = self._call(CMD_NEXT_TOKEN, payload)
        if status != STAT_OK:
            raise RuntimeError(f"NEXT_TOKEN failed: status=0x{status:02x}")
        if len(resp) < 4:
            raise RuntimeError("short token response")
        return struct.unpack("<I", resp[:4])[0]


def load_tokenizer(model_path: str = "/home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/local_gemma_3n_int4"):
    """Load Gemma 3N tokenizer from local files."""
    try:
        from transformers import AutoTokenizer
        return AutoTokenizer.from_pretrained(model_path)
    except Exception as exc:
        print(f"Tokenizer load failed ({exc})")
        sys.exit(1)


def chat_repl(client: PCCXClient, tokenizer) -> None:
    """Simple chat REPL — encode → send → receive → decode."""
    print("=== PCCX Chat (Ctrl-C to exit) ===")
    client.reset()
    client.load_weights(0x000e4b00)
    print(f"  weights loaded (manifest 0x000e4b00)")

    while True:
        try:
            user_in = input("\n> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not user_in:
            continue

        # Encode user prompt
        token_ids = tokenizer.encode(user_in, add_special_tokens=False)
        print(f"  prompt tokens ({len(token_ids)}): {token_ids[:16]}{'…' if len(token_ids) > 16 else ''}")

        # Load prompt token by token (KV cache builds on server)
        t0 = time.monotonic()
        for pos, tok in enumerate(token_ids):
            client.load_prompt(pos, tok)
        prompt_ms = (time.monotonic() - t0) * 1000
        print(f"  prompt loaded in {prompt_ms:.0f}ms")

        # Generate response token by token (single token for v002 first-silicon)
        generated: list[int] = []
        t0 = time.monotonic()
        max_new = 16  # short response for first-silicon
        for i in range(max_new):
            tok = client.next_token(request_id=i)
            if tok in tokenizer.all_special_ids or tok == tokenizer.eos_token_id:
                break
            generated.append(tok)
        gen_ms = (time.monotonic() - t0) * 1000
        if generated:
            text = tokenizer.decode(generated, skip_special_tokens=True)
            print(f"  reply ({len(generated)} tok in {gen_ms:.0f}ms): {text}")
        else:
            print(f"  no tokens generated ({gen_ms:.0f}ms)")


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "192.168.219.108"
    client = PCCXClient(host=host)
    print(f"Connecting to {host}:9001 …")
    try:
        client.connect()
    except Exception as exc:
        print(f"Connection failed: {exc}")
        return 1

    if not client.ping():
        print("PING failed")
        return 2
    print("PING OK")

    print("Loading tokenizer …")
    tokenizer = load_tokenizer()
    print(f"  Tokenizer: {type(tokenizer).__name__}, vocab={tokenizer.vocab_size}")

    chat_repl(client, tokenizer)
    client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

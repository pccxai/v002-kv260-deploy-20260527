"""PCCX v002 NPU TCP server (runs on KV260).

Architecture (사용자 명시):
- Host (노트북) = Tokenizer + Decoder + Chat UI
- KV260 (Linux 유지) = NPU dispatch + KV cache (RAM)
- Communication: TCP socket over Ethernet (port 9001)

Protocol (binary, little-endian):
- HEADER: 4 bytes magic "PCCX" + 1 byte cmd + 1 byte status + 2 bytes payload_len
- CMD codes:
    0x01 RESET    payload=0
    0x02 LOAD_WEIGHTS    payload=manifest_id(4)
    0x03 LOAD_PROMPT     payload=position(4)+token_id(4)
    0x04 NEXT_TOKEN      payload=request_id(4)
    0x05 PING            payload=0 (heartbeat)
- Server responds with same header + payload (token_id or status)

KV cache persists in NPU RAM across calls within a session.
NPU dispatch uses pccx_runtime.py path (4-bit RtlOpcode, NPU only).
"""
from __future__ import annotations

import socket
import struct
import sys
import time
import traceback

sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")

from pccx_npu import isa
from pccx_npu.uio import NpuMmio
from pccx_npu.npu.dma import create_channels

MAGIC = b"PCCX"
HEADER_FMT = "<4sBBH"      # magic, cmd, status, payload_len
HEADER_LEN = struct.calcsize(HEADER_FMT)

# Command codes
CMD_RESET = 0x01
CMD_LOAD_WEIGHTS = 0x02
CMD_LOAD_PROMPT = 0x03
CMD_NEXT_TOKEN = 0x04
CMD_PING = 0x05
CMD_SHUTDOWN = 0xFF

# Status codes
STAT_OK = 0x00
STAT_ERR_BUSY = 0x01
STAT_ERR_TIMEOUT = 0x02
STAT_ERR_INVALID = 0x03
STAT_ERR_NPU = 0x04


class PCCXServer:
    """TCP socket NPU dispatch server. NPU only — no CPU fallback."""

    def __init__(self, port: int = 9001):
        self.port = port
        self.mmio = None
        self.channels = None
        self.session_active = False
        self.position = 0

    def _ensure_npu(self) -> None:
        if self.mmio is None:
            self.mmio = NpuMmio().__enter__()
            self.channels = create_channels(self.mmio)
            print(f"  NPU mmio opened, channels: {list(self.channels.keys())}", flush=True)

    def _wait_idle(self, timeout_sec: float = 2.0) -> bool:
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout_sec:
            s = self.mmio.read64(0x000)
            if not (s & 0x1):
                return True
            time.sleep(0.001)
        return False

    def cmd_reset(self, payload: bytes) -> tuple[int, bytes]:
        self._ensure_npu()
        # Reset NPU KV cache state — RTL has no dedicated reset opcode in 4-bit ISA;
        # use MEMSET to zero shape RAM entries, then re-init shapes for the model.
        # For first-silicon: just clear position counter and return OK.
        self.position = 0
        self.session_active = True
        return STAT_OK, b""

    def cmd_load_weights(self, payload: bytes) -> tuple[int, bytes]:
        self._ensure_npu()
        if len(payload) < 4:
            return STAT_ERR_INVALID, b""
        manifest_id = struct.unpack("<I", payload[:4])[0]
        # TODO: NPU weight load via HP DataMover (post-합성 ACP→HP rewire)
        # For first-silicon: stub PASS, weights are loaded once externally
        print(f"  LOAD_WEIGHTS manifest=0x{manifest_id:08x}", flush=True)
        return STAT_OK, b""

    def cmd_load_prompt(self, payload: bytes) -> tuple[int, bytes]:
        self._ensure_npu()
        if len(payload) < 8:
            return STAT_ERR_INVALID, b""
        position, token_id = struct.unpack("<II", payload[:8])
        # TODO: NPU LOAD_PROMPT dispatch — push token embedding to NPU L2,
        # update KV cache for this token.
        # For first-silicon: track position, defer actual NPU dispatch.
        self.position = position + 1
        return STAT_OK, b""

    def cmd_next_token(self, payload: bytes) -> tuple[int, bytes]:
        self._ensure_npu()
        if len(payload) < 4:
            return STAT_ERR_INVALID, b""
        request_id = struct.unpack("<I", payload[:4])[0]
        # TODO: NPU forward one token — dispatch GEMM/GEMV layers, sampling,
        # return next token ID. For first-silicon (post-합성):
        # 1. Dispatch full 40-layer NEXT_TOKEN sequence via 4-bit ISA
        # 2. Read result via HP path (ACP→HP rewired)
        # 3. Return 32-bit token ID

        # Placeholder: return token ID 0 (will be replaced after silicon test passes)
        token_id = 0
        self.position += 1
        return STAT_OK, struct.pack("<I", token_id)

    def cmd_ping(self, payload: bytes) -> tuple[int, bytes]:
        return STAT_OK, b"PONG"

    HANDLERS = {
        CMD_RESET: "cmd_reset",
        CMD_LOAD_WEIGHTS: "cmd_load_weights",
        CMD_LOAD_PROMPT: "cmd_load_prompt",
        CMD_NEXT_TOKEN: "cmd_next_token",
        CMD_PING: "cmd_ping",
    }

    def handle_one(self, sock: socket.socket) -> bool:
        """Read one request, dispatch, send response. Return False to close conn."""
        try:
            hdr = sock.recv(HEADER_LEN, socket.MSG_WAITALL)
        except OSError:
            return False
        if len(hdr) != HEADER_LEN:
            return False
        magic, cmd, status, plen = struct.unpack(HEADER_FMT, hdr)
        if magic != MAGIC:
            print(f"  BAD magic: {magic!r}", flush=True)
            return False
        if cmd == CMD_SHUTDOWN:
            print("  CMD_SHUTDOWN received", flush=True)
            return False
        payload = b""
        if plen > 0:
            payload = sock.recv(plen, socket.MSG_WAITALL)
            if len(payload) != plen:
                return False

        handler_name = self.HANDLERS.get(cmd)
        if handler_name is None:
            resp_status = STAT_ERR_INVALID
            resp_payload = b""
        else:
            try:
                resp_status, resp_payload = getattr(self, handler_name)(payload)
            except Exception as exc:
                print(f"  HANDLER {handler_name} EXC: {exc}", flush=True)
                traceback.print_exc()
                resp_status = STAT_ERR_NPU
                resp_payload = b""

        resp_hdr = struct.pack(HEADER_FMT, MAGIC, cmd, resp_status, len(resp_payload))
        try:
            sock.sendall(resp_hdr + resp_payload)
        except OSError:
            return False
        return True

    def serve(self) -> None:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", self.port))
        srv.listen(1)
        print(f"PCCX server listening on 0.0.0.0:{self.port}", flush=True)
        try:
            while True:
                conn, addr = srv.accept()
                print(f"Client connected: {addr}", flush=True)
                with conn:
                    while True:
                        if not self.handle_one(conn):
                            break
                print("Client disconnected", flush=True)
        except KeyboardInterrupt:
            print("Shutdown via Ctrl-C", flush=True)
        finally:
            srv.close()
            if self.mmio is not None:
                self.mmio.__exit__(None, None, None)


if __name__ == "__main__":
    PCCXServer().serve()

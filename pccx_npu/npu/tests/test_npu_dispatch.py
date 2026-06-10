from __future__ import annotations

import importlib.util
from pathlib import Path
import struct
import sys

import numpy as np
import pytest

from pccx_npu import isa
from pccx_npu.npu import address_map
from pccx_npu.npu import npu_core
from pccx_npu.npu.cpu_fallback import cpu_gemm
from pccx_npu.npu.dma import (
    CMD_EXT,
    CMD_HI,
    CMD_LO,
    CMD_PUSH,
    FLAGS,
    PSDataMoverChannel,
    STS_POP,
    datamover_status_is_okay,
    decode_datamover_status,
    format_datamover_status,
    pack_datamover_command,
)


def load_dbg_common():
    root = Path(__file__).resolve().parents[3]
    path = root / "debug" / "_lib" / "dbg_common.py"
    spec = importlib.util.spec_from_file_location("dbg_common_for_test", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_npu_gemm_matches_cpu_fallback(monkeypatch):
    monkeypatch.setattr(npu_core, "NPU_AVAILABLE", False)
    W = np.array(
        [
            [1.0, 2.0, 3.0],
            [4.0, 5.0, 6.0],
        ],
        dtype=np.float32,
    )
    X = np.array(
        [
            [7.0, 8.0],
            [9.0, 10.0],
        ],
        dtype=np.float32,
    )

    np.testing.assert_array_equal(npu_core.npu_gemm(W, X), cpu_gemm(W, X))


def test_discover_address_map_uses_mocked_uio_sysfs(tmp_path):
    sysfs_root = tmp_path / "sys" / "class" / "uio"
    map0 = sysfs_root / "uio4" / "maps" / "map0"
    map0.mkdir(parents=True)
    (map0 / "addr").write_text("0xA1000000\n", encoding="ascii")
    (map0 / "size").write_text("0x00010000\n", encoding="ascii")

    amap = address_map.discover_address_map(
        sysfs_uio_root=sysfs_root,
        proc_device_tree_root=tmp_path / "missing-device-tree",
    )

    assert amap.npu_base == 0xA1000000
    assert amap.uio_map_base == 0xA1000000
    assert amap.cmdsts_bases["hp0"] == 0xA1001000
    assert amap.cmdsts_bases["acp_result"] == 0xA1006000


def test_discover_address_map_scans_mocked_device_tree_ranges(tmp_path):
    dt_root = tmp_path / "proc" / "device-tree" / "fabric"
    dt_root.mkdir(parents=True)
    (dt_root / "ranges").write_bytes(
        struct.pack(">IIII", 0x00000000, 0xA0200000, 0x00000000, 0x00010000)
    )

    amap = address_map.discover_address_map(
        sysfs_uio_root=tmp_path / "missing-sysfs",
        proc_device_tree_root=tmp_path / "proc" / "device-tree",
    )

    assert amap.npu_base == 0xA0200000
    assert amap.cmdsts_bases["hp3"] == 0xA0204000


def test_datamover_command_word_packing():
    word = pack_datamover_command(
        addr=0x12345678,
        tag=0xA,
        length_bytes=0x40,
        eof=True,
    )

    expected = (
        (0xF << 76)
        | (0xF << 72)
        | (0xA << 64)
        | (0x12345678 << 32)
        | (1 << 30)
        | (1 << 23)
        | 0x40
    )
    assert word == expected


def test_datamover_command_custom_cache_user_fields():
    word = pack_datamover_command(
        addr=0x87654321,
        tag=0x5,
        length_bytes=0x123,
        eof=False,
        xuser=0x2,
        xcache=0xB,
    )

    expected = (
        (0x2 << 76)
        | (0xB << 72)
        | (0x5 << 64)
        | (0x87654321 << 32)
        | (1 << 23)
        | 0x123
    )
    assert word == expected


def test_debug_and_runtime_datamover_packers_match():
    dbg_common = load_dbg_common()
    kwargs = {
        "addr": 0x12345678,
        "tag": 0xA,
        "xuser": 0xF,
        "xcache": 0xF,
    }

    word = pack_datamover_command(length_bytes=0x40, eof=True, **kwargs)
    lo, hi, ext = dbg_common.pack_dm_cmd(btt=0x40, eof=1, drr=0, **kwargs)

    assert lo == (word & 0xFFFF_FFFF)
    assert hi == ((word >> 32) & 0xFFFF_FFFF)
    assert ext == ((word >> 64) & 0xFFFF)


def test_datamover_status_decode_contract():
    dbg_common = load_dbg_common()

    okay = dbg_common.decode_dm_status(0x0000018A)
    assert okay["tag"] == 0xA
    assert okay["okay"] is True
    assert okay["bytes"] == 1
    assert okay["decerr"] is False
    assert okay["interr"] is False

    decerr = dbg_common.decode_dm_status(0x00000020)
    assert decerr["okay"] is False
    assert decerr["decerr"] is True
    assert decerr["bytes"] == 0

    interr = dbg_common.decode_dm_status(0x00000010)
    assert interr["okay"] is False
    assert interr["interr"] is True
    assert interr["bytes"] == 0


def test_datamover_status_decode_8bit_observable_contract():
    dbg_common = load_dbg_common()

    cases = {
        0x80 | 0x5: ("okay", 0x5),
        0x40 | 0x6: ("slverr", 0x6),
        0x20 | 0x7: ("decerr", 0x7),
        0x10 | 0x8: ("interr", 0x8),
    }
    for raw, (flag, tag) in cases.items():
        decoded = dbg_common.decode_dm_status(raw)
        assert decoded["tag"] == tag
        assert decoded[flag] is True
        assert decoded["bytes"] == 0
        assert decoded["eof"] is False


def test_runtime_datamover_status_decode_matches_debug_contract():
    decoded = decode_datamover_status(0x0000018A)
    assert decoded["tag"] == 0xA
    assert decoded["okay"] is True
    assert decoded["bytes"] == 1
    assert datamover_status_is_okay(0x80 | 0xA, expected_tag=0xA) is True
    assert datamover_status_is_okay(0x40 | 0xA, expected_tag=0xA) is False
    assert "SLVERR" in format_datamover_status(0x40 | 0xA)


def test_datamover_payload_success_gate_rejects_empty_errors_and_tag_mismatch():
    dbg_common = load_dbg_common()

    assert dbg_common.dm_payloads_all_okay([0x80 | 0xA], expected_tag=0xA) is True
    assert dbg_common.dm_payloads_all_okay([], expected_tag=0xA) is False
    assert dbg_common.dm_payloads_all_okay([0x80 | 0xA], expected_tag=0xB) is False
    assert dbg_common.dm_payloads_all_okay([0x10 | 0xA], expected_tag=0xA) is False
    assert dbg_common.dm_payloads_all_okay([0x20 | 0xA], expected_tag=0xA) is False
    assert dbg_common.dm_payloads_all_okay([0x40 | 0xA], expected_tag=0xA) is False


def test_debug_datamover_packer_rejects_invalid_descriptors():
    dbg_common = load_dbg_common()

    invalid_kwargs = [
        {"addr": -1, "btt": 16},
        {"addr": 0x1_0000_0000, "btt": 16},
        {"addr": 0, "btt": 0},
        {"addr": 0, "btt": 1 << 23},
        {"addr": 0, "btt": 16, "tag": 0x10},
        {"addr": 0, "btt": 16, "xuser": 0x10},
        {"addr": 0, "btt": 16, "xcache": 0x10},
        {"addr": 0, "btt": 16, "drr": 2},
        {"addr": 0, "btt": 16, "eof": 2},
    ]
    for kwargs in invalid_kwargs:
        with pytest.raises(ValueError):
            dbg_common.pack_dm_cmd(**kwargs)


def test_datamover_issue_command_writes_three_words_then_push():
    class FakeMmio:
        def __init__(self) -> None:
            self.writes: list[tuple[int, int]] = []

        def write32(self, offset: int, value: int) -> None:
            self.writes.append((offset, value))

        def read32(self, offset: int) -> int:
            assert offset == 0x1000 + FLAGS
            return 0

    fake = FakeMmio()
    chan = PSDataMoverChannel("hp0", fake, base_addr=0x1000, uio_map_base=0)
    token = chan.issue_command(0x12345678, 0xA, 0x40)
    word = pack_datamover_command(
        addr=0x12345678,
        tag=0xA,
        length_bytes=0x40,
    )

    assert token == 0xA
    assert fake.writes == [
        (0x1000 + CMD_LO, word & 0xFFFF_FFFF),
        (0x1000 + CMD_HI, (word >> 32) & 0xFFFF_FFFF),
        (0x1000 + CMD_EXT, (word >> 64) & 0xFFFF_FFFF),
        (0x1000 + CMD_PUSH, 0x1),
    ]


def test_datamover_poll_status_decodes_low_nibble_tag():
    class FakeMmio:
        def __init__(self) -> None:
            self.pop_count = 0

        def write32(self, offset: int, value: int) -> None:
            raise AssertionError("poll_status should not write")

        def read32(self, offset: int) -> int:
            if offset == 0x1000 + FLAGS:
                return 0
            if offset == 0x1000 + 0x010:
                self.pop_count += 1
                return 0x80 | 0xA
            raise AssertionError(f"unexpected read offset 0x{offset:x}")

    fake = FakeMmio()
    chan = PSDataMoverChannel("hp0", fake, base_addr=0x1000, uio_map_base=0)

    assert chan.poll_status(0xA, timeout_sec=0.01) == 0x8A
    assert fake.pop_count == 1


def test_datamover_poll_status_rejects_mismatched_tag():
    class FakeMmio:
        def write32(self, offset: int, value: int) -> None:
            raise AssertionError("poll_status should not write")

        def read32(self, offset: int) -> int:
            if offset == 0x1000 + FLAGS:
                return 0
            if offset == 0x1000 + STS_POP:
                return 0x80 | 0xB
            raise AssertionError(f"unexpected read offset 0x{offset:x}")

    fake = FakeMmio()
    chan = PSDataMoverChannel("hp0", fake, base_addr=0x1000, uio_map_base=0)

    with pytest.raises(RuntimeError, match="did not match command token"):
        chan.poll_status(0xA, timeout_sec=0.01)


def test_datamover_poll_status_rejects_non_okay_status():
    class FakeMmio:
        def write32(self, offset: int, value: int) -> None:
            raise AssertionError("poll_status should not write")

        def read32(self, offset: int) -> int:
            if offset == 0x1000 + FLAGS:
                return 0
            if offset == 0x1000 + STS_POP:
                return 0x40 | 0xA
            raise AssertionError(f"unexpected read offset 0x{offset:x}")

    fake = FakeMmio()
    chan = PSDataMoverChannel("hp0", fake, base_addr=0x1000, uio_map_base=0)

    with pytest.raises(RuntimeError, match="not OKAY"):
        chan.poll_status(0xA, timeout_sec=0.01)


def test_stage1_gemm_silicon_route_contract_blocks_acp_weight_preload():
    root = Path(__file__).resolve().parents[3]
    path = root / "debug" / "stage1_gemm_silicon.py"
    spec = importlib.util.spec_from_file_location("stage1_gemm_silicon_for_test", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    assert module.GEMM_WEIGHT_CHANNELS == ("hp0", "hp1")
    assert module.GEMM_FMAP_CHANNEL == "acp_fmap"
    assert module.GEMM_FMAP_CHANNEL not in module.GEMM_WEIGHT_CHANNELS
    assert module.WEIGHT_PACKING_IMPLEMENTED is False
    module.validate_gemm_route_contract()


def test_memcpy_route_bits_match_rtl_direction_enums():
    host_to_l2 = isa.encode_memcpy(from_device=1, to_device=0)
    l2_to_host = isa.encode_memcpy(from_device=0, to_device=1)

    assert ((host_to_l2 >> 59) & 0x1) == 1
    assert ((host_to_l2 >> 58) & 0x1) == 0
    assert ((l2_to_host >> 59) & 0x1) == 0
    assert ((l2_to_host >> 58) & 0x1) == 1
    assert isa.MemcpyRoute.FROM_HOST_TO_L2 == 0x01
    assert isa.MemcpyRoute.FROM_L2_TO_HOST == 0x10


def test_token_runtime_emits_self_contained_commands_only():
    class FakeMmio:
        def __init__(self) -> None:
            self.commands: list[int] = []
            self.reads = 0

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb) -> None:
            return None

        def write64(self, offset: int, value: int) -> None:
            if offset == address_map.AXIL_CMD_IN:
                self.commands.append(value)

        def read64(self, offset: int) -> int:
            assert offset == address_map.AXIL_STAT_OUT
            self.reads += 1
            last_opcode, _ = isa.decode_command(self.commands[-1])
            if last_opcode == isa.Opcode.NEXT_TOKEN:
                return isa.encode_status(done=True, token=0x1234)
            return isa.encode_status(done=True)

    fake = FakeMmio()
    runtime = npu_core.NpuTokenRuntime(mmio_factory=lambda: fake)

    runtime.load_weights_to_l2({"descriptors": [{"slot": 0}]})
    runtime.init_activation([11, 22])
    token = runtime.run_one_token_step()

    assert token == 0x1234
    opcodes = [isa.decode_command(word)[0] for word in fake.commands]
    assert opcodes == [
        isa.Opcode.LOAD_WEIGHT,
        isa.Opcode.RESET_KV_CACHE,
        isa.Opcode.LOAD_PROMPT,
        isa.Opcode.LOAD_PROMPT,
        isa.Opcode.NEXT_TOKEN,
    ]
    assert len(fake.commands) == 5
    assert fake.reads == 5


def test_sim_backend_returns_configured_tokens(monkeypatch):
    monkeypatch.setenv("PCCX_NPU_SIM_BACKEND", "1")
    monkeypatch.setenv("PCCX_NPU_SIM_TOKENS", "77,88")
    monkeypatch.setenv("PCCX_NPU_TOKEN_BACKEND", "1")
    npu_core._reset_token_runtime_for_tests()

    runtime = npu_core.token_runtime()
    runtime.init_activation([101, 102])

    assert runtime.run_one_token_step() == 77
    assert runtime.run_one_token_step() == 88
    assert npu_core.npu_backend_readiness()["hardware_results"] is True

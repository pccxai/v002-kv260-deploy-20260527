# v9 ILA — DataMover stall 신호 silicon 확정 가이드

> Current note, 2026-05-31: this is now a historical ILA plan. The protected
> capture path and probe mapping remain useful, but current board state and next
> analysis live in `docs/HANDOFF-v13-cdc-fix-debug-mmio-2026-05-31.md` and
> `docs/TIMING-CLOSURE-PREP-2026-05-31.md`.

**목표**: v2~v8 합성 8회로도 못 잡은 "DataMover single transfer가 silicon에서 **정확히 어느 신호**에서 멈추나"를 Vivado ILA waveform으로 처음으로 눈으로 확정한다. 이게 forward one token으로 가는 가장 빠른 길.

**배경**: KV260 silicon에서 NPU AXIL frontend·MEMSET·GEMM compute는 동작하지만, fmap/result DataMover의 single transfer가 hang → weight/fmap을 NPU L2로 못 올림. HP/ACP 둘 다 single transfer stuck. (상세: `AUTONOMOUS-NIGHT-2026-05-28.md`, `V002_DEBUG_REPORT.md`)

---

## ⚠ 진행 순서 (반드시 이 순서)

```
Part 0 (사용자, 지금 5분, 현재 bitstream)  →  나에게 결과 보고
        ↓ (JTAG 보임? → transport 결정)
Part A (Claude, GCP 합성 ~2h)  →  ILA 들어간 .bit.bin + .ltx
        ↓
Part B (deploy)  →  Part C (사용자, HW Manager capture)  →  Part D (해석)
```

> **★ Part 0 결과를 보고하기 전엔 합성(Part A)을 시작하지 않는다.** Part 0이 5분 만에 transport(JTAG-direct vs XVC)를 결정하고, 그게 합성할 BD를 바꾸기 때문. 잘못된 transport로 합성하면 2시간 + deploy가 또 날아간다.

---

## Part 0 — KV260이 Vivado에 JTAG로 보이는가? (사용자, ~5분)

현재 bitstream 그대로, **로컬 PC**에서 (FT4232H가 로컬 USB에 꽂혀 있음 — `lsusb`에 `0403:6011`).

### 0-1. 먼저 그냥 시도 (드라이버가 알아서 잡을 수도)
1. Vivado Lab 실행 → **Open Hardware Manager** → **Open Target** → **Auto Connect**
2. 장치가 뜨면 (보통 `arm_dap` + `xcu5ev` 같은 PL TAP 2개) → **JTAG-direct 가능. 0-3으로.**

### 0-2. 안 보이면 — JTAG 채널을 `ftdi_sio`에서 분리
현재 FT4232H 4채널이 전부 `/dev/ttyUSB0~3`로 잡혀 있어서 (`ftdi_sio`가 점유), Vivado가 JTAG 채널(채널 A = interface 0)을 libusb로 못 잡을 수 있다. 그 채널만 분리:
```bash
# 로컬 PC에서. interface :1.0 = 채널 A = JTAG (UART/콘솔은 보통 :1.1)
ls /sys/bus/usb/drivers/ftdi_sio/        # 3-x:1.0  3-x:1.1  3-x:1.2  3-x:1.3 형태
echo -n '3-x:1.0' | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind   # 3-x는 위 출력값으로
```
그 후 0-1 Auto Connect 재시도. (Vivado Lab 설치 시 cable driver를 깔았으면 0-2 없이 0-1에서 바로 될 수도 있음)

### 0-3. 결과 보고 (둘 중 하나)
- ✅ **장치 enumerate 됨** → 나한테 "JTAG 보인다" 보고 → 나는 **JTAG-direct용 BD**로 합성 (Debug Bridge 불필요, 가장 단순)
- ❌ **끝내 안 보임 / unbind도 실패** → "JTAG 안 보인다" 보고 → 나는 **XVC-over-Ethernet용 BD**로 합성 (Debug Bridge IP + KV260 XVC daemon, 이미 깔린 :9001 Ethernet 재사용, ftdi와 안 싸움)

> 둘 다 동작하는 길이야. Part 0은 "어느 쪽이 네 환경에서 마찰이 적은가"만 가른다.

---

## Part A — ILA 들어간 bitstream 합성 (Claude, GCP — Part 0 보고 후)

내가 GCP에서 한다. 기록용 요약:
1. GCP VM start → `system_ila` IP를 BD에 삽입 (XVC 경로면 `Debug Bridge` IP도 AXI-to-BSCAN 모드로 추가).
2. **probe 신호** (BD inspect로 net 이름·clock·width 확정 완료 — 2026-05-29):

   | ILA | 대상 net | 신호 |
   |---|---|---|
   | system_ila_0 ★ | `fmap_dm_acp/M_AXI_MM2S` (read, ACP) | AR(arvalid/arready/araddr/**arcache**) + R(rvalid/rready/rlast) |
   | system_ila_1 ★ | `weight_dm_hp0/M_AXI_MM2S` (read, HP 대조군) | 동일 |

   - clock = `zynq_ps/pl_clk0` 단일(100MHz), depth **1024**.
   - **BRAM 제약으로 2 ILA·M_AXI-only로 축소** (실측): 5 ILA@2048은 RAMB36 147>144 초과 → impl FAIL.
     2 ILA@1024 ≈ 128 RAMB36로 안전.
   - **cmd/sts AXIS probe 제외**: BRAM 절약 + "cmd는 받고 status는 안 옴"은 SW(`dma.py` FLAGS)로 이미 확인된 사실이라 ILA 가치 낮음.
   - **ARUSER 제외**: `c_enable_cache_user=false`라 DataMover가 AxUSER를 노출/구동 안 함 — **이것 자체가 finding**. **ARCACHE는 포함**(AXI4 필수, non-coherent 고정값이 ACP에 도달함을 silicon에서 확인).
   - **`result_dm_acp`(write) 제외**: `dbg_step_03` stimulus가 read(MM2S)라서.
   - ★ 핵심: read 채널(AR+R)만으로 "주소 거부(`arready=0`)" vs "데이터 안 옴(`rvalid` 안 옴)"이 갈린다.

3. synth + impl + `write_bitstream` + **`write_debug_probes` (.ltx)** → `.bit.bin` + `.ltx`.
4. 산출물 GCP→로컬 transfer. (`.ltx`가 없으면 HW Manager가 probe 이름을 모름 — 반드시 쌍으로)

---

## Part B — KV260 deploy

```bash
# 로컬 new-bits/ 에 받은 후
scp new-bits/pccx_npu_bd_v9_ila.bit.bin ubuntu@192.168.219.108:/tmp/
ssh ubuntu@192.168.219.108 'sudo xmutil unloadapp && \
  sudo cp /tmp/pccx_npu_bd_v9_ila.bit.bin /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin && \
  sudo xmutil loadapp pccx_npu_bd && ls -l /dev/uio4'
```
`.ltx`는 KV260에 올릴 필요 없음 — **로컬 HW Manager에서만** 로드한다.

---

## Part C — HW Manager로 ILA capture (사용자)

### JTAG-direct 경로
1. (Part 0-2 했으면) JTAG 채널 unbind 상태 유지.
2. Vivado Lab → Open HW Manager → Auto Connect → KV260 target.

### XVC-over-Ethernet 경로
1. KV260에서 XVC daemon 실행 (내가 Part A에서 daemon + 실행법 같이 줌).
2. HW Manager → `Open Target` → `Open New Target` → **Add Xilinx Virtual Cable (XVC)** → `192.168.219.108:<port>`.

### 공통 — capture
3. probe 파일 로드: ILA 코어에 **`.ltx`** 지정 (Refresh Device 후 Trigger Setup 자동 채워짐).
4. **★ trigger를 먼저 arm, stimulus는 그 다음** (stall은 1회성 rare event — free-run하면 idle만 보고 끝남):
   - Trigger 조건: `fmap_dm_acp` 의 `cmd_tvalid` **또는** `arvalid` **rising edge**.
   - Trigger position: 윈도우 **초반**(예: 1/8), depth: **최대**.
   - **Run Trigger** (arm — 노란 "waiting for trigger" 상태 확인).
5. arm 된 상태에서 **KV260에서 single transfer 발생**:
   ```bash
   ssh ubuntu@192.168.219.108 'cd /home/ubuntu/pccx-gemma-deploy && \
     sudo python3 debug/dbg_step_03_cmdsts_single_acp.py'
   ```
6. ILA가 trigger → waveform 캡쳐됨. **저장**: 파형 screenshot + `File > Export ILA Data`(.csv/.ila).
7. (대조) HP0도 보려면 trigger를 `weight_dm_hp0`로 바꿔 arm → `dbg_step_05_hp_vs_acp_diff.py` 실행.

---

## Part D — 해석 매트릭스 (capture 후 이 표로 분기)

> probe = fmap_acp vs hp0의 `M_AXI_MM2S` **AR+R** (system_ila 2개, depth 512). cmd push 여부는
> SW(`pccx_npu/npu/dma.py` CMD_LVL/FLAGS)로 이미 확인됨("cmd 받음, status 안 옴")이라 ILA에서 뺌.

| `M_AXI_MM2S` waveform | 의미 | 다음 fix |
|---|---|---|
| `arvalid` 자체가 안 뜸 | mover가 read 시작 못 함 (내부 stall) | mover config/reset (BD) |
| `arvalid=1` & `arready=0` 영구 | PS/SmartConnect가 **주소를 거부** | addressing / SmartConnect 라우팅 / PS 포트 활성 |
| AR handshake OK, **`rvalid` 영영 안 옴** | 주소 받았는데 데이터 복귀 X = read 처리 stall | ↓ both 여부로 분기 |
| ★ **fmap_acp + hp0 둘 다 동일하게 stall** (가장 유력) | ACP-specific 아님 = **generic PS/interconnect/clock 원인** (v8에서 HP1도 stuck) | PS 포트 활성·clock·SmartConnect 점검 — **ACP coherency 가설 배제** |
| hp0 정상 + fmap_acp만 stall | ACP-specific stall | `cache_user=false`라 아래 행도 함께 봄 |
| `arcache` non-coherent 고정값 (HP=ACP 동일) | DataMover가 coherent transaction 미요청 (`c_enable_cache_user=false` silicon 확인) | **PS snoop enable(/dev/mem CCI)만으론 ACP 해결 불가** → coherent master / interconnect coherency injection |

→ 어떤 행이 나오든 **그 다음 합성이 처음으로 "근거 기반"**이 된다 (이전 8회는 추측 기반).

> **"both-stuck"은 실패가 아니라 답이다.** v8에서 HP1 single transfer도 stuck이었으므로 둘 다 동일하게
> 멈추는 게 유력하고, 이건 *더 진단적* — ACP-specific을 배제하고 generic PS/interconnect 원인을 가리킨다.
>
> **`c_enable_cache_user=false` 선제 가지치기**: DataMover가 AxCACHE/AxUSER coherency sideband를
> 구동하지 않으므로 `debug/dbg_step_06`의 `/dev/mem` CCI snoop enable path는 ACP에 효과 없을 가능성이
> 높다 (snoop을 켜도 DataMover가 coherence를 *요청*하지 않으니 snoop할 대상이 없음).

> **⚠ 알려진 2차 이슈 (이번 capture와 무관 — 기록만)**: v9 bitstream WNS = **−1.168ns** (TNS −14.7),
> failing path 8개 **전부 NPU `u_fmap_pre`** (fmap FIFO BRAM read → `u_fmap_shifter/global_emax_reg`).
> ILA·DataMover와 무관 (probe net은 positive slack, fmap_pre는 transfer **downstream**) → 이번 stall
> capture엔 영향 없음. 단 **DataMover stall을 고쳐 데이터가 실제로 흐르면** 이 setup violation이 fmap
> compute를 망칠 수 있음 → transfer 동작 확인 후 별도 timing fix 필요. v8 baseline에도 있던 violation으로 추정.

---

## 산출물 공유
capture한 waveform screenshot / `.csv`를 나한테 주면, Part D 매트릭스로 root cause 확정하고 그에 맞는 다음 합성(또는 PS init fix)을 바로 만든다.

**전제**: 전부 KV260 **Linux 부팅 유지** (베어메탈 아님). ILA는 PL fabric 안에 있어서 누가 bitstream을 올렸든(`xmutil`) JTAG로 독립 접근된다.

---

## 진행 상태 (2026-05-30 00:15) — capture 직전, OS blocker로 중단

### ✅ 완료 (durable — SD/로컬에 보존, 다음 세션 재사용)
- v9 ILA bitstream 합성: synth/impl PASS. WNS −1.168ns = NPU `u_fmap_pre` 기존 violation (ILA·DataMover 무관, capture에 영향 X — advisor 확인).
- KV260 deploy: SD firmware = v9 (`/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin` md5 `03fd14fb`). v8 백업 `…bit.bin.bak-v8-20260529-225621`.
- HW Manager JTAG로 **ILA 2개 enumerate + armed 확인**: `hw_ila_1`=`fmap_dm_acp`(ACP), `hw_ila_2`=`weight_dm_hp0`(HP).
- `.ltx`: `/home/hwkim/v9.ltx` (+ `new-bits/pccx_v9_ila.ltx`). JSON, probe 이름 확인됨.
- trigger recipe: 위 Part C (arvalid rising, position 64, depth 1024) — Tcl 명령 검증 완료(armed 성공).

### ❌ BLOCKER = KV260 물리 boot media/전원 불안정 (degrading) — PCCX 설계와 무관
밤새 **3개 distinct signature, uptime이 점점 짧아짐** (= 점진 악화):
- ~7.3h uptime: BPF SMP lockup (`kick_all_cpus_sync → bpf_int_jit_compile`)
- ~50m uptime: multi-CPU soft-lockup (systemd:1 / sshd) — `debug/results/uart_lockup_*.txt`
- ~8m uptime: **`mmc1` SDHCI timeout** (SD I/O 실패) — `debug/results/uart_mmc1_sdhci_timeout_2026-05-30.txt`
→ 이후 콘솔 `^@`(hang) + SSH `No route` = rootfs(SD) 접근 불가로 freeze.
통합: SD/boot media 또는 **12V 전원 marginal**(undervoltage도 SD timeout+CPU stall로 나타남). 물리 문제.
**hard power-cycle 4+회(unclean)가 rootfs/SD를 악화**시켰을 가능성 — ★ 재부팅으로 안 고쳐짐, power-cycle 중단.
- **소프트 재부팅/종료 불가 확인**: hang이 깊어 SSH=No route, UART `reboot`·SysRq(S-U-B/h, 종료용 S-U-O까지) 전부 무응답 — `kick_all_cpus_sync` hang이 SysRq IRQ도 막음 → graceful 종료 불가, **hard power-off만 가능**. (단 부팅 중 idle freeze라 fs 쓰기 적음 → 손상 위험 낮음, 필요시 다음 부팅 전 또 fsck)
- ~~`bpf_jit_enable=0`~~ = superseded (SD/물리 레벨은 못 고침. 이전 가설).
- **ACP 무죄** 유지: ACP는 이전 8세션 crash 없이 동작, v9는 ACP config 안 바꿈 → 보드 안정화 후 ACP가 진짜 target. ACP-crash 가설 문서화 금지.

### ▶ NEXT (다음 세션 — SD 카드 hardware triage, 사용자 + SD 손에)
1. **KV260 SD 빼서 노트북에서 점검** (3 case 분리):
   - 삽입 시 `dmesg` (노트북에서도 I/O error 나는가?)
   - `sudo fsck -n /dev/sdX2` (rootfs corruption — hard reset 잔재?)
   - read test: `sudo badblocks -nsv /dev/sdX` 또는 `sudo dd if=/dev/sdX of=/dev/null bs=4M`
   → **card-failing→교체** / **fs-corrupted→repair·reimage** / **card-fine→KV260 slot 또는 다른 12V 어댑터**
   - **2026-05-30 01:10 점검**: `/dev/sda`(USB 리더) 정상 마운트 — `sda1` system-boot(vfat 1G) + `sda2` writable(ext4 28G, 61% used). **boot 파티션 전체 read OK = 배드블록 X**, rootfs 구조 정상. → **SD 카드 기본 양호 (card-fine 쪽)**, KV260 슬롯/12V 전원 의심 ↑. rootfs `fsck -fn`: **ext4 손상 확정** — orphaned inode 21개(28133/55870/…) = **hard reset 4회 잔재**. SD 카드는 양호 → ★ **fs 손상이 부팅 hang 진짜 원인 유력**: 부팅 시 ext4 orphan cleanup 과부하 → I/O/CPU 폭증 → BPF/systemd lockup + mmc1 timeout으로 발현. **복구 완료**(2026-05-30 ~01:25): `fsck -fy` → orphan inode 21개 FIXED + extent tree optimize 4개, 최종 `fsck -fn` **CLEAN**(Pass 1-5 에러 0, MODIFIED 없음). 데이터 보존(216238 files). SD 재장착 부팅함.
   - **결과(01:50)**: fs는 정상(uptime **12min**까지 진행, 이전 8min보다↑)이나 **`kick_all_cpus_sync` SMP lockup 재발**(`load_module → flush_module_icache`, `uart_smp_lockup_kick_all_cpus_*.txt`). ★ **fs/SD 원인 아님 확정** (fs 복구·카드 read OK인데도 hang). BPF·module 둘 다 `kick_all_cpus_sync`=**CPU IPI 동기화 실패** → 진짜 root = **12V 전원 marginal(undervoltage) 또는 CPU/SMP 하드웨어**(undervoltage가 IPI 실패 + mmc1 timeout 동시 설명).
   - **다음**: ① **다른 12V 어댑터**(KV260 = 12V/3A+ 필요, 약하면 undervoltage) → ② 그래도면 KV260 SoM/슬롯 하드웨어. 보드 안정(~10min) 후 → HW Manager re-arm → **capture**.
2. 보드 부팅 → **~10분 안정 확인** (load 정상, lockup 없음)
3. HW Manager Auto Connect + ILA re-arm (Part C Tcl)
4. `dbg_step_03` stimulus → arvalid → **capture** → Part D 매트릭스로 root cause 확정
   (SW/bitstream은 모두 준비됨: SD에 v9, `.ltx` `/home/hwkim/v9.ltx`, trigger 레시피 Part C 검증완료)

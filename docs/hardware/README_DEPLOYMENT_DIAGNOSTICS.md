# FPST Deployment Build & Runtime Diagnostics

Tài liệu này là checklist thực hành để **build -> thu report -> nạp -> chạy chẩn đoán -> thu log** trên deployment `main` hiện hành.

Mục tiêu là sau mỗi bước, người vận hành có thể gửi lại report/log để kiểm tra các dấu hiệu như: **resource gần đầy, timing fail, Flash/RAM/stack vượt giới hạn, SPI/UART bất thường, RNG chưa sẵn sàng, session lệch, replay/auth failure, PQC treo, telemetry không commit hoặc hiệu năng RTT bất thường**.

> Đây là tài liệu vận hành bổ sung. Pin/wiring vẫn lấy từ `docs/hardware/FPST-WIRING-GUIDE-v1.1.md`; source/top/CST/SDC và compiler profile vẫn lấy từ README của từng target.

---

## 1. Những thứ cần giữ lại sau mỗi build

Không chỉ giữ `.fs`/`.hex`. Trước khi nạp, lưu cả report để có thể kiểm tra lại.

### Primer #1 — Gowin

Deployment input:

```text
Device  : GW2A-LV18PG256C8/I7
Top     : kiwi_primer20k_fpst_tx_top
Sources : targets/primer20k_1/sources-fpst-deployment.f
CST     : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst
SDC     : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.sdc
```

Sau synthesis + place & route + timing, lưu/chụp lại:

```text
- exact device/tool version
- synthesis result
- place & route result
- timing summary / worst slack
- clock summary
- LUT utilization
- FF/register utilization
- BSRAM utilization
- DSP utilization
- I/O utilization
- warning/error summary
- generated .fs
- SHA-256 của .fs
```

Bắt buộc: P&R/timing phải PASS. `sys_clk_i` là 27 MHz; SDC còn mô tả SPI SCK implementation envelope 5 MHz. Bring-up thật vẫn bắt đầu ở 1 MHz.

Không có một ngưỡng LUT riêng được project khóa cho P1; vì vậy **không tự đặt pass/fail giả**. Nếu bất kỳ resource nào rất gần giới hạn hoặc tool báo congestion/timing issue, giữ nguyên report và review trước khi nạp.

### Primer #2 — Gowin

Deployment input:

```text
Device  : GW2A-LV18PG256C8/I7
Top     : kiwi_primer20k_fpst_rx_top
Sources : targets/primer20k_2/sources-fpst-deployment.f
CST     : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.cst
SDC     : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.sdc
```

Lưu cùng nhóm report như P1:

```text
LUT / FF / BSRAM / DSP / I/O
P&R result
timing summary + worst slack
clock/constraint summary
warnings/errors
.fs + SHA-256
```

Bắt buộc: exact-device P&R/timing PASS trước khi coi image là candidate để nạp.

### Tiny 1P5 — Gowin

Deployment input:

```text
Device  : GW1N-UV1P5QN48XC7/I6
Top     : supervisor_top
Sources : targets/tiny1p5/sources.f
CST     : targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.cst
SDC     : targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.sdc
Clock   : 27 MHz
```

Lưu:

```text
LUT utilization
FF/register utilization
other resource utilization
timing summary / worst slack
warnings/errors
.fs + SHA-256
```

**Tiny project gate: LUT <= 70% và 27 MHz timing PASS.**

### SN32F407F — Keil / ARM Compiler 6

Final image phải theo:

```text
targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md
```

Và dùng:

```text
INCLUDE : fpst_sn32f407_dual_main.c
EXCLUDE : fpst_sn32f407_main.c
```

Build profile:

```text
Device : SONiX SN32F407F
Flash  : 32 KiB
SRAM   : 8 KiB
ARM Compiler 6
Optimization : -O2
Heap : 0 nếu không thực sự cần
Initial stack target : 0x800 = 2 KiB
```

Sau build lưu:

```text
- full build log
- Keil "Program Size" summary nếu tool hiển thị
- .map / linker memory report
- Flash region usage
- RW/ZI/static RAM usage
- call graph / stack-usage report
- worst-case stack estimate/evidence
- warning/error summary
- generated .hex
- SHA-256 của .hex
```

Release gate:

```text
Flash <= 0x8000 = 32768 bytes
static SRAM + verified worst-case stack <= 0x2000 = 8192 bytes
```

Không chỉ nhìn linker báo build thành công. Nếu không có stack/call-graph evidence thì chưa đủ để kết luận SRAM an toàn.

---

## 2. Những dấu hiệu build cần báo lại để review

Dừng và review trước khi nạp nếu thấy một trong các trường hợp:

```text
ERROR trong synthesis / P&R / linker
Timing FAIL hoặc negative slack
clock/path quan trọng bị unconstrained
resource chạm/gần device limit
Tiny LUT > 70%
Flash SN32 > 32 KiB
SRAM + worst-case stack > 8 KiB
stack evidence thiếu hoặc không rõ
multiple-driver / combinational-loop / severe placement warning
CST pin conflict / I/O standard conflict
.hex hoặc .fs không được tạo đúng target
```

Warning không tự động đồng nghĩa lỗi. Giữ nguyên warning text để phân loại thay vì tự bỏ qua.

---

## 3. Gate A — sau khi nạp, trước khi cho SPI production chạy

SN32 build đầu tiên phải giữ:

```text
FPST_SN32F407_HARNESS_VERIFIED=0
```

Ở Gate A, Primer BTP traffic bị firmware cố ý block. Đây là trạng thái an toàn để kiểm UART, ADC/RNG và phần điện.

### Cài PC host

Windows:

```powershell
cd software/host
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -e .
python -m unittest discover -s tests -v
```

Liệt kê COM:

```powershell
fpst-host ports
```

Thay `COM5` bằng cổng thực tế.

### Chẩn đoán Gate A

```powershell
fpst-host probe --port COM5
fpst-host wiring --port COM5
fpst-host rng-status --port COM5
```

Ở build `HARNESS_VERIFIED=0`:

```text
wiring=UNVERIFIED
```

và lệnh cần Primer có thể trả `BLOCKED`. **Đó là đúng thiết kế, không phải bug.**

Kiểm ADC vài lần bằng CLI MCU/host:

```powershell
fpst-host adc --port COM5
```

Lặp lại nhiều lần và lưu output nếu cần đánh giá entropy path. `rng-status` mong muốn cuối cùng là:

```text
rng=ADC_P20-conditioned READY (research/competition)
```

Nếu RNG blocked, thử có kiểm soát:

```powershell
fpst-host rng-reseed --port COM5 --yes
fpst-host rng-status --port COM5
```

RNG chưa READY không nhất thiết chứng minh board hỏng, nhưng **ML-KEM live session sẽ bị block** và cần kiểm ADC/entropy trước khi tiếp tục.

Ngoài CLI, Gate A vẫn phải continuity/common-ground/no-contention theo wiring guide.

---

## 4. Gate B — SPI thật sau khi continuity đã PASS

Chỉ sau Gate A mới rebuild SN32 với:

```text
FPST_SN32F407_HARNESS_VERIFIED=1
```

Bắt đầu SPI Mode 0 / MSB-first / **1 MHz**.

### Chạy bộ kiểm tra đầu tiên

```powershell
fpst-host wiring   --port COM5
fpst-host ping     --port COM5
fpst-host ping2    --port COM5
fpst-host discover --port COM5
fpst-host selftest --port COM5
fpst-host status   --port COM5
fpst-host status2  --port COM5
fpst-host pqc-status --port COM5
fpst-host fault    --port COM5
```

Kỳ vọng chính:

```text
wiring=verified-two-primer
ping / ping2 -> OK
selftest-pair=PASS
pqc=idle khi không có operation đang chạy
không có REMOTE_ERR / ERR bất ngờ
```

Nếu `pqc=busy` đứng mãi khi hệ thống đang idle, giữ log vì đó là dấu hiệu cần điều tra.

Có thể chạy demo chuẩn và ghi JSONL:

```powershell
fpst-host demo --port COM5 --log results/pc/bringup.jsonl
```

Demo chuẩn:

```text
wiring -> discover -> selftest -> status -> status2 -> rng-status
```

---

## 5. Session + telemetry consistency checks

Sau khi có receiver ML-KEM-512 public key 800 byte:

```powershell
fpst-host kem-session `
  --port COM5 `
  --public-key receiver_mlkem512_pk.bin `
  --session-id 0x10203040 `
  --ciphertext-out session.ct `
  --yes
```

Linux dùng `\` thay PowerShell backtick.

Sau khi session thành công:

```powershell
fpst-host key-status  --port COM5
fpst-host key-status2 --port COM5
fpst-host rx-counters --port COM5
fpst-host fault       --port COM5
```

Các invariant quan trọng:

```text
P1 session_id == P2 session_id
P1 active=1 và P2 active=1
ngay sau session: P1 tx_seq == P2 expected == 0
```

Gửi một telemetry sample:

```powershell
fpst-host telemetry --port COM5 --yes
fpst-host key-status  --port COM5
fpst-host key-status2 --port COM5
fpst-host rx-counters --port COM5
```

Normal-path mong muốn:

```text
telemetry=COMMITTED
P1 tx_seq == P2 expected
accepted tăng đúng theo số packet commit
replay không tự tăng
Auth_fail không tự tăng
```

Dấu hiệu bất thường cần giữ log:

```text
P1 tx_seq != P2 expected sau một transaction đã kết thúc
accepted không tăng dù telemetry báo COMMITTED
replay tăng trong normal path
Auth_fail tăng trong normal path
REMOTE_ERR / ERR xuất hiện không do test chủ động
session_active của hai Primer không giống nhau
```

---

## 6. Zeroize / recovery checks

Trước zeroize, lưu:

```powershell
fpst-host key-status  --port COM5
fpst-host key-status2 --port COM5
fpst-host rx-counters --port COM5
fpst-host fault       --port COM5
```

Zeroize:

```powershell
fpst-host zeroize --port COM5 --yes
```

Sau đó kiểm lại:

```powershell
fpst-host key-status  --port COM5
fpst-host key-status2 --port COM5
fpst-host rx-counters --port COM5
fpst-host rng-status  --port COM5
fpst-host fault       --port COM5
```

Yêu cầu an toàn chính:

```text
old P1/P2 session không còn active
old session/key không được tự resurrect
SN32 CSPRNG đã bị zeroize nên rng-status có thể/được mong đợi trở về BLOCKED cho tới reseed
```

Để tạo session mới sau explicit zeroize:

```powershell
fpst-host rng-reseed --port COM5 --yes
fpst-host rng-status --port COM5
```

Chỉ tiếp tục KEM khi RNG READY.

---

## 7. Runtime fault/counter monitoring

Các lệnh nên dùng khi thấy hành vi lạ:

```powershell
fpst-host status      --port COM5
fpst-host status2     --port COM5
fpst-host key-status  --port COM5
fpst-host key-status2 --port COM5
fpst-host pqc-status  --port COM5
fpst-host rx-counters --port COM5
fpst-host rng-status  --port COM5
fpst-host fault       --port COM5
```

MCU `fault` trả ít nhất:

```text
session_state
last_status
last_detail
```

P2 `rx-counters` trả:

```text
accepted
replay
auth_fail
expected_sequence
```

Khi báo lỗi, luôn chụp/lưu **cả trạng thái trước và sau sự kiện**, không chỉ dòng lỗi cuối cùng.

---

## 8. Hiệu năng / RTT

PC host có benchmark read-only. Bắt đầu với 100 mẫu ở 1 MHz:

```powershell
fpst-host bench ping    --port COM5 --count 100
fpst-host bench ping2   --port COM5 --count 100
fpst-host bench status  --port COM5 --count 100
fpst-host bench status2 --port COM5 --count 100
```

Host report RTT quan sát từ PC (min/mean/p50/p95/max). Đây **không phải FPGA cycle count**, nhưng rất hữu ích để phát hiện timeout, jitter hoặc endpoint chậm bất thường.

Khi qualification SPI 1 -> 2 -> 3 -> 4 -> 5 MHz, chỉ tăng tốc sau khi rate trước đã PASS logic-analyzer + transaction tests. Không có CLI runtime nào trong deployment hiện tại để tự đổi SPI clock; thay đổi rate phải theo build/configuration profile đã kiểm soát.

Ở mỗi rate, nên lưu:

```text
SPI rate
ping P1 RTT summary
ping P2 RTT summary
selftest result
telemetry result
rx-counters before/after
logic-analyzer capture
```

---

## 9. Heartbeat / supervisor physical observations

Không có PC command thay thế được scope/logic analyzer cho phần này.

Cần quan sát:

```text
SN32 heartbeat -> Tiny khoảng 100 ms/transition
P1 heartbeat   -> Tiny khoảng 100 ms/transition
P2 heartbeat   -> Tiny khoảng 100 ms/transition
Tiny watchdog  -> fault sau khoảng project-profile 350 ms không có transition
```

Khi zeroize/safe-lock nhưng Primer logic vẫn sống, P1/P2 heartbeat phải tiếp tục toggle. Nếu heartbeat dừng chỉ vì security state, đó là bất thường đối với current recovery architecture.

P2 local auth-threshold fault route:

```text
P2 J2-12/T13 -> Tiny J1-11/pin15
```

phải được continuity/level-check thật trước khi coi là verified.

---

## 10. Bộ dữ liệu tối thiểu nên gửi lại để review

### Sau build FPGA

Cho từng P1/P2/Tiny:

```text
1. exact device + Gowin version
2. synthesis summary
3. P&R summary
4. timing summary + worst slack
5. LUT/FF/BSRAM/DSP/I/O utilization (những resource tool có report)
6. warning/error list
7. tên + SHA-256 .fs
```

### Sau build SN32

```text
1. Keil/ARM Compiler version + DFP
2. full build result / Program Size line
3. .map / memory-region usage
4. RW/ZI/static RAM
5. call graph / worst-case stack
6. warning/error list
7. tên + SHA-256 .hex
```

### Sau bring-up

```text
fpst-host demo output/log
key-status + key-status2
rx-counters trước/sau telemetry
fault output
rng-status
100-sample ping/ping2 RTT benchmark
logic-analyzer screenshot nếu đang qualify SPI
heartbeat/fault/zeroize waveform nếu đang test Tiny
```

Không gửi private ML-KEM key, shared secret, `K_TX`, `NP_TX`, CSPRNG seed hoặc secret khác.

---

## 11. Quick run sheet

```text
[BUILD]
P1 Gowin -> resource + timing + .fs
P2 Gowin -> resource + timing + .fs
Tiny Gowin -> LUT <=70% + timing + .fs
SN32 Keil -> Flash/RAM/stack + .hex

[GATE A]
HARNESS_VERIFIED=0
ports -> probe -> wiring -> adc -> rng-status
continuity + GND + no-contention

[GATE B]
HARNESS_VERIFIED=1
SPI 1 MHz
wiring -> ping -> ping2 -> discover -> selftest -> status/status2

[SESSION]
kem-session
key-status + key-status2
telemetry
rx-counters
fault

[PERFORMANCE]
bench ping/ping2/status/status2 --count 100
logic analyzer

[SECURITY]
zeroize
check old session gone
rng-status -> reseed -> READY
fault/recovery + heartbeat waveform

[THEN]
qualify 2 -> 3 -> 4 -> 5 MHz one step at a time
```

# Deployment Targets

Thư mục này là điểm vào duy nhất để xác định **code nào dùng cho thiết bị nào**, **build bằng công cụ nào** và **artifact nào cần nạp hoặc chạy**.

## Target index

| Target | Thiết bị | Vai trò | Trạng thái |
|---|---|---|---|
| [`primer20k_1`](primer20k_1/README.md) | Kiwi Primer 20K #1 | NTT/INTT, Ascon encrypt, STP TX | NTT self-test đã có; phần còn lại đang phát triển |
| [`primer20k_2`](primer20k_2/README.md) | Kiwi Primer 20K #2 | Ascon decrypt/verify, STP RX, replay | Chưa triển khai RTL target |
| [`tiny1p5`](tiny1p5/README.md) | Kiwi FPGA Tiny 1P5 | Supervisor/watchdog/tamper | Chưa triển khai RTL target |
| [`sn32f407`](sn32f407/README.md) | SONiX SN32F407 EVK | Firmware control và PC–FPGA bridge | Chưa khóa pin/protocol |
| [`pc`](pc/README.md) | Máy tính | Host, golden model, simulation, benchmark | Golden NTT đã có; host app chưa hoàn tất |

## Artifact map

```text
Primer 20K #1  <- Gowin .fs
Primer 20K #2  <- Gowin .fs
Tiny 1P5       <- Gowin .fs
SN32F407       <- firmware .hex/.bin
PC             <- Python/C++ executables and test commands
```

## Layout rule

Mỗi target có thể chứa:

```text
targets/<target>/
├── README.md       vai trò, top, build, nạp và trạng thái
├── sources.f       source manifest cho FPGA target, khi đã có
├── constraints/    constraint riêng của target, khi được khóa
├── rtl/            chỉ top/wrapper gắn với target
├── firmware/       chỉ với MCU target
└── scripts/        build/program helper riêng của target
```

Các core dùng chung như NTT, Ascon, telemetry và supervisor **không được copy vào từng target**. Chúng vẫn ở `rtl/`; target chỉ tham chiếu bằng manifest. Quy tắc này tránh hai bản cùng một thuật toán bị lệch nhau.

## Spec baseline

Mọi target mới phải đối chiếu `FPST-SYS-SPEC-001 v1.1`. Nếu target chưa đủ thông tin phần cứng hoặc interface, ghi `TBD` thay vì tự chọn pin, protocol hoặc error behavior.
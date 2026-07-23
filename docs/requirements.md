# Project Requirements

Tài liệu này là bản yêu cầu ban đầu. Các mục đánh dấu **TBD** phải được chốt trước khi thiết kế RTL chi tiết.

## 1. Functional requirements

- FR-01: Hệ thống tạo hoặc tiếp nhận session key từ luồng ML-KEM.
- FR-02: NTT/INTT accelerator nhận dữ liệu đa thức và trả kết quả đúng theo golden model.
- FR-03: Hệ thống mã hóa và xác thực telemetry bằng Ascon-AEAD128.
- FR-04: Mỗi packet có version, type, sequence counter, payload length, nonce-related fields và authentication tag.
- FR-05: Receiver từ chối packet có tag sai.
- FR-06: Receiver từ chối packet bị phát lại theo chính sách sequence counter.
- FR-07: Supervisor ghi nhận timeout, authentication failure, replay và tamper event.
- FR-08: Sự kiện nghiêm trọng kích hoạt zeroize hoặc vô hiệu hóa session key.
- FR-09: Host có thể thu latency, cycle count và trạng thái lỗi.

## 2. Verification requirements

- VR-01: Mỗi arithmetic primitive có unit test.
- VR-02: NTT và INTT được kiểm tra round-trip và so sánh vector chuẩn.
- VR-03: Ascon được kiểm tra bằng known-answer test chính thức hoặc vector tham chiếu đáng tin cậy.
- VR-04: Test tích hợp phải bao gồm packet hợp lệ, tag sai, replay, counter bất thường và timeout.
- VR-05: Mọi lỗi kiểm thử phải tái tạo được bằng seed hoặc vector lưu trong repository.

## 3. Performance requirements

Các ngưỡng sau đang để TBD:

- Clock target: **TBD MHz**.
- NTT latency target: **TBD cycles**.
- ML-KEM encapsulation/decapsulation latency: **TBD**.
- Telemetry throughput: **TBD packet/s**.
- LUT/FF/BRAM/DSP budget: **TBD theo board**.

## 4. Platform requirements

- Board chính: **TBD**.
- Toolchain: **TBD theo board**.
- HDL ưu tiên: SystemVerilog; có thể dùng Verilog khi toolchain hạn chế.
- Simulation: ưu tiên công cụ có thể tự động hóa bằng command line.
- Host software: Python hoặc C/C++, lựa chọn sau khi chốt giao tiếp.

## 5. Security assumptions

- Thiết kế hiện tại tập trung vào tính đúng chức năng và kiến trúc hệ thống.
- Side-channel resistance, fault injection resistance và secure key storage chưa được mặc định coi là đã giải quyết.
- Không công bố secret key, seed bí mật hoặc token trong log và repository.
- Không dùng kết quả nghiên cứu này cho production trước khi được đánh giá độc lập.

## 6. Quyết định cần chốt sớm

1. Board nào dùng làm mục tiêu chính?
2. Chọn ML-KEM-512, ML-KEM-768 hay ML-KEM-1024?
3. Giao tiếp PC–FPGA dùng UART, SPI, USB hay soft-core bus?
4. NTT accelerator nhận cả đa thức hay chỉ thực hiện butterfly/multiply service?
5. Ascon triển khai RTL hoàn toàn hay software trước, RTL sau?
6. Demo cuối cần chứng minh các chỉ số nào?

# BRAM-Friendly Ping-Pong Coefficient Memory

## Mục tiêu

M5.1 thay bộ nhớ hệ số bất đồng bộ của M5 bằng hai bank RAM đồng bộ 256×16 bit. Mỗi tầng NTT đọc toàn bộ hệ số từ một bank và ghi kết quả sang bank còn lại.

```text
Tầng chẵn: bank 0 --read--> butterfly --write--> bank 1
Tầng lẻ:  bank 1 --read--> butterfly --write--> bank 0
```

Bank chỉ được đổi vai trò sau khi kết quả butterfly cuối cùng của tầng đã được ghi xong.

## Thành phần

- `true_dual_port_ram_256x16.sv`: RAM hai cổng thực, đọc đồng bộ và ghi đồng bộ.
- `coefficient_pingpong_memory_256x16.sv`: ghép hai RAM, định tuyến cổng đọc/ghi và quản lý bank đang hoạt động.
- `forward_ntt_core.sv`: dùng RAM đồng bộ, stage barrier và metadata FIFO để giữ đúng thứ tự writeback.

## Giao diện host

Host chỉ được truy cập khi `host_ready_o == 1`.

- Ghi: đặt `host_we_i`, địa chỉ và dữ liệu trước cạnh lên clock.
- Đọc: phát một xung `host_re_i`; `host_rvalid_o` và `host_rdata_o` xuất hiện sau cạnh lên kế tiếp.
- Khi core đang chạy, các yêu cầu host bị chặn.

RAM không được xóa theo reset. Sau reset hoặc sau khi hủy một transform, phần mềm phải nạp lại đủ 256 hệ số trước khi phát `start_i`.

## Vì sao dùng ping-pong

Một butterfly cần đọc hai hệ số và ghi hai kết quả. Một true dual-port RAM có đúng hai cổng, nên một RAM đơn không thể vừa cấp hai lần đọc vừa nhận hai lần ghi trong cùng một chu kỳ. Hai bank cho phép:

- bank nguồn dùng cả hai cổng để đọc;
- bank đích dùng cả hai cổng để ghi;
- duy trì một butterfly mới mỗi chu kỳ khi pipeline không bị stall;
- loại bỏ read-after-write hazard giữa các tầng.

## Ràng buộc stage barrier

Khi scheduler phát giao dịch cuối tầng:

1. `stage_barrier_o` được bật;
2. scheduler ngừng phát giao dịch mới;
3. các request đang nằm trong ROM, RAM và butterfly pipeline tiếp tục chạy;
4. kết quả cuối tầng được ghi vào bank đích;
5. `swap_i` đổi bank nguồn/đích;
6. barrier được gỡ và tầng kế tiếp bắt đầu.

Mỗi forward NTT có đúng 7 barrier và 7 lần đổi bank.

## Kiểm chứng

Testbench kiểm tra:

- đọc host đồng bộ và tín hiệu `host_rvalid_o`;
- hai lần đọc đồng thời;
- hai lần ghi đồng thời vào bank đích;
- đổi bank đúng sau writeback cuối tầng;
- reset chỉ khôi phục bank chọn, không xóa RAM;
- đủ 5 vector NTT và 1280 hệ số khớp golden model;
- host access bị từ chối khi core bận.

Yosys được dừng trước bước memory mapping và bắt buộc phải tìm đúng hai cell `$mem_v2`. Đây là kiểm tra độc lập rằng hai mảng hệ số vẫn còn ở dạng memory sau RTL lowering.

## Giới hạn

Việc Yosys giữ lại hai memory cell chưa đồng nghĩa đã ánh xạ thành BRAM trên một FPGA cụ thể. Kết quả cuối cùng vẫn phải được xác nhận bằng Vivado hoặc Gowin EDA với đúng mã chip, constraint và báo cáo utilization/timing của board.

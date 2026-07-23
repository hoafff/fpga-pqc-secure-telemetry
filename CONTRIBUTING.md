# Contributing

## Quy trình làm việc

1. Tạo branch theo mẫu:
   - `feature/<ten-chuc-nang>`
   - `fix/<ten-loi>`
   - `docs/<noi-dung>`
2. Mỗi commit chỉ nên giải quyết một thay đổi rõ ràng.
3. Trước khi mở pull request, chạy testbench liên quan và ghi kết quả.
4. Pull request phải mô tả:
   - Mục tiêu thay đổi.
   - Giao diện module bị ảnh hưởng.
   - Cách kiểm thử.
   - Kết quả mô phỏng/tổng hợp nếu có.
5. Không merge code RTL chưa có testbench hoặc chưa đối chiếu với golden model.

## Quy ước commit

```text
feat: thêm chức năng
fix: sửa lỗi
test: thêm hoặc sửa kiểm thử
rtl: thay đổi RTL
docs: cập nhật tài liệu
chore: cấu hình và công việc hỗ trợ
```

## Quy ước RTL

- Ưu tiên SystemVerilog.
- Tín hiệu input dùng hậu tố `_i`, output dùng `_o`.
- Reset active-low dùng tên `rst_n`.
- Parameter và localparam viết hoa.
- Tránh magic number; đưa hằng số vào parameter/package.
- Module tuần tự dùng `always_ff`, logic tổ hợp dùng `always_comb`.
- Mỗi module phải ghi rõ giả thiết miền dữ liệu đầu vào.

## Definition of Done

Một task RTL chỉ được coi là hoàn thành khi:

- Code compile thành công.
- Unit test pass.
- Có kiểm thử biên và trường hợp lỗi phù hợp.
- Kết quả khớp golden model.
- Tài liệu giao diện được cập nhật.
- Không có secret hoặc file sinh tự động trong commit.

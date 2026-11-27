# Minh Tú – Chấm công & xếp ca

Ứng dụng chấm công, xếp ca và tính lương cho nhân viên **Nhà sách Minh Tú**. Gồm hai phần dùng chung một app:

- **Nhân viên:** chấm công vào/ra, xem lịch làm việc chung, đăng ký lịch, gửi yêu cầu, tạm ứng lương, xem lương đang giữ, tiến trình tự động tăng lương, phiếu lương, bảng tin, tin nhắn.
- **Quản lý:** xếp ca, duyệt đăng ký lịch / yêu cầu / tạm ứng, giữ và trả lại lương, đặt quy tắc tự động tăng lương, chốt và trả kỳ lương, đăng bảng tin, nhắn tin, quản lý đơn giá nhân viên.

App dùng trên điện thoại, có 4 tab: **Trang chủ, Tác vụ, Tin nhắn, Tài khoản**.

## Kiến trúc

```
Trình duyệt (frontend/index.html, GitHub Pages)
        │  supabase-js (HTTPS + Realtime WebSocket)
        ▼
Supabase
 ├─ Auth           đăng nhập email/mật khẩu, JWT + refresh token
 ├─ PostgREST      API REST tự sinh từ schema public
 ├─ RPC (plpgsql)  nghiệp vụ: chấm công, phiếu lương, tạm ứng, duyệt đơn, tự động tăng lương
 ├─ RLS            phân quyền theo từng dòng dữ liệu (cửa hàng / quản lý / nhân viên)
 └─ Realtime       tin nhắn, bảng tin, lịch, đơn cập nhật tức thì
```

Toàn bộ quy tắc nghiệp vụ và phân quyền nằm **trong database**, nên frontend không thể vượt quyền dù bị sửa code:

| Quy tắc | Nơi kiểm soát |
|---|---|
| Giờ vào/ra lấy theo giờ **máy chủ** (Asia/Ho_Chi_Minh), không tin giờ điện thoại | `clock_in()`, `clock_out()` |
| Chỉ chấm công được ca mình được xếp, sớm nhất 60 phút trước giờ vào ca; số phút muộn do server tính | `clock_in()` |
| Tạm ứng không vượt hạn mức mỗi kỳ, không ứng khi kỳ đã chốt | `request_advance()` |
| Tự động tăng lương khi đủ giờ công và không vượt số lần đi muộn; chạy ngay khi kết thúc ca | trigger `attendance_auto_raise` → `app.apply_auto_raise()` |
| Quản lý sửa đơn giá bằng tay được ghi lại vào lịch sử | trigger `profiles_rate_change` |
| Thực nhận = lương giờ công (theo đơn giá tại từng ngày) − tạm ứng − giữ lương + trả lại lương giữ | `get_payslip()` |
| Nhân viên chỉ thấy công, lương, đơn, chat riêng của mình; quản lý thấy cả cửa hàng | RLS trên mọi bảng |
| Nhân viên tự đăng ký tài khoản bằng **mã cửa hàng**; mã sai thì không tạo được | trigger `on_auth_user_created` |

## Cấu trúc thư mục

```
frontend/
  index.html        app (HTML + CSS + JS, không cần build)
  config.js         URL + publishable key của project Supabase
supabase/
  migrations/
    ..._schema.sql     bảng, ràng buộc, chỉ mục
    ..._security.sql   hàm phân quyền, đăng ký bằng mã cửa hàng, RLS
    ..._business.sql   RPC nghiệp vụ, tự động tăng lương, realtime
  seed.sql          dữ liệu mẫu (7 tài khoản, ~75 ngày chấm công)
  tests/            kiểm thử phân quyền + nghiệp vụ (chạy trong CI)
  config.toml       cấu hình Supabase CLI
.github/workflows/
  ci.yml            chạy migrations + seed + kiểm thử trên PostgreSQL 16
  pages.yml         deploy frontend lên GitHub Pages
```

## Mô hình dữ liệu

`stores` (cấu hình cửa hàng, kỳ lương, quy tắc tăng lương) · `profiles` (nhân viên/quản lý, đơn giá) · `shift_templates` (ca sáng/chiều/tối) · `shift_assignments` (lịch chung) · `attendance` (chấm công) · `shift_registrations` + `registration_slots` (đăng ký lịch) · `requests` (yêu cầu) · `salary_advances` (tạm ứng) · `salary_holds` (lương giữ) · `raise_history` (lịch sử tăng lương) · `pay_periods` (kỳ đã chốt/đã trả) · `posts` + `post_reads` (bảng tin) · `messages` (tin nhắn nhóm và chat riêng).

## Cài đặt

### 1. Tạo project Supabase
Tạo project trên [supabase.com](https://supabase.com/dashboard), chọn region **Singapore (ap-southeast-1)**.

### 2. Đẩy database lên
```bash
npm i -g supabase            # hoặc: brew install supabase/tap/supabase
supabase login
supabase link --project-ref <project-ref>
supabase db push --include-seed   # chạy migrations + dữ liệu mẫu
```
Không dùng CLI thì mở **SQL Editor** và chạy lần lượt 3 file trong `supabase/migrations/`, rồi `supabase/seed.sql`.

### 3. Cấu hình frontend
Điền vào `frontend/config.js` (lấy ở **Project Settings → API Keys**):
```js
window.MINHTU_CONFIG = { url: 'https://<project-ref>.supabase.co', key: 'sb_publishable_...' };
```
Publishable key được phép công khai: mọi quyền đã do RLS kiểm soát. **Không bao giờ** đưa `service_role`/secret key vào frontend.

Trong **Authentication → URL Configuration**, thêm địa chỉ GitHub Pages vào *Site URL* / *Redirect URLs*.

### 4. Chạy thử trên máy
```bash
cd frontend && python3 -m http.server 5500   # mở http://localhost:5500
```

### 5. Deploy
Push lên nhánh `main` → workflow **pages.yml** đưa thư mục `frontend/` lên GitHub Pages (bật *Settings → Pages → Source: GitHub Actions* nếu được hỏi).

## Tài khoản demo (từ `seed.sql`)

Mật khẩu chung: `MinhTu@2026`. Mã cửa hàng để nhân viên mới tự đăng ký: `MINHTU2026`.

| Email | Vai trò |
|---|---|
| quanly@minhtu.vn | Quản lý – Hồ Mỹ Hạnh |
| linh@minhtu.vn | Thu ngân – Nguyễn Thảo Linh |
| khang@, ngoc@, huy@, truc@, an@minhtu.vn | Nhân viên |

> Đây là dữ liệu demo. Khi dùng thật: đổi mật khẩu/xoá các tài khoản này, đổi `join_code` của cửa hàng, bật xác nhận email.

## Kiểm thử

```bash
psql "$DATABASE_URL" -f supabase/tests/ci/auth_stub.sql      # chỉ khi chạy trên PostgreSQL thường
for f in supabase/migrations/*.sql; do psql "$DATABASE_URL" -f $f; done
psql "$DATABASE_URL" -f supabase/seed.sql
psql "$DATABASE_URL" -f supabase/tests/business_test.sql
```
Kiểm thử bao gồm: RLS của nhân viên/quản lý/khách, chấm công vào-ra, chặn vào ca hai lần, tự động tăng lương, hạn mức tạm ứng, đăng ký và duyệt lịch, công thức phiếu lương, ghi lịch sử chỉnh đơn giá, đăng ký bằng mã cửa hàng. Toàn bộ chạy trong transaction và rollback.

## Việc có thể làm tiếp

- Xác thực chấm công thật: QR động đổi mỗi 30 giây tại quầy (Edge Function ký mã), hoặc kiểm tra IP Wi-Fi cửa hàng.
- Thông báo đẩy (Web Push) khi đơn được duyệt / có tin nhắn.
- Xuất phiếu lương PDF, nhắc chốt công tự động bằng `pg_cron`.

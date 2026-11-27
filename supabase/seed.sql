-- =====================================================================
-- Dữ liệu mẫu cho Nhà sách Minh Tú (chỉ dùng để demo / phát triển)
-- Tài khoản demo (mật khẩu chung: MinhTu@2026):
--   quanly@minhtu.vn  – Quản lý Hồ Mỹ Hạnh
--   linh@minhtu.vn    – Thu ngân Nguyễn Thảo Linh
--   khang@, ngoc@, huy@, truc@, an@minhtu.vn
-- Đổi mật khẩu hoặc xoá các tài khoản này trước khi dùng thật.
-- =====================================================================
do $$
declare
  v_store uuid := '11111111-1111-4111-8111-111111111111';
  v_pw text := extensions.crypt('MinhTu@2026', extensions.gen_salt('bf'));
  v_today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_now timestamp := now() at time zone 'Asia/Ho_Chi_Minh';
  v_mon date;
  u record; d date; i int := 0; j int; k int;
  ids uuid[] := array[]::uuid[];
  v_mgr uuid := '22222222-2222-4222-8222-000000000000';
  sh record; v_in timestamp; v_out timestamp; v_late int; v_rand float;
begin
  perform setseed(0.42);

  insert into public.stores (id, name, join_code) values (v_store, 'Nhà sách Minh Tú', 'MINHTU2026');

  insert into public.shift_templates (store_id, code, name, start_time, end_time, capacity, sort) values
    (v_store, 'S', 'Ca sáng', '07:30', '12:00', 3, 1),
    (v_store, 'C', 'Ca chiều', '12:00', '17:00', 3, 2),
    (v_store, 'T', 'Ca tối', '17:00', '22:00', 3, 3);

  -- tài khoản (trigger on_auth_user_created tự tạo hồ sơ theo mã cửa hàng)
  for u in select * from (values
      (v_mgr,                                  'quanly@minhtu.vn', 'Hồ Mỹ Hạnh',       'Quản lý cửa hàng', '0909 000 111', 0,     0),
      ('22222222-2222-4222-8222-000000000001'::uuid, 'linh@minhtu.vn',  'Nguyễn Thảo Linh', 'Thu ngân',     '0901 234 567', 25000, 40),
      ('22222222-2222-4222-8222-000000000002'::uuid, 'khang@minhtu.vn', 'Trần Minh Khang',  'Kho',          '0902 345 678', 24000, 52),
      ('22222222-2222-4222-8222-000000000003'::uuid, 'ngoc@minhtu.vn',  'Lê Bảo Ngọc',      'Tư vấn sách',  '0903 456 789', 23000, 18),
      ('22222222-2222-4222-8222-000000000004'::uuid, 'huy@minhtu.vn',   'Phạm Gia Huy',     'Thu ngân',     '0904 567 890', 25000, 30),
      ('22222222-2222-4222-8222-000000000005'::uuid, 'truc@minhtu.vn',  'Võ Thanh Trúc',    'Tư vấn sách',  '0905 678 901', 23000, 8),
      ('22222222-2222-4222-8222-000000000006'::uuid, 'an@minhtu.vn',    'Đỗ Quốc An',       'Kho',          '0906 789 012', 24000, 45)
    ) as t(id, email, name, pos, phone, rate, cycle) loop
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, email_change, email_change_token_new, recovery_token)
    values ('00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email, v_pw, now(),
            '{"provider":"email","providers":["email"]}',
            jsonb_build_object('full_name', u.name, 'join_code', 'MINHTU2026', 'phone', u.phone),
            now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), u.id, u.id::text, jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
            'email', now(), now(), now());

    perform set_config('app.auto_raise', 'on', true);  -- không ghi lịch sử "điều chỉnh tay" cho dữ liệu mẫu
    if u.id = v_mgr then
      update public.profiles set role = 'manager', position = u.pos, hourly_rate = 0 where id = u.id;
    else
      update public.profiles set position = u.pos, hourly_rate = u.rate,
             raise_cycle_start = v_today - u.cycle where id = u.id;
      ids := ids || u.id;
      if u.email <> 'an@minhtu.vn' then
        insert into public.raise_history (store_id, staff_id, from_rate, to_rate, effective_on, reason) values
          (v_store, u.id, u.rate - 2000, u.rate - 1000, v_today - u.cycle - 70, 'Đủ 300 giờ công, đi muộn 2 lần'),
          (v_store, u.id, u.rate - 1000, u.rate,        v_today - u.cycle,      'Đủ 300 giờ công, đi muộn 1 lần');
      end if;
    end if;
    perform set_config('app.auto_raise', 'off', true);
  end loop;

  -- lịch làm việc chung: 75 ngày trước tới 28 ngày sau, mỗi ca 2 người xoay vòng
  for d in select generate_series(v_today - 75, v_today + 28, interval '1 day')::date loop
    j := 0;
    for sh in select * from public.shift_templates where store_id = v_store order by sort loop
      for k in 0..1 loop
        insert into public.shift_assignments (store_id, work_date, shift_id, staff_id)
        values (v_store, d, sh.id, ids[((i + j * 2 + k) % 6) + 1]) on conflict do nothing;
      end loop;
      j := j + 1;
    end loop;
    i := i + 1;
  end loop;
  -- hôm nay Linh làm ca tối
  delete from public.shift_assignments where work_date = v_today and staff_id = ids[1];
  insert into public.shift_assignments (store_id, work_date, shift_id, staff_id)
  select v_store, v_today, id, ids[1] from public.shift_templates where store_id = v_store and code = 'T';

  -- chấm công cho các ca đã qua (cả các ca hôm nay đã bắt đầu, trừ Linh)
  for sh in select a.*, s.start_time, s.end_time from public.shift_assignments a
            join public.shift_templates s on s.id = a.shift_id
            where a.work_date < v_today
               or (a.work_date = v_today and a.work_date + s.start_time < v_now and a.staff_id <> ids[1])
            order by a.work_date, s.sort loop
    v_rand := random();
    continue when v_rand < 0.03;              -- vắng
    v_in := sh.work_date + sh.start_time + make_interval(mins => -8 + floor(random() * 12)::int);
    if random() < 0.08 then v_in := v_in + make_interval(mins => 6 + floor(random() * 15)::int); end if;
    v_out := sh.work_date + sh.end_time + make_interval(mins => -2 + floor(random() * 10)::int);
    v_in := least(v_in, v_now);
    if v_out > v_now then v_out := null; end if;
    v_late := greatest(0, floor(extract(epoch from v_in - (sh.work_date + sh.start_time)) / 60)::int - 5);
    insert into public.attendance (store_id, staff_id, work_date, shift_id, check_in, check_out, method, late_minutes)
    values (v_store, sh.staff_id, sh.work_date, sh.shift_id,
            v_in at time zone 'Asia/Ho_Chi_Minh', v_out at time zone 'Asia/Ho_Chi_Minh',
            case when random() < 0.5 then 'QR tại quầy' else 'Wi-Fi cửa hàng' end, v_late);
  end loop;

  -- yêu cầu
  insert into public.requests (store_id, staff_id, type, for_date, note, status) values
    (v_store, ids[3], 'Nghỉ phép',    v_today + 1, 'Đi khám răng buổi sáng', 'pending'),
    (v_store, ids[2], 'Đổi ca',       v_today + 2, 'Đổi ca chiều sang ca tối với Huy', 'pending'),
    (v_store, ids[1], 'Bổ sung công', v_today - 3, 'Quên bấm ra ca tối, về lúc 22:05', 'approved');

  -- tạm ứng, lương giữ
  insert into public.salary_advances (store_id, staff_id, amount, reason, request_date, status, reviewed_by, reviewed_at) values
    (v_store, ids[1], 500000,  'Đóng học phí', v_today - 12, 'approved', v_mgr, now()),
    (v_store, ids[4], 1000000, 'Sửa xe máy',   v_today,      'pending',  null,  null);
  insert into public.salary_holds (store_id, staff_id, amount, reason, held_on, due_on, released_on, created_by) values
    (v_store, ids[6], 300000, 'Giữ 10% lương thử việc (nhân viên mới)', v_today - 30, v_today + 30, null, v_mgr),
    (v_store, ids[1], 300000, 'Giữ lương thử việc 2 tháng đầu',         v_today - 70, v_today - 5,  v_today - 5, v_mgr),
    (v_store, ids[1], 150000, 'Giữ đến khi nộp đủ hồ sơ bảo hiểm',      v_today - 8,  v_today + 25, null, v_mgr);

  -- đăng ký lịch tuần sau
  v_mon := date_trunc('week', v_today)::date + 7;
  insert into public.shift_registrations (id, store_id, staff_id, week_start, note) values
    ('33333333-3333-4333-8333-000000000001', v_store, ids[3], v_mon, 'Thứ 7 em đi học'),
    ('33333333-3333-4333-8333-000000000002', v_store, ids[5], v_mon, '');
  insert into public.registration_slots (registration_id, work_date, shift_id)
  select '33333333-3333-4333-8333-000000000001', v_mon + x.o, s.id
    from (values (0,'S'),(2,'C'),(4,'T')) x(o, c) join public.shift_templates s on s.store_id = v_store and s.code = x.c;
  insert into public.registration_slots (registration_id, work_date, shift_id)
  select '33333333-3333-4333-8333-000000000002', v_mon + x.o, s.id
    from (values (1,'T'),(3,'T'),(5,'S'),(6,'C')) x(o, c) join public.shift_templates s on s.store_id = v_store and s.code = x.c;

  -- kỳ lương cũ đã trả
  insert into public.pay_periods (store_id, start_date, end_date, status, closed_at, paid_at)
  select v_store, p.start_date, p.end_date, 'paid', now(), now()
    from app.period_for(v_store, (v_today - interval '2 months')::date) p;

  -- bảng tin
  insert into public.posts (store_id, author_id, title, body, pinned, created_at) values
    (v_store, v_mgr, 'Lịch chốt công và trả lương',
     E'Kỳ lương tính từ ngày 26 tháng trước đến ngày 25 tháng này, lương trả vào ngày 5.\nMọi người xem lại Phiếu lương và gửi yêu cầu bổ sung công trước ngày 27 nhé.', true, now() - interval '50 hours'),
    (v_store, v_mgr, 'Hội sách cuối năm',
     'Từ 15/12 cửa hàng mở thêm quầy sách giảm giá ở sảnh. Cần thêm 2 bạn ca tối, ai muốn làm thì vào Đăng ký lịch làm việc.', false, now() - interval '20 hours'),
    (v_store, v_mgr, 'Nhắc đồng phục', 'Đeo bảng tên khi vào ca. Thứ 2 và thứ 6 mặc áo đồng phục đỏ.', false, now() - interval '120 hours');

  -- tin nhắn
  insert into public.messages (store_id, thread_staff_id, sender_id, body, created_at) values
    (v_store, null,   v_mgr,  'Tối thứ 7 có đợt sách thiếu nhi mới về, ca tối nhờ các bạn phụ xếp kệ nhé.', now() - interval '6 hours'),
    (v_store, null,   ids[2], 'Dạ em nhận ạ.', now() - interval '5.5 hours'),
    (v_store, null,   ids[5], 'Em ở lại thêm 30 phút được chị.', now() - interval '5 hours'),
    (v_store, ids[1], v_mgr,  'Linh ơi, thứ 3 tuần sau em đổi sang ca sáng được không?', now() - interval '3 hours'),
    (v_store, ids[1], ids[1], 'Dạ được chị, em gửi yêu cầu đổi ca luôn nha.', now() - interval '2.6 hours');
end $$;

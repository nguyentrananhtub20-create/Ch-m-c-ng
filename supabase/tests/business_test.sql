-- =====================================================================
-- Kiểm thử phân quyền & nghiệp vụ. Chạy sau migrations + seed:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/business_test.sql
-- Toàn bộ chạy trong một transaction và ROLLBACK ở cuối, không để lại dữ liệu.
-- =====================================================================
\set QUIET on
begin;

create temp table ids as select
  '22222222-2222-4222-8222-000000000000'::uuid as mgr,
  '22222222-2222-4222-8222-000000000001'::uuid as linh,
  '22222222-2222-4222-8222-000000000002'::uuid as khang;
grant select on ids to authenticated;

-- Ca thử nghiệm phủ cả ngày để kiểm thử không phụ thuộc giờ chạy
insert into public.shift_templates (store_id, code, name, start_time, end_time, sort)
values ('11111111-1111-4111-8111-111111111111', 'X', 'Ca thử', '00:00', '23:59:59', 0);
insert into public.shift_assignments (store_id, work_date, shift_id, staff_id)
select '11111111-1111-4111-8111-111111111111', (now() at time zone 'Asia/Ho_Chi_Minh')::date, id, (select linh from ids)
  from public.shift_templates where code = 'X';
update public.stores set raise_hours = 10, raise_max_late = 1000;

-- ===== Nhân viên Linh =====
select set_config('request.jwt.claim.sub', (select linh::text from ids), true);
set local role authenticated;

do $$ begin
  assert (select count(distinct staff_id) from public.attendance) = 1, 'nhân viên chỉ thấy công của mình';
  assert (select count(*) from public.salary_advances where staff_id <> (select linh from ids)) = 0, 'không thấy tạm ứng người khác';
  assert (select count(*) from public.messages where thread_staff_id is not null and thread_staff_id <> (select linh from ids)) = 0,
         'không đọc được chat riêng của người khác';
  assert (select count(*) from public.profiles) = 7, 'thấy danh sách đồng nghiệp';
  assert (select count(*) from public.shift_assignments) > 100, 'thấy lịch làm việc chung';
  raise notice 'OK  RLS nhân viên';
end $$;

do $$ begin
  insert into public.shift_assignments (store_id, work_date, shift_id, staff_id)
  select store_id, current_date + 3, shift_id, staff_id from public.shift_assignments limit 1;
  raise exception 'FAIL nhân viên tự xếp ca được';
exception when insufficient_privilege or check_violation then raise notice 'OK  nhân viên không tự xếp ca';
end $$;

do $$ begin
  update public.profiles set hourly_rate = 99000 where id = (select linh from ids);
  if found then raise exception 'FAIL nhân viên tự sửa đơn giá được'; end if;
  raise notice 'OK  nhân viên không tự sửa đơn giá';
exception when insufficient_privilege then raise notice 'OK  nhân viên không tự sửa đơn giá';
end $$;

do $$ begin
  perform public.get_payslip((select khang from ids));
  raise exception 'FAIL xem được phiếu lương người khác';
exception when insufficient_privilege then raise notice 'OK  không xem phiếu lương người khác';
end $$;

do $$ declare r public.attendance; rate0 int; rate1 int; begin
  select hourly_rate into rate0 from public.profiles where id = (select linh from ids);
  r := public.clock_in('Wi-Fi cửa hàng');
  assert r.check_out is null and r.method = 'Wi-Fi cửa hàng', 'vào ca';
  begin perform public.clock_in(); raise exception 'FAIL vào ca hai lần';
  exception when unique_violation then null; end;
  update public.attendance set check_in = now() - interval '2 hours' where id = r.id;  -- không có quyền: bị RLS chặn
  r := public.clock_out();
  assert r.check_out is not null, 'kết thúc ca';
  select hourly_rate into rate1 from public.profiles where id = (select linh from ids);
  assert rate1 = rate0 + 1000, format('tự động tăng lương sau khi đủ giờ (%s -> %s)', rate0, rate1);
  assert exists (select 1 from public.raise_history where staff_id = (select linh from ids) and is_auto and to_rate = rate1),
         'ghi lịch sử tăng lương tự động';
  raise notice 'OK  chấm công vào/ra + tự động tăng lương % -> %', rate0, rate1;
end $$;

do $$ declare a public.salary_advances; begin
  begin perform public.request_advance(5000000, 'quá hạn mức'); raise exception 'FAIL vượt hạn mức';
  exception when invalid_parameter_value then null; end;
  a := public.request_advance(400000, 'mua sách');
  assert a.status = 'pending', 'đơn tạm ứng chờ duyệt';
  raise notice 'OK  tạm ứng trong hạn mức, chặn vượt hạn mức';
end $$;

do $$ declare g public.shift_registrations; w date := date_trunc('week', now() at time zone 'Asia/Ho_Chi_Minh')::date + 14; begin
  g := public.submit_registration(w, jsonb_build_array(jsonb_build_object('date', w, 'shift', 'S'),
                                                       jsonb_build_object('date', w + 1, 'shift', 'T')), 'test');
  assert (select count(*) from public.registration_slots where registration_id = g.id) = 2, 'lưu 2 ca đăng ký';
  begin perform public.review_registration(g.id, true); raise exception 'FAIL nhân viên tự duyệt';
  exception when insufficient_privilege then null; end;
  raise notice 'OK  đăng ký lịch, không tự duyệt được';
end $$;

do $$ begin
  insert into public.messages (store_id, thread_staff_id, sender_id, body)
  values ('11111111-1111-4111-8111-111111111111', (select khang from ids), (select linh from ids), 'hi');
  raise exception 'FAIL nhắn vào chat riêng của người khác';
exception when insufficient_privilege or check_violation then raise notice 'OK  không nhắn vào chat riêng người khác';
end $$;

-- ===== Quản lý =====
reset role;
select set_config('request.jwt.claim.sub', (select mgr::text from ids), true);
set local role authenticated;

do $$ declare g uuid; n int; s jsonb; begin
  assert (select count(distinct staff_id) from public.attendance) = 6, 'quản lý thấy công cả cửa hàng';
  select id into g from public.shift_registrations where note = 'test';
  perform public.review_registration(g, true);
  select count(*) into n from public.shift_assignments a join public.shift_registrations r on r.staff_id = a.staff_id
   where r.id = g and a.work_date between r.week_start and r.week_start + 6;
  assert n >= 2, 'duyệt đăng ký thì xếp vào lịch';
  perform public.review_advance((select id from public.salary_advances where reason = 'mua sách'), true);
  s := public.get_payslip((select linh from ids));
  assert (s->>'advances')::int >= 400000, 'tạm ứng đã duyệt trừ vào phiếu lương';
  assert (s->>'net')::numeric = (s->>'gross')::numeric - (s->>'advances')::numeric - (s->>'holds')::numeric + (s->>'released')::numeric,
         'công thức thực nhận';
  update public.profiles set hourly_rate = hourly_rate + 500 where id = (select khang from ids);
  assert exists (select 1 from public.raise_history where staff_id = (select khang from ids) and not is_auto), 'ghi lịch sử chỉnh tay';
  raise notice 'OK  quản lý: duyệt đăng ký, duyệt tạm ứng, phiếu lương, chỉnh đơn giá (thực nhận = %)', s->>'net';
end $$;

do $$ begin
  perform public.set_period_status('2000-01-26', 'paid');
  raise exception 'FAIL đánh dấu trả khi chưa chốt';
exception when invalid_parameter_value then raise notice 'OK  phải chốt kỳ trước khi trả';
end $$;

-- ===== Khách chưa đăng nhập =====
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role anon;
do $$ begin
  perform 1 from public.profiles limit 1;
  raise exception 'FAIL khách đọc được dữ liệu';
exception when insufficient_privilege then raise notice 'OK  khách không đọc được gì';
end $$;

-- ===== Đăng ký tài khoản bằng mã cửa hàng =====
reset role;
do $$ begin
  insert into auth.users (id, email, raw_user_meta_data) values (gen_random_uuid(), 'x@test.vn', '{"join_code":"SAI","full_name":"X"}');
  raise exception 'FAIL đăng ký với mã sai';
exception when invalid_parameter_value then raise notice 'OK  chặn đăng ký sai mã cửa hàng';
end $$;
do $$ declare u uuid := gen_random_uuid(); begin
  insert into auth.users (id, email, raw_user_meta_data) values (u, 'moi@test.vn', '{"join_code":"minhtu2026","full_name":"Bạn Mới"}');
  assert (select role from public.profiles where id = u) = 'staff', 'tạo hồ sơ nhân viên';
  raise notice 'OK  đăng ký bằng mã cửa hàng tạo hồ sơ nhân viên';
end $$;

rollback;
\echo 'Tất cả kiểm thử đã chạy xong'

-- =====================================================================
-- 03. Nghiệp vụ: chấm công, kỳ lương, phiếu lương, tạm ứng, lương giữ,
--     đăng ký ca, duyệt yêu cầu, tự động tăng lương
-- Mọi RPC dùng giờ của server (không tin giờ của điện thoại).
-- =====================================================================

-- ---------- Tiện ích ----------
create or replace function app.me() returns public.profiles
language plpgsql stable security definer set search_path = '' as $$
declare p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid() and active;
  if not found then raise exception 'Bạn chưa đăng nhập hoặc tài khoản đã bị khoá' using errcode = '42501'; end if;
  return p;
end $$;

create or replace function app.require_manager() returns public.profiles
language plpgsql stable security definer set search_path = '' as $$
declare p public.profiles := app.me();
begin
  if p.role <> 'manager' then raise exception 'Chỉ quản lý mới được thực hiện thao tác này' using errcode = '42501'; end if;
  return p;
end $$;

create or replace function app.local_now(p_store uuid) returns timestamp
language sql stable security definer set search_path = '' as $$
  select now() at time zone (select timezone from public.stores where id = p_store)
$$;

-- Kỳ lương chứa một ngày: từ ngày pay_start_day đến ngày trước đó của tháng sau
create or replace function app.period_for(p_store uuid, p_day date, out start_date date, out end_date date)
language plpgsql stable security definer set search_path = '' as $$
declare d int; m date;
begin
  select pay_start_day into d from public.stores where id = p_store;
  m := date_trunc('month', p_day)::date;
  start_date := m + (d - 1);
  if extract(day from p_day) < d then start_date := (m - interval '1 month')::date + (d - 1); end if;
  end_date := (start_date + interval '1 month')::date - 1;
end $$;

-- Đơn giá đang áp dụng tại một ngày (dựa vào lịch sử tăng lương)
create or replace function app.rate_at(p_staff uuid, p_day date) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select from_rate from public.raise_history
      where staff_id = p_staff and effective_on > p_day
      order by effective_on asc, created_at asc limit 1),
    (select hourly_rate from public.profiles where id = p_staff))
$$;

-- ---------- Chấm công ----------
create or replace function public.clock_in(p_method text default 'QR tại quầy')
returns public.attendance
language plpgsql security definer set search_path = '' as $$
declare
  me public.profiles := app.me();
  st public.stores;
  nowl timestamp;
  today date;
  sh public.shift_templates;
  rec public.attendance;
  v_late int;
begin
  if p_method not in ('QR tại quầy', 'Wi-Fi cửa hàng') then
    raise exception 'Cách chấm công không hợp lệ' using errcode = '22023';
  end if;
  if exists (select 1 from public.attendance where staff_id = me.id and check_out is null) then
    raise exception 'Bạn đang trong ca, hãy kết thúc ca trước' using errcode = '23505';
  end if;
  select * into st from public.stores where id = me.store_id;
  nowl := app.local_now(st.id);
  today := nowl::date;

  select s.* into sh
    from public.shift_assignments a
    join public.shift_templates s on s.id = a.shift_id
   where a.staff_id = me.id and a.work_date = today
     and s.end_time > nowl::time
     and not exists (select 1 from public.attendance x
                      where x.staff_id = me.id and x.work_date = today and x.shift_id = s.id)
   order by s.start_time limit 1;
  if not found then
    raise exception 'Hôm nay bạn không còn ca nào để chấm công' using errcode = 'P0002';
  end if;
  if nowl < today + sh.start_time - interval '60 minutes' then
    raise exception 'Chưa tới giờ vào %, sớm nhất là %', sh.name,
      to_char(sh.start_time - interval '60 minutes', 'HH24:MI') using errcode = '22023';
  end if;

  v_late := greatest(0, floor(extract(epoch from (nowl - (today + sh.start_time))) / 60)::int - st.grace_minutes);
  insert into public.attendance (store_id, staff_id, work_date, shift_id, check_in, method, late_minutes)
  values (st.id, me.id, today, sh.id, now(), p_method, v_late)
  returning * into rec;
  return rec;
end $$;

create or replace function public.clock_out()
returns public.attendance
language plpgsql security definer set search_path = '' as $$
declare me public.profiles := app.me(); rec public.attendance;
begin
  update public.attendance set check_out = now()
   where staff_id = me.id and check_out is null
  returning * into rec;
  if not found then raise exception 'Bạn chưa vào ca' using errcode = 'P0002'; end if;
  return rec;
end $$;

-- ---------- Tự động tăng lương ----------
create or replace function app.apply_auto_raise(p_staff uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  p public.profiles; st public.stores;
  v_hours numeric; v_late int; v_to int; v_today date;
begin
  select * into p from public.profiles where id = p_staff and active and role = 'staff';
  if not found then return false; end if;
  select * into st from public.stores where id = p.store_id;
  if p.hourly_rate >= st.raise_max_rate or st.raise_step = 0 then return false; end if;

  select coalesce(sum(extract(epoch from (check_out - check_in)) / 3600), 0),
         count(*) filter (where late_minutes > 0)
    into v_hours, v_late
    from public.attendance
   where staff_id = p.id and check_out is not null and work_date >= p.raise_cycle_start;

  if v_hours < st.raise_hours or v_late > st.raise_max_late then return false; end if;

  v_to := least(st.raise_max_rate, p.hourly_rate + st.raise_step);
  v_today := app.local_now(st.id)::date;
  perform set_config('app.auto_raise', 'on', true);
  update public.profiles set hourly_rate = v_to, raise_cycle_start = v_today where id = p.id;
  perform set_config('app.auto_raise', 'off', true);
  insert into public.raise_history (store_id, staff_id, from_rate, to_rate, effective_on, reason, is_auto)
  values (st.id, p.id, p.hourly_rate, v_to, v_today,
          format('Đủ %s giờ công, đi muộn %s lần', round(st.raise_hours), v_late), true);
  return true;
end $$;

-- Kiểm tra mỗi khi một ca được kết thúc
create or replace function app.on_attendance_closed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.check_out is not null and old.check_out is null then
    perform app.apply_auto_raise(new.staff_id);
  end if;
  return new;
end $$;
create trigger attendance_auto_raise
  after update of check_out on public.attendance
  for each row execute function app.on_attendance_closed();

-- Quản lý chạy lại cho cả cửa hàng (ví dụ sau khi hạ ngưỡng giờ công)
create or replace function public.run_auto_raises() returns int
language plpgsql security definer set search_path = '' as $$
declare me public.profiles := app.require_manager(); n int := 0; r record;
begin
  for r in select id from public.profiles where store_id = me.store_id and role = 'staff' and active loop
    if app.apply_auto_raise(r.id) then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- ---------- Phiếu lương ----------
create or replace function public.get_payslip(p_staff uuid default null, p_day date default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  me public.profiles := app.me();
  who public.profiles;
  per record;
  v_status text;
  r jsonb;
begin
  select * into who from public.profiles where id = coalesce(p_staff, me.id);
  if not found or who.store_id <> me.store_id or (me.role <> 'manager' and who.id <> me.id) then
    raise exception 'Không có quyền xem phiếu lương này' using errcode = '42501';
  end if;
  select * into per from app.period_for(who.store_id, coalesce(p_day, app.local_now(who.store_id)::date));
  select status::text into v_status from public.pay_periods where store_id = who.store_id and start_date = per.start_date;

  with a as (
    select extract(epoch from (check_out - check_in)) / 3600 as h, app.rate_at(who.id, work_date) as rate, late_minutes
      from public.attendance
     where staff_id = who.id and check_out is not null
       and work_date between per.start_date and per.end_date)
  select jsonb_build_object(
    'staff_id', who.id, 'full_name', who.full_name,
    'start_date', per.start_date, 'end_date', per.end_date,
    'status', coalesce(v_status, case when per.end_date < app.local_now(who.store_id)::date then 'pending_close' else 'open' end),
    'shifts', (select count(*) from a),
    'hours', round((select coalesce(sum(h), 0) from a)::numeric, 2),
    'late_count', (select count(*) from a where late_minutes > 0),
    'gross', round((select coalesce(sum(h * rate), 0) from a)::numeric),
    'advances', (select coalesce(sum(amount), 0) from public.salary_advances
                  where staff_id = who.id and status = 'approved'
                    and request_date between per.start_date and per.end_date),
    'holds', (select coalesce(sum(amount), 0) from public.salary_holds
               where staff_id = who.id and held_on between per.start_date and per.end_date),
    'released', (select coalesce(sum(amount), 0) from public.salary_holds
                  where staff_id = who.id and released_on between per.start_date and per.end_date))
  into r;
  return r || jsonb_build_object('net',
    (r->>'gross')::numeric - (r->>'advances')::numeric - (r->>'holds')::numeric + (r->>'released')::numeric);
end $$;

-- Chốt kỳ / đánh dấu đã trả
create or replace function public.set_period_status(p_start date, p_status public.period_status)
returns public.pay_periods
language plpgsql security definer set search_path = '' as $$
declare me public.profiles := app.require_manager(); per record; rec public.pay_periods;
begin
  select * into per from app.period_for(me.store_id, p_start);
  if per.start_date <> p_start then raise exception 'Ngày bắt đầu kỳ không hợp lệ' using errcode = '22023'; end if;
  if p_status = 'paid' and not exists (select 1 from public.pay_periods
       where store_id = me.store_id and start_date = p_start and status = 'closed') then
    raise exception 'Phải chốt kỳ trước khi đánh dấu đã trả' using errcode = '22023';
  end if;
  insert into public.pay_periods (store_id, start_date, end_date, status, closed_at, paid_at)
  values (me.store_id, per.start_date, per.end_date, p_status, now(), case when p_status = 'paid' then now() end)
  on conflict (store_id, start_date) do update
    set status = excluded.status,
        paid_at = case when excluded.status = 'paid' then now() else public.pay_periods.paid_at end
  returning * into rec;
  return rec;
end $$;

-- ---------- Tạm ứng ----------
create or replace function public.request_advance(p_amount bigint, p_reason text default '')
returns public.salary_advances
language plpgsql security definer set search_path = '' as $$
declare me public.profiles := app.me(); st public.stores; per record; used bigint; rec public.salary_advances; today date;
begin
  select * into st from public.stores where id = me.store_id;
  today := app.local_now(st.id)::date;
  select * into per from app.period_for(st.id, today);
  if exists (select 1 from public.pay_periods where store_id = st.id and start_date = per.start_date) then
    raise exception 'Kỳ lương này đã chốt, không thể tạm ứng thêm' using errcode = '22023';
  end if;
  select coalesce(sum(amount), 0) into used from public.salary_advances
   where staff_id = me.id and status <> 'rejected' and request_date between per.start_date and per.end_date;
  if p_amount is null or p_amount <= 0 or used + p_amount > st.advance_limit then
    raise exception 'Bạn chỉ có thể ứng thêm tối đa % đ trong kỳ này',
      to_char(greatest(0, st.advance_limit - used), 'FM999G999G999') using errcode = '22023';
  end if;
  insert into public.salary_advances (store_id, staff_id, amount, reason, request_date)
  values (st.id, me.id, p_amount, coalesce(trim(p_reason), ''), today)
  returning * into rec;
  return rec;
end $$;

create or replace function public.review_advance(p_id uuid, p_approve boolean)
returns public.salary_advances
language plpgsql security definer set search_path = '' as $$
declare me public.profiles := app.require_manager(); rec public.salary_advances;
begin
  update public.salary_advances
     set status = case when p_approve then 'approved'::public.review_status else 'rejected' end,
         reviewed_by = me.id, reviewed_at = now()
   where id = p_id and store_id = me.store_id and status = 'pending'
  returning * into rec;
  if not found then raise exception 'Không tìm thấy đơn đang chờ duyệt' using errcode = 'P0002'; end if;
  return rec;
end $$;

-- ---------- Yêu cầu ----------
create or replace function public.review_request(p_id uuid, p_approve boolean)
returns public.requests
language plpgsql security definer set search_path = '' as $$
declare me public.profiles := app.require_manager(); rec public.requests;
begin
  update public.requests
     set status = case when p_approve then 'approved'::public.review_status else 'rejected' end,
         reviewed_by = me.id, reviewed_at = now()
   where id = p_id and store_id = me.store_id and status = 'pending'
  returning * into rec;
  if not found then raise exception 'Không tìm thấy yêu cầu đang chờ duyệt' using errcode = 'P0002'; end if;
  return rec;
end $$;

-- ---------- Lương giữ ----------
create or replace function public.release_hold(p_id uuid)
returns public.salary_holds
language plpgsql security definer set search_path = '' as $$
declare me public.profiles := app.require_manager(); rec public.salary_holds;
begin
  update public.salary_holds set released_on = app.local_now(me.store_id)::date
   where id = p_id and store_id = me.store_id and released_on is null
  returning * into rec;
  if not found then raise exception 'Khoản giữ không tồn tại hoặc đã trả lại' using errcode = 'P0002'; end if;
  return rec;
end $$;

-- ---------- Đăng ký lịch làm việc ----------
-- p_slots: [{"date":"2026-11-30","shift":"S"}, ...]
create or replace function public.submit_registration(p_week_start date, p_slots jsonb, p_note text default '')
returns public.shift_registrations
language plpgsql security definer set search_path = '' as $$
declare me public.profiles := app.me(); reg public.shift_registrations; today date; n int;
begin
  today := app.local_now(me.store_id)::date;
  if extract(isodow from p_week_start) <> 1 or p_week_start <= today then
    raise exception 'Chỉ đăng ký được cho các tuần sắp tới (bắt đầu từ thứ 2)' using errcode = '22023';
  end if;
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then
    raise exception 'Hãy chọn ít nhất một ca' using errcode = '22023';
  end if;
  select count(*) into n from jsonb_array_elements(p_slots) e
   where (e->>'date')::date not between p_week_start and p_week_start + 6
      or not exists (select 1 from public.shift_templates s where s.store_id = me.store_id and s.code = e->>'shift');
  if n > 0 then raise exception 'Có ca không hợp lệ trong đăng ký' using errcode = '22023'; end if;

  select * into reg from public.shift_registrations where staff_id = me.id and week_start = p_week_start;
  if found and reg.status <> 'pending' then
    raise exception 'Đăng ký tuần này đã được xử lý, không sửa được nữa' using errcode = '22023';
  end if;
  insert into public.shift_registrations (store_id, staff_id, week_start, note)
  values (me.store_id, me.id, p_week_start, coalesce(trim(p_note), ''))
  on conflict (staff_id, week_start) do update set note = excluded.note, updated_at = now()
  returning * into reg;
  delete from public.registration_slots where registration_id = reg.id;
  insert into public.registration_slots (registration_id, work_date, shift_id)
  select distinct reg.id, (e->>'date')::date, s.id
    from jsonb_array_elements(p_slots) e
    join public.shift_templates s on s.store_id = me.store_id and s.code = e->>'shift';
  return reg;
end $$;

create or replace function public.review_registration(p_id uuid, p_approve boolean)
returns public.shift_registrations
language plpgsql security definer set search_path = '' as $$
declare me public.profiles := app.require_manager(); rec public.shift_registrations;
begin
  update public.shift_registrations
     set status = case when p_approve then 'approved'::public.review_status else 'rejected' end,
         reviewed_by = me.id, reviewed_at = now(), updated_at = now()
   where id = p_id and store_id = me.store_id and status = 'pending'
  returning * into rec;
  if not found then raise exception 'Không tìm thấy đăng ký đang chờ duyệt' using errcode = 'P0002'; end if;
  if p_approve then
    insert into public.shift_assignments (store_id, work_date, shift_id, staff_id)
    select rec.store_id, work_date, shift_id, rec.staff_id
      from public.registration_slots where registration_id = rec.id
    on conflict do nothing;
  end if;
  return rec;
end $$;

-- ---------- Quyền gọi hàm ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function
  public.clock_in(text), public.clock_out(), public.run_auto_raises(),
  public.get_payslip(uuid, date), public.set_period_status(date, public.period_status),
  public.request_advance(bigint, text), public.review_advance(uuid, boolean),
  public.review_request(uuid, boolean), public.release_hold(uuid),
  public.submit_registration(date, jsonb, text), public.review_registration(uuid, boolean)
to authenticated;
grant execute on function app.me(), app.require_manager(), app.local_now(uuid),
  app.period_for(uuid, date), app.rate_at(uuid, date), app.uid(), app.store_id(),
  app.is_manager(), app.in_my_store(uuid)
to authenticated;

-- ---------- Realtime cho tin nhắn, bảng tin, lịch, đơn ----------
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.messages, public.posts,
      public.shift_assignments, public.requests, public.salary_advances, public.shift_registrations;
  end if;
end $$;

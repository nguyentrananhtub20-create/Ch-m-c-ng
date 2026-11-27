-- =====================================================================
-- 02. Bảo mật: hàm hỗ trợ, đăng ký tài khoản, Row Level Security
-- Nguyên tắc: mỗi người chỉ thấy dữ liệu cửa hàng của mình;
-- nhân viên chỉ thấy dữ liệu cá nhân; thao tác nhạy cảm đi qua RPC.
-- =====================================================================

-- Schema riêng, không lộ qua API REST
create schema if not exists app;
grant usage on schema app to authenticated;

create or replace function app.uid() returns uuid
language sql stable as $$ select auth.uid() $$;

create or replace function app.store_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select store_id from public.profiles where id = auth.uid() and active
$$;

create or replace function app.is_manager() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'manager' and active)
$$;

create or replace function app.in_my_store(p_profile uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
                 where p.id = p_profile and p.store_id = app.store_id())
$$;

grant execute on function app.uid(), app.store_id(), app.is_manager(), app.in_my_store(uuid) to authenticated;

-- ---------- Tự tạo hồ sơ khi nhân viên đăng ký bằng mã cửa hàng ----------
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_store uuid;
begin
  -- tài khoản do seed/admin tạo sẵn hồ sơ thì bỏ qua
  if new.raw_user_meta_data ? 'skip_profile' then return new; end if;
  select id into v_store from public.stores
   where upper(join_code) = upper(coalesce(new.raw_user_meta_data->>'join_code', ''));
  if v_store is null then
    raise exception 'Mã cửa hàng không đúng' using errcode = '22023';
  end if;
  insert into public.profiles (id, store_id, full_name, phone, role)
  values (new.id, v_store,
          coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), split_part(new.email, '@', 1)),
          nullif(trim(new.raw_user_meta_data->>'phone'), ''),
          'staff');
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();

-- ---------- Ghi lịch sử khi quản lý chỉnh đơn giá bằng tay ----------
create or replace function app.log_manual_rate_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.hourly_rate <> old.hourly_rate
     and coalesce(current_setting('app.auto_raise', true), '') <> 'on' then
    insert into public.raise_history (store_id, staff_id, from_rate, to_rate, effective_on, reason, is_auto)
    values (new.store_id, new.id, old.hourly_rate, new.hourly_rate,
            (now() at time zone 'Asia/Ho_Chi_Minh')::date, 'Quản lý điều chỉnh đơn giá', false);
  end if;
  return new;
end $$;
create trigger profiles_rate_change
  after update of hourly_rate on public.profiles
  for each row execute function app.log_manual_rate_change();

-- ---------- Quyền mức bảng / cột ----------
revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;
grant select on all tables in schema public to authenticated;

grant update (name, manager_title, grace_minutes, pay_start_day, pay_out_day, advance_limit,
              raise_hours, raise_step, raise_max_rate, raise_max_late)
  on public.stores to authenticated;
grant update (position, phone, hourly_rate, raise_cycle_start, active) on public.profiles to authenticated;
grant insert, update, delete on public.shift_templates to authenticated;
grant insert, delete on public.shift_assignments to authenticated;
grant update (check_in, check_out, method, late_minutes) on public.attendance to authenticated;
grant insert on public.requests to authenticated;
grant insert on public.salary_holds to authenticated;
grant insert, update (title, body, pinned), delete on public.posts to authenticated;
grant insert on public.post_reads to authenticated;
grant insert on public.messages to authenticated;

-- ---------- Bật RLS cho mọi bảng ----------
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;

-- stores
create policy "xem cửa hàng của mình" on public.stores for select to authenticated
  using (id = (select app.store_id()));
create policy "quản lý sửa cấu hình" on public.stores for update to authenticated
  using (id = (select app.store_id()) and (select app.is_manager()))
  with check (id = (select app.store_id()));

-- profiles
create policy "xem đồng nghiệp cùng cửa hàng" on public.profiles for select to authenticated
  using (store_id = (select app.store_id()) or id = (select app.uid()));
create policy "quản lý sửa hồ sơ nhân viên" on public.profiles for update to authenticated
  using (store_id = (select app.store_id()) and (select app.is_manager()))
  with check (store_id = (select app.store_id()));

-- shift_templates
create policy "xem ca mẫu" on public.shift_templates for select to authenticated
  using (store_id = (select app.store_id()));
create policy "quản lý sửa ca mẫu" on public.shift_templates for all to authenticated
  using (store_id = (select app.store_id()) and (select app.is_manager()))
  with check (store_id = (select app.store_id()) and (select app.is_manager()));

-- shift_assignments: ai cũng xem lịch chung, chỉ quản lý xếp ca
create policy "xem lịch chung" on public.shift_assignments for select to authenticated
  using (store_id = (select app.store_id()));
create policy "quản lý xếp ca" on public.shift_assignments for insert to authenticated
  with check (store_id = (select app.store_id()) and (select app.is_manager())
              and app.in_my_store(staff_id)
              and exists (select 1 from public.shift_templates s
                          where s.id = shift_assignments.shift_id and s.store_id = shift_assignments.store_id));
create policy "quản lý bỏ ca" on public.shift_assignments for delete to authenticated
  using (store_id = (select app.store_id()) and (select app.is_manager()));

-- attendance: ghi qua RPC clock_in/clock_out; quản lý được sửa để điều chỉnh công
create policy "xem chấm công" on public.attendance for select to authenticated
  using (staff_id = (select app.uid())
         or (store_id = (select app.store_id()) and (select app.is_manager())));
create policy "quản lý điều chỉnh công" on public.attendance for update to authenticated
  using (store_id = (select app.store_id()) and (select app.is_manager()))
  with check (store_id = (select app.store_id()));

-- requests
create policy "xem yêu cầu" on public.requests for select to authenticated
  using (staff_id = (select app.uid())
         or (store_id = (select app.store_id()) and (select app.is_manager())));
create policy "nhân viên gửi yêu cầu" on public.requests for insert to authenticated
  with check (staff_id = (select app.uid()) and store_id = (select app.store_id())
              and status = 'pending' and reviewed_by is null and reviewed_at is null);

-- shift_registrations / slots (ghi qua RPC)
create policy "xem đăng ký ca" on public.shift_registrations for select to authenticated
  using (staff_id = (select app.uid())
         or (store_id = (select app.store_id()) and (select app.is_manager())));
create policy "xem ca đã đăng ký" on public.registration_slots for select to authenticated
  using (exists (select 1 from public.shift_registrations r where r.id = registration_id));

-- salary_advances (ghi qua RPC)
create policy "xem tạm ứng" on public.salary_advances for select to authenticated
  using (staff_id = (select app.uid())
         or (store_id = (select app.store_id()) and (select app.is_manager())));

-- salary_holds
create policy "xem lương giữ" on public.salary_holds for select to authenticated
  using (staff_id = (select app.uid())
         or (store_id = (select app.store_id()) and (select app.is_manager())));
create policy "quản lý giữ lương" on public.salary_holds for insert to authenticated
  with check (store_id = (select app.store_id()) and (select app.is_manager())
              and app.in_my_store(staff_id) and created_by = (select app.uid())
              and released_on is null);

-- raise_history
create policy "xem lịch sử tăng lương" on public.raise_history for select to authenticated
  using (staff_id = (select app.uid())
         or (store_id = (select app.store_id()) and (select app.is_manager())));

-- pay_periods
create policy "xem trạng thái kỳ lương" on public.pay_periods for select to authenticated
  using (store_id = (select app.store_id()));

-- posts
create policy "xem bảng tin" on public.posts for select to authenticated
  using (store_id = (select app.store_id()));
create policy "quản lý đăng tin" on public.posts for insert to authenticated
  with check (store_id = (select app.store_id()) and (select app.is_manager())
              and author_id = (select app.uid()));
create policy "quản lý sửa tin" on public.posts for update to authenticated
  using (store_id = (select app.store_id()) and (select app.is_manager()))
  with check (store_id = (select app.store_id()));
create policy "quản lý xoá tin" on public.posts for delete to authenticated
  using (store_id = (select app.store_id()) and (select app.is_manager()));

-- post_reads
create policy "xem lượt đọc" on public.post_reads for select to authenticated
  using (staff_id = (select app.uid())
         or ((select app.is_manager()) and app.in_my_store(staff_id)));
create policy "đánh dấu đã đọc" on public.post_reads for insert to authenticated
  with check (staff_id = (select app.uid())
              and exists (select 1 from public.posts p where p.id = post_id and p.store_id = (select app.store_id())));

-- messages
create policy "xem tin nhắn" on public.messages for select to authenticated
  using (store_id = (select app.store_id())
         and (thread_staff_id is null or thread_staff_id = (select app.uid()) or (select app.is_manager())));
create policy "gửi tin nhắn" on public.messages for insert to authenticated
  with check (sender_id = (select app.uid()) and store_id = (select app.store_id())
              and (thread_staff_id is null
                   or thread_staff_id = (select app.uid())
                   or ((select app.is_manager()) and app.in_my_store(thread_staff_id))));

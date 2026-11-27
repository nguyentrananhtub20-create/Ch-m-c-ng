-- =====================================================================
-- Minh Tú – Chấm công & xếp ca
-- 01. Schema: bảng, ràng buộc, chỉ mục
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Cửa hàng & cấu hình ----------
create table public.stores (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  join_code        text not null unique,               -- mã để nhân viên tự đăng ký
  timezone         text not null default 'Asia/Ho_Chi_Minh',
  manager_title    text not null default 'Quản lý',
  grace_minutes    int  not null default 5   check (grace_minutes between 0 and 60),
  pay_start_day    int  not null default 26  check (pay_start_day between 1 and 28),
  pay_out_day      int  not null default 5   check (pay_out_day between 1 and 28),
  advance_limit    bigint not null default 2000000 check (advance_limit >= 0),
  raise_hours      numeric(7,2) not null default 300 check (raise_hours >= 10),
  raise_step       int  not null default 1000 check (raise_step >= 0),
  raise_max_rate   int  not null default 30000 check (raise_max_rate >= 0),
  raise_max_late   int  not null default 5 check (raise_max_late >= 0),
  created_at       timestamptz not null default now()
);

-- ---------- Hồ sơ người dùng (1-1 với auth.users) ----------
create type public.user_role as enum ('manager', 'staff');

create table public.profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  store_id           uuid not null references public.stores(id) on delete cascade,
  full_name          text not null check (length(trim(full_name)) > 0),
  position           text not null default 'Nhân viên',
  phone              text,
  role               public.user_role not null default 'staff',
  hourly_rate        int not null default 23000 check (hourly_rate >= 0),
  raise_cycle_start  date not null default current_date,  -- mốc tính giờ công cho lần tăng lương kế tiếp
  active             boolean not null default true,
  created_at         timestamptz not null default now()
);
create index on public.profiles (store_id);

-- ---------- Ca mẫu (sáng/chiều/tối) ----------
create table public.shift_templates (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references public.stores(id) on delete cascade,
  code        text not null,                -- S / C / T
  name        text not null,
  start_time  time not null,
  end_time    time not null,
  capacity    int  not null default 3 check (capacity > 0),
  sort        int  not null default 0,
  unique (store_id, code),
  check (end_time > start_time)
);

-- ---------- Lịch làm việc chung ----------
create table public.shift_assignments (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references public.stores(id) on delete cascade,
  work_date   date not null,
  shift_id    uuid not null references public.shift_templates(id) on delete cascade,
  staff_id    uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (work_date, shift_id, staff_id)
);
create index on public.shift_assignments (store_id, work_date);
create index on public.shift_assignments (staff_id, work_date);

-- ---------- Chấm công ----------
create table public.attendance (
  id            uuid primary key default gen_random_uuid(),
  store_id      uuid not null references public.stores(id) on delete cascade,
  staff_id      uuid not null references public.profiles(id) on delete cascade,
  work_date     date not null,
  shift_id      uuid not null references public.shift_templates(id),
  check_in      timestamptz not null,
  check_out     timestamptz,
  method        text not null default 'QR tại quầy',
  late_minutes  int not null default 0,      -- số phút muộn vượt quá thời gian cho phép
  created_at    timestamptz not null default now(),
  unique (staff_id, work_date, shift_id),
  check (check_out is null or check_out >= check_in)
);
create index on public.attendance (store_id, work_date);
create index on public.attendance (staff_id, work_date);
-- tối đa 1 lượt đang mở cho mỗi nhân viên
create unique index attendance_one_open on public.attendance (staff_id) where check_out is null;

-- ---------- Trạng thái duyệt dùng chung ----------
create type public.review_status as enum ('pending', 'approved', 'rejected');

-- ---------- Yêu cầu (nghỉ phép, đổi ca, ...) ----------
create table public.requests (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null references public.stores(id) on delete cascade,
  staff_id     uuid not null references public.profiles(id) on delete cascade,
  type         text not null check (type in ('Nghỉ phép','Đổi ca','Đi muộn','Về sớm','Bổ sung công')),
  for_date     date not null,
  note         text not null default '',
  status       public.review_status not null default 'pending',
  reviewed_by  uuid references public.profiles(id),
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now()
);
create index on public.requests (store_id, status);

-- ---------- Đăng ký lịch làm việc ----------
create table public.shift_registrations (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null references public.stores(id) on delete cascade,
  staff_id     uuid not null references public.profiles(id) on delete cascade,
  week_start   date not null check (extract(isodow from week_start) = 1),
  note         text not null default '',
  status       public.review_status not null default 'pending',
  reviewed_by  uuid references public.profiles(id),
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (staff_id, week_start)
);
create table public.registration_slots (
  registration_id uuid not null references public.shift_registrations(id) on delete cascade,
  work_date       date not null,
  shift_id        uuid not null references public.shift_templates(id) on delete cascade,
  primary key (registration_id, work_date, shift_id)
);

-- ---------- Tạm ứng lương ----------
create table public.salary_advances (
  id            uuid primary key default gen_random_uuid(),
  store_id      uuid not null references public.stores(id) on delete cascade,
  staff_id      uuid not null references public.profiles(id) on delete cascade,
  amount        bigint not null check (amount > 0),
  reason        text not null default '',
  request_date  date not null,
  status        public.review_status not null default 'pending',
  reviewed_by   uuid references public.profiles(id),
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now()
);
create index on public.salary_advances (store_id, status);

-- ---------- Lương đang giữ ----------
create table public.salary_holds (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null references public.stores(id) on delete cascade,
  staff_id     uuid not null references public.profiles(id) on delete cascade,
  amount       bigint not null check (amount > 0),
  reason       text not null check (length(trim(reason)) > 0),
  held_on      date not null,
  due_on       date not null,
  released_on  date,
  created_by   uuid references public.profiles(id),
  created_at   timestamptz not null default now(),
  check (released_on is null or released_on >= held_on)
);
create index on public.salary_holds (staff_id);

-- ---------- Lịch sử tăng lương ----------
create table public.raise_history (
  id            uuid primary key default gen_random_uuid(),
  store_id      uuid not null references public.stores(id) on delete cascade,
  staff_id      uuid not null references public.profiles(id) on delete cascade,
  from_rate     int not null,
  to_rate       int not null,
  effective_on  date not null,
  reason        text not null,
  is_auto       boolean not null default true,
  created_at    timestamptz not null default now()
);
create index on public.raise_history (staff_id, effective_on);

-- ---------- Kỳ lương đã chốt / đã trả ----------
create type public.period_status as enum ('closed', 'paid');
create table public.pay_periods (
  store_id    uuid not null references public.stores(id) on delete cascade,
  start_date  date not null,
  end_date    date not null,
  status      public.period_status not null,
  closed_at   timestamptz,
  paid_at     timestamptz,
  primary key (store_id, start_date)
);

-- ---------- Bảng tin ----------
create table public.posts (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references public.stores(id) on delete cascade,
  author_id   uuid not null references public.profiles(id),
  title       text not null check (length(trim(title)) > 0),
  body        text not null default '',
  pinned      boolean not null default false,
  created_at  timestamptz not null default now()
);
create index on public.posts (store_id, created_at desc);
create table public.post_reads (
  post_id   uuid not null references public.posts(id) on delete cascade,
  staff_id  uuid not null references public.profiles(id) on delete cascade,
  read_at   timestamptz not null default now(),
  primary key (post_id, staff_id)
);

-- ---------- Tin nhắn ----------
-- thread_staff_id = null: nhóm "Cả cửa hàng"; khác null: chat riêng quản lý <-> nhân viên đó
create table public.messages (
  id               uuid primary key default gen_random_uuid(),
  store_id         uuid not null references public.stores(id) on delete cascade,
  thread_staff_id  uuid references public.profiles(id) on delete cascade,
  sender_id        uuid not null references public.profiles(id) on delete cascade,
  body             text not null check (length(trim(body)) between 1 and 2000),
  created_at       timestamptz not null default now()
);
create index on public.messages (store_id, thread_staff_id, created_at);

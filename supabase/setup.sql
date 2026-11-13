-- Atlas Free Inventory: database setup. Run once in the Supabase SQL Editor.
-- Everyone signs in with email + password; only emails in `members` can create an account.
-- Stock only changes through record_transaction(), which checks stock inside one database transaction.

-- ---------- tables ----------
create table public.members (
  email text primary key check (email = lower(email)),
  is_admin boolean not null default false,
  added_at timestamptz not null default now()
);

create table public.items (
  id bigint generated always as identity primary key,
  code text not null unique,
  name text not null check (length(trim(name)) > 0),
  location text not null default '',
  qty integer not null default 0 check (qty >= 0),
  deleted boolean not null default false,  -- deleted items stay so past check-outs still name them
  created_at timestamptz not null default now()
);

create table public.events (
  id bigint generated always as identity primary key,
  name text not null check (length(trim(name)) > 0),
  event_date date,
  status text not null default 'open' check (status in ('open', 'close_requested', 'closed')),
  close_requested_by text,
  created_at timestamptz not null default now()
);

create table public.event_requests (
  id bigint generated always as identity primary key,
  name text not null check (length(trim(name)) > 0),
  event_date date,
  requested_by text not null default lower(coalesce(auth.jwt() ->> 'email', '')),
  created_at timestamptz not null default now()
);

create table public.transactions (
  id bigint generated always as identity primary key,
  dir text not null check (dir in ('out', 'in')),
  type text not null check (type in ('general', 'event', 'donor', 'merch')),
  event_id bigint references public.events (id),
  donor text not null default '',
  user_email text not null,
  created_at timestamptz not null default now()
);

create table public.transaction_lines (
  id bigint generated always as identity primary key,
  transaction_id bigint not null references public.transactions (id) on delete cascade,
  item_id bigint not null references public.items (id),
  qty integer not null check (qty > 0),
  donor text not null default ''
);

-- ---------- who is asking ----------
create function public.my_email() returns text
language sql stable as $$ select lower(coalesce(auth.jwt() ->> 'email', '')) $$;

create function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where email = public.my_email())
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where email = public.my_email() and is_admin)
$$;

-- ---------- only team emails can create an account ----------
create function public.only_team_signups() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.members where email = lower(new.email)) then
    raise exception 'This email is not on the team';
  end if;
  return new;
end $$;

create trigger only_team_signups before insert on auth.users
for each row execute function public.only_team_signups();

-- ---------- the team always keeps one admin ----------
create function public.keep_one_admin() returns trigger
language plpgsql as $$
begin
  if (tg_op = 'DELETE' and old.is_admin) or (tg_op = 'UPDATE' and old.is_admin and not new.is_admin) then
    if not exists (select 1 from public.members where is_admin and email <> old.email) then
      raise exception 'The team needs at least one admin.';
    end if;
  end if;
  return coalesce(new, old);
end $$;

create trigger keep_one_admin before update or delete on public.members
for each row execute function public.keep_one_admin();

-- ---------- access rules ----------
alter table public.members enable row level security;
alter table public.items enable row level security;
alter table public.events enable row level security;
alter table public.event_requests enable row level security;
alter table public.transactions enable row level security;
alter table public.transaction_lines enable row level security;

create policy "team reads members" on public.members for select to authenticated using (public.is_member());
create policy "admins add members" on public.members for insert to authenticated with check (public.is_admin());
create policy "admins change members" on public.members for update to authenticated using (public.is_admin());
create policy "admins remove members" on public.members for delete to authenticated using (public.is_admin());

create policy "team reads items" on public.items for select to authenticated using (public.is_member());
create policy "admins add items" on public.items for insert to authenticated with check (public.is_admin());
create policy "admins change items" on public.items for update to authenticated using (public.is_admin());

create policy "team reads events" on public.events for select to authenticated using (public.is_member());
create policy "admins add events" on public.events for insert to authenticated with check (public.is_admin());
create policy "admins change events" on public.events for update to authenticated using (public.is_admin());

create policy "team reads requests" on public.event_requests for select to authenticated using (public.is_member());
create policy "team asks for events" on public.event_requests for insert to authenticated
  with check (public.is_member() and requested_by = public.my_email());
create policy "admins clear requests" on public.event_requests for delete to authenticated using (public.is_admin());

create policy "team reads activity" on public.transactions for select to authenticated using (public.is_member());
create policy "team reads activity lines" on public.transaction_lines for select to authenticated using (public.is_member());
-- No insert/update/delete rules on activity: it is only written by record_transaction() and never edited.

-- ---------- check-out / check-in ----------
-- p_lines: [{"item_id": 1, "qty": 2, "donor": ""}, ...]
create function public.record_transaction(p_dir text, p_type text, p_event_id bigint, p_donor text, p_lines jsonb)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_tx bigint;
  v_line jsonb;
  v_item public.items;
  v_qty integer;
begin
  if not public.is_member() then raise exception 'This email is not on the team'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Scan at least one item first.'; end if;
  if p_type = 'event' and not exists (select 1 from public.events where id = p_event_id and status <> 'closed') then
    raise exception 'That event is closed.';
  end if;

  insert into public.transactions (dir, type, event_id, donor, user_email)
  values (p_dir, p_type, case when p_type = 'event' then p_event_id end, coalesce(p_donor, ''), public.my_email())
  returning id into v_tx;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := (v_line ->> 'qty')::integer;
    select * into v_item from public.items where id = (v_line ->> 'item_id')::bigint and not deleted for update;
    if not found then raise exception 'An item in this list was deleted. Remove it and try again.'; end if;
    if p_dir = 'out' and v_item.qty < v_qty then
      raise exception 'Only % left in stock for %.', v_item.qty, v_item.name;
    end if;
    update public.items set qty = qty + (case when p_dir = 'out' then -v_qty else v_qty end) where id = v_item.id;
    insert into public.transaction_lines (transaction_id, item_id, qty, donor)
    values (v_tx, v_item.id, v_qty, coalesce(v_line ->> 'donor', ''));
  end loop;
  return v_tx;
end $$;

create function public.request_event_close(p_event_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'This email is not on the team'; end if;
  update public.events set status = 'close_requested', close_requested_by = public.my_email()
  where id = p_event_id and status = 'open';
end $$;

revoke execute on function public.record_transaction(text, text, bigint, text, jsonb) from public, anon;
revoke execute on function public.request_event_close(bigint) from public, anon;
grant execute on function public.record_transaction(text, text, bigint, text, jsonb) to authenticated;
grant execute on function public.request_event_close(bigint) to authenticated;

-- ---------- sample data (delete these items in Admin › Items when you add real ones) ----------
insert into public.items (code, name, location, qty) values
  ('AF-0001', 'Atlas Free T-shirt (M)', 'Storage closet, shelf A', 42),
  ('AF-0002', 'Atlas Free T-shirt (L)', 'Storage closet, shelf A', 35),
  ('AF-0003', 'Tote bag', 'Storage closet, shelf B', 60),
  ('AF-0004', 'Water bottle', 'Storage closet, shelf B', 24),
  ('AF-0005', 'Sticker pack', 'Front desk drawer', 150),
  ('AF-0006', 'Brochure (box of 100)', 'Office, cabinet 2', 8),
  ('AF-0007', 'Table cloth (blue)', 'Event bin 1', 3),
  ('AF-0008', 'Pull-up banner', 'Event bin 1', 2),
  ('AF-0009', 'Donor thank-you mug', 'Office, cabinet 1', 18),
  ('AF-0010', 'Framed print', 'Office, cabinet 1', 0);
insert into public.events (name) values ('Sample: Community 5K');

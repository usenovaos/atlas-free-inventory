-- Atlas Free Inventory: sizes, item photos and number-only item numbers. Run once in the Supabase SQL Editor.
-- Stock now lives per size in item_stock; an item without sizes has one row with size '' (one size).
-- items.qty stays as the item's total, kept in step by a trigger.

-- ---------- item numbers: AF-0003 becomes 3 (old printed labels still scan; the app ignores "AF-" and leading zeros) ----------
update public.items set code = regexp_replace(code, '^AF-0*(\d)', '\1') where code ~ '^AF-\d+$';

-- ---------- photos ----------
alter table public.items add column photo_path text not null default '';   -- a file in the item-photos bucket, '' = no photo

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('item-photos', 'item-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp']);
-- Private bucket: only signed-in team members can see photos, only admins can add or remove them.
create policy "team sees item photos" on storage.objects for select to authenticated
  using (bucket_id = 'item-photos' and public.is_member());
create policy "admins add item photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'item-photos' and public.is_admin());
create policy "admins change item photos" on storage.objects for update to authenticated
  using (bucket_id = 'item-photos' and public.is_admin());
create policy "admins remove item photos" on storage.objects for delete to authenticated
  using (bucket_id = 'item-photos' and public.is_admin());

-- ---------- stock per size ----------
create table public.item_stock (
  item_id bigint not null references public.items (id),
  size text not null default '',          -- '' = one size; otherwise XXS…XXXL or the admin's own size name
  qty integer not null default 0 check (qty >= 0),
  sort smallint not null default 0,
  primary key (item_id, size)
);
alter table public.item_stock enable row level security;
create policy "team reads stock" on public.item_stock for select to authenticated using (public.is_member());
-- No write rules: stock only changes through save_item(), record_transaction() and delete_transaction().

insert into public.item_stock (item_id, size, qty) select id, '', qty from public.items;

alter table public.transaction_lines add column size text not null default '';

create function public.sync_item_qty() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.items set qty = coalesce((select sum(qty) from public.item_stock where item_id = items.id), 0)
  where id in (case when tg_op <> 'INSERT' then old.item_id end, case when tg_op <> 'DELETE' then new.item_id end);
  return null;
end $$;
create trigger sync_item_qty after insert or update or delete on public.item_stock
for each row execute function public.sync_item_qty();

-- ---------- add or edit an item with its sizes (admins) ----------
-- p_stock: [{"size": "M", "qty": 12}, ...] or [{"size": "", "qty": 40}] for one size. Sizes left out are removed.
create function public.save_item(p_id bigint, p_code text, p_name text, p_location text, p_photo text, p_stock jsonb)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint;
begin
  if not public.is_admin() then raise exception 'Only admins can change items.'; end if;
  if coalesce(p_code, '') !~ '^\d+$' then raise exception 'The item number can only have numbers.'; end if;
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'Give the item a name.'; end if;
  if jsonb_typeof(p_stock) <> 'array' or jsonb_array_length(p_stock) = 0 then raise exception 'Add a quantity.'; end if;
  if exists (select 1 from jsonb_array_elements(p_stock) s where coalesce((s ->> 'qty')::integer, -1) < 0) then
    raise exception 'Quantities must be 0 or more.';
  end if;
  if jsonb_array_length(p_stock) > 1 and exists (select 1 from jsonb_array_elements(p_stock) s where trim(s ->> 'size') = '') then
    raise exception 'Every size needs a name.';
  end if;
  if exists (select 1 from public.items where code = p_code and id is distinct from p_id) then
    raise exception 'Item number % is already used by another item.', p_code;
  end if;

  if p_id is null then
    insert into public.items (code, name, location, photo_path) values (p_code, trim(p_name), trim(coalesce(p_location, '')), coalesce(p_photo, ''))
    returning id into v_id;
  else
    update public.items set code = p_code, name = trim(p_name), location = trim(coalesce(p_location, '')), photo_path = coalesce(p_photo, '')
    where id = p_id and not deleted returning id into v_id;
    if v_id is null then raise exception 'That item was deleted.'; end if;
  end if;

  delete from public.item_stock where item_id = v_id
    and size not in (select trim(s ->> 'size') from jsonb_array_elements(p_stock) s);
  insert into public.item_stock (item_id, size, qty, sort)
    select v_id, trim(s ->> 'size'), (s ->> 'qty')::integer, (n - 1)::smallint from jsonb_array_elements(p_stock) with ordinality as t(s, n)
  on conflict (item_id, size) do update set qty = excluded.qty, sort = excluded.sort;
  return v_id;
end $$;

-- ---------- check-out / check-in, now per size ----------
-- p_lines: [{"item_id": 1, "size": "M", "qty": 2, "donor": ""}, ...]; size '' (or missing) = one size.
create or replace function public.record_transaction(p_dir text, p_type text, p_event_id bigint, p_donor text, p_lines jsonb)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_tx bigint;
  v_line jsonb;
  v_item public.items;
  v_stock public.item_stock;
  v_qty integer;
  v_size text;
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
    v_size := coalesce(v_line ->> 'size', '');
    if coalesce(v_qty, 0) < 1 then raise exception 'Quantities must be 1 or more.'; end if;
    select * into v_item from public.items where id = (v_line ->> 'item_id')::bigint and not deleted for update;
    if not found then raise exception 'An item in this list was deleted. Remove it and try again.'; end if;
    select * into v_stock from public.item_stock where item_id = v_item.id and size = v_size for update;
    if not found then
      raise exception '% doesn''t come in size %. Remove it and try again.', v_item.name, case when v_size = '' then 'one size' else v_size end;
    end if;
    if p_dir = 'out' and v_stock.qty < v_qty then
      raise exception 'Only % left in stock for %.', v_stock.qty, v_item.name || case when v_size = '' then '' else ' (' || v_size || ')' end;
    end if;
    update public.item_stock set qty = qty + (case when p_dir = 'out' then -v_qty else v_qty end)
    where item_id = v_item.id and size = v_size;
    insert into public.transaction_lines (transaction_id, item_id, qty, donor, size)
    values (v_tx, v_item.id, v_qty, coalesce(v_line ->> 'donor', ''), v_size);
  end loop;
  return v_tx;
end $$;

-- ---------- deleting an entry, now per size ----------
create or replace function public.delete_transaction(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_tx public.transactions;
  v_line public.transaction_lines;
  v_name text;
  v_have integer;
begin
  if not public.is_admin() then raise exception 'Only admins can delete entries.'; end if;
  select * into v_tx from public.transactions where id = p_id for update;
  if not found then raise exception 'That entry was already deleted.'; end if;

  for v_line in select * from public.transaction_lines where transaction_id = p_id order by id loop
    select name into v_name from public.items where id = v_line.item_id for update;
    if v_line.size <> '' then v_name := v_name || ' (' || v_line.size || ')'; end if;
    select qty into v_have from public.item_stock where item_id = v_line.item_id and size = v_line.size for update;
    if v_tx.dir = 'in' then
      if coalesce(v_have, 0) < v_line.qty then
        raise exception 'Can''t delete: this check-in added % %, but only % are in stock now.', v_line.qty, v_name, coalesce(v_have, 0);
      end if;
      update public.item_stock set qty = qty - v_line.qty where item_id = v_line.item_id and size = v_line.size;
    else
      -- the size may have been removed since; putting the items back brings it back
      insert into public.item_stock (item_id, size, qty, sort) values (v_line.item_id, v_line.size, v_line.qty, 99)
      on conflict (item_id, size) do update set qty = item_stock.qty + excluded.qty;
    end if;
  end loop;

  insert into public.deleted_transactions (entry, deleted_by)
  values (to_jsonb(v_tx) || jsonb_build_object('lines',
            coalesce((select jsonb_agg(to_jsonb(l) order by l.id) from public.transaction_lines l where l.transaction_id = p_id), '[]'::jsonb)),
          public.my_email());
  delete from public.transactions where id = p_id;   -- its lines go with it (on delete cascade)
end $$;

revoke execute on function public.save_item(bigint, text, text, text, text, jsonb) from public, anon;
grant execute on function public.save_item(bigint, text, text, text, text, jsonb) to authenticated;
revoke execute on function public.sync_item_qty() from public, anon;

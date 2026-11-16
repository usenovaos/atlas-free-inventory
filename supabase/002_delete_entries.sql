-- Atlas Free Inventory: admins can delete a check-out or check-in entry. Run once in the Supabase SQL Editor.
-- Deleting puts the stock back: a deleted check-out returns its items, a deleted check-in takes them out again.
-- Every deleted entry is copied to deleted_transactions first, so nothing disappears without a record.

create table public.deleted_transactions (
  id bigint generated always as identity primary key,
  entry jsonb not null,          -- the deleted transaction with its lines
  deleted_by text not null,
  deleted_at timestamptz not null default now()
);
alter table public.deleted_transactions enable row level security;
create policy "admins read deleted entries" on public.deleted_transactions for select to authenticated using (public.is_admin());

create function public.delete_transaction(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_tx public.transactions;
  v_line public.transaction_lines;
  v_item public.items;
begin
  if not public.is_admin() then raise exception 'Only admins can delete entries.'; end if;
  select * into v_tx from public.transactions where id = p_id for update;
  if not found then raise exception 'That entry was already deleted.'; end if;

  for v_line in select * from public.transaction_lines where transaction_id = p_id order by id loop
    select * into v_item from public.items where id = v_line.item_id for update;
    if v_tx.dir = 'in' and v_item.qty < v_line.qty then
      raise exception 'Can''t delete: this check-in added % %, but only % are in stock now.', v_line.qty, v_item.name, v_item.qty;
    end if;
    update public.items set qty = qty + (case when v_tx.dir = 'out' then v_line.qty else -v_line.qty end) where id = v_item.id;
  end loop;

  insert into public.deleted_transactions (entry, deleted_by)
  values (to_jsonb(v_tx) || jsonb_build_object('lines',
            coalesce((select jsonb_agg(to_jsonb(l) order by l.id) from public.transaction_lines l where l.transaction_id = p_id), '[]'::jsonb)),
          public.my_email());
  delete from public.transactions where id = p_id;   -- its lines go with it (on delete cascade)
end $$;

revoke execute on function public.delete_transaction(bigint) from public, anon;
grant execute on function public.delete_transaction(bigint) to authenticated;

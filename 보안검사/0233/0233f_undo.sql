-- 0233f 되돌리기 — 표 권한을 넓게 되돌립니다 (Supabase 기본 모습)
begin;
do $$
declare r record;
begin
  for r in select c.relname, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p')
  loop
    if r.relkind in ('r', 'p') then
      execute format('grant all on table public.%I to anon, authenticated', r.relname);
    else
      execute format('grant select on table public.%I to anon, authenticated', r.relname);
    end if;
  end loop;
end $$;
grant execute on function public.am_i_registered() to anon;
grant execute on function public.bot_can() to anon;
grant execute on function public.next_po_no() to anon;
grant execute on function public.mark_proc_done(jsonb) to anon;
delete from public.app_config where key = 'mig_0233f';
commit;

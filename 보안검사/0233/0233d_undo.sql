-- 0233d 되돌리기 — 0233d 가 붙인 「search_path = public」 만 뗍니다
-- (원래부터 고정돼 있던 함수는 값이 'public' 하나가 아니거나 다른 토막(0233a~c, 0235)이 만든 것이라 구분이 어렵습니다.
--  그래서 정확히 'search_path=public' 하나만 설정된 함수 중, 0233a~c·0235 가 만든 함수를 뺀 나머지를 뗍니다.)
begin;
do $$
declare r record; n integer := 0;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
      join pg_language l on l.oid = p.prolang
     where ns.nspname = 'public'
       and l.lanname in ('sql', 'plpgsql')
       and p.proconfig = array['search_path=public']
       and p.proname not in ('orders_guard','receipt_allocs_guard','chat_admin','rate_hit',
                             'device_gate','device_register','device_status','device_list','device_admin',
                             'device_approve','device_revoke','device_rename','device_lock_set','device_lock_on','device_ok')
  loop
    execute format('alter function %s reset search_path', r.sig);
    n := n + 1;
  end loop;
  raise notice '경로 고정 뗀 함수: % 개', n;
end $$;
delete from public.app_config where key = 'mig_0233d';
commit;

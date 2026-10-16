-- ============================================================
-- 0233d  함수 경로 고정  (보안 겹겹이 #30, Supabase 자체 점검 「function_search_path_mutable」)
-- 런하는 곳: Supabase SQL Editor   되돌리기: 0233d_undo.sql   확인: 0233d_check.sql
-- ------------------------------------------------------------
-- public 스키마의 우리 함수 가운데 search_path 가 고정되지 않은 것 전부(약 65개)에
-- 「set search_path = public」 을 붙입니다. 함수 내용은 바뀌지 않습니다.
-- (확장(pg_trgm) 이 만든 C 함수는 건너뜁니다. 암호 함수를 쓰는 cust_* 는 이미 'public, extensions' 로 고정돼 있어 해당 없음)
-- ============================================================
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
       and p.prokind = 'f'
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')   -- 확장 소속 제외
       and (p.proconfig is null
            or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
  loop
    execute format('alter function %s set search_path = public', r.sig);
    n := n + 1;
  end loop;
  raise notice '경로 고정한 함수: % 개', n;
end $$;
insert into public.app_config (key, value) values ('mig_0233d', to_char(now(), 'YYYY-MM-DD HH24:MI'))
  on conflict (key) do update set value = excluded.value;
commit;

-- 0233d 확인 — 「남은 함수」 가 0 이면 된 것입니다
select count(*) as "경로 고정 안 된 우리 함수(0이어야)"
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  join pg_language l on l.oid = p.prolang
 where ns.nspname = 'public' and l.lanname in ('sql','plpgsql') and p.prokind = 'f'
   and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
   and (p.proconfig is null or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'));

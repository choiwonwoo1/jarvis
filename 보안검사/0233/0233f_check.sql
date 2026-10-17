-- 0233f 확인 — 전부 true 면 적용된 것입니다
select 'anon 표 권한 (영업소 보기 하나만)' as 항목,
       (select count(*) = 1 from information_schema.table_privileges where table_schema='public' and grantee='anon') as ok
union all select 'authenticated TRUNCATE 없음', not exists (select 1 from information_schema.table_privileges where table_schema='public' and grantee='authenticated' and privilege_type in ('TRUNCATE','TRIGGER','REFERENCES'))
union all select '백업 표 권한 없음', not exists (select 1 from information_schema.table_privileges where table_schema='public' and grantee in ('anon','authenticated') and (table_name like '\_bak\_%' or table_name like 'backup\_%' or table_name like '\_co\_addr\_backup%'))
union all select 'anon 이 bot_can 못 부름', not has_function_privilege('anon', 'public.bot_can()', 'execute')
union all select '적용 표시', exists (select 1 from app_config where key='mig_0233f');

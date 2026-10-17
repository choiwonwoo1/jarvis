-- 0233c 확인 — 전부 true 면 적용된 것입니다
select 'rate_hits 표' as 항목, exists(select 1 from pg_tables where tablename='rate_hits') as ok
union all select 'rate_hit 함수', exists(select 1 from pg_proc where proname='rate_hit')
union all select 'rate_hit 화면에서 못 부름', coalesce((select not has_function_privilege('authenticated', p.oid, 'execute') from pg_proc p where p.proname='rate_hit' limit 1), false)
union all select 'submit_order 견적 제한(0233a 판 포함)', (select position('0233c(#22)' in prosrc)>0 and position('0233a(#14)' in prosrc)>0 from pg_proc where proname='submit_order')
union all select 'cust_join 가입 제한', (select position('0233c(#22)' in prosrc)>0 from pg_proc where proname='cust_join')
union all select 'register_staff 코드 제한', (select position('0233c(#28)' in prosrc)>0 from pg_proc where proname='register_staff')
union all select 'cust_pw_reset_issue 보냄만', (select position('0233c(#9)' in prosrc)>0 from pg_proc where proname='cust_pw_reset_issue')
union all select 'cust_login 옛 세션 삭제', (select position('0233c(#10)' in prosrc)>0 from pg_proc where proname='cust_login')
union all select 'cust_profile_save 이메일 기록', (select position('0233c(#8)' in prosrc)>0 from pg_proc where proname='cust_profile_save')
union all select '적용 표시', exists(select 1 from app_config where key='mig_0233c');

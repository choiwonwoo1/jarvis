-- 0233e 확인
select '세션 전체' as 항목, count(*)::text as 값 from auth.sessions
union all select '14일 넘게 안 쓴 세션(0이어야)', count(*)::text from auth.sessions where coalesce(refreshed_at, created_at) < now() - interval '14 days'
union all select '자동 정리 예약(buil-sessions 있어야)', coalesce((select schedule from cron.job where jobname='buil-sessions'), '없음')
union all select '적용 표시', coalesce((select value from app_config where key='mig_0233e'), '없음');

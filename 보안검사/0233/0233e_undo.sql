-- 0233e 되돌리기 — 자동 정리를 멈추고 함수를 지웁니다 (이미 지운 세션은 되돌릴 수 없고, 되돌릴 필요도 없습니다: 다시 로그인하면 됩니다)
begin;
select cron.unschedule(jobid) from cron.job where jobname = 'buil-sessions';
drop function if exists public.sessions_cleanup(integer);
delete from public.app_config where key = 'mig_0233e';
commit;

-- ============================================================
-- 0233e  세션 정리  (「세션 정리해줘」)
-- 런하는 곳: Supabase SQL Editor   되돌리기: 0233e_undo.sql   확인: 0233e_check.sql
-- ------------------------------------------------------------
-- 지금 상태(2026-10-16): 로그인 세션 2,883개. 14일 넘게 안 쓴 것 612개.
--   사장님 계정 2,210개(자동 검사가 로그인할 때마다 하나씩 생김), admin@ 512개(9월 1일 이후 안 씀).
-- 하는 일
--  1) 14일 넘게 안 쓴 세션을 지웁니다 (그 기기는 다음에 한 번 다시 로그인하면 됩니다. 기기 등록은 그대로라 승인은 다시 안 받습니다).
--  2) 같은 일을 매일 새벽 3시 10분(한국)에 자동으로 합니다 (pg_cron 「buil-sessions」).
--  ⚠ admin@ 계정 잠그기는 넣지 않았습니다 — 백업 스크립트·봇이 그 계정을 쓰는지 확인하고 사장님 말씀을 받은 뒤 따로.
-- ============================================================
begin;

create or replace function public.sessions_cleanup(p_days integer default 14)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_n integer;
begin
  delete from auth.sessions
   where coalesce(refreshed_at, created_at) < now() - make_interval(days => greatest(p_days, 1));
  get diagnostics v_n = row_count;
  return v_n;
end
$$;
revoke all on function public.sessions_cleanup(integer) from public, anon, authenticated;

-- 1) 지금 한 번
select public.sessions_cleanup(14) as "지운 세션 수";

-- 2) 매일 (18:10 UTC = 한국 03:10)
select cron.unschedule(jobid) from cron.job where jobname = 'buil-sessions';
select cron.schedule('buil-sessions', '10 18 * * *', $$select public.sessions_cleanup(14)$$);

insert into public.app_config (key, value) values ('mig_0233e', to_char(now(), 'YYYY-MM-DD HH24:MI'))
  on conflict (key) do update set value = excluded.value;
commit;

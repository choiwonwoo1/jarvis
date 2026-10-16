-- ============================================================
-- 0233f  권한 한 겹 더  (「권한 한 겹 더 넣어줘」)
-- 런하는 곳: Supabase SQL Editor   되돌리기: 0233f_undo.sql   확인: 0233f_check.sql
-- ------------------------------------------------------------
-- 지금은 행 규칙(RLS)이 막고 있지만, 표 권한 자체는 로그인 전(anon)·로그인 직원(authenticated)에게 넓게 열려 있습니다.
-- 규칙이 하나 잘못 풀려도 표 권한이 한 번 더 막도록 합니다. 화면 동작은 바뀌지 않습니다.
--  1) 로그인 전(anon): 모든 표 권한을 뺍니다. 남기는 것은 화물 영업소 보기 하나(택배 조회 화면).
--     (견적 요청·회원 가입·회원 로그인은 함수(SECURITY DEFINER)로 하므로 표 권한이 필요 없습니다)
--  2) 로그인 직원(authenticated): 표를 통째로 비우는 TRUNCATE, 트리거를 다는 TRIGGER, 외래키를 거는 REFERENCES 권한을 모든 표에서 뺍니다.
--     (TRUNCATE 는 행 규칙을 안 거칩니다 — 지금 이 권한을 쓸 길은 없지만 남겨 둘 이유도 없습니다)
--  3) 백업 표(_bak_*, _co_addr_backup_*, backup_0198): 로그인 계정 권한 전부 뺌 (SQL Editor 의 되돌리기 파일은 postgres 로 돌아 영향 없음).
--  4) 내부 함수 4개를 로그인 전(anon)이 못 부르게: am_i_registered, bot_can, next_po_no, mark_proc_done.
-- ⚠ Supabase 는 새 표·함수를 만들면 anon·authenticated 권한을 저절로 줍니다. 앞으로 만든 표는 그때그때 같이 봐야 합니다.
-- ============================================================
begin;

-- 1) anon
do $$
declare r record;
begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p')
  loop
    execute format('revoke all on table public.%I from anon', r.relname);
  end loop;
end $$;
grant select on table public.freight_agencies to anon;   -- 「영업소 보기」 규칙(active 만) 그대로

-- 2) authenticated: truncate / trigger / references
do $$
declare r record;
begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r', 'p')
  loop
    execute format('revoke truncate, trigger, references on table public.%I from authenticated', r.relname);
  end loop;
end $$;

-- 3) 백업 표
do $$
declare r record;
begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r'
              and (c.relname like '\_bak\_%' or c.relname like '\_co\_addr\_backup%' or c.relname like 'backup\_%')
  loop
    execute format('revoke all on table public.%I from anon, authenticated', r.relname);
  end loop;
end $$;

-- 4) 내부 함수
revoke execute on function public.am_i_registered() from public, anon;
revoke execute on function public.bot_can()         from public, anon;
revoke execute on function public.next_po_no()      from public, anon;
revoke execute on function public.mark_proc_done(jsonb) from public, anon;
grant  execute on function public.am_i_registered(), public.bot_can(), public.next_po_no(), public.mark_proc_done(jsonb) to authenticated, service_role;

insert into public.app_config (key, value) values ('mig_0233f', to_char(now(), 'YYYY-MM-DD HH24:MI'))
  on conflict (key) do update set value = excluded.value;
commit;

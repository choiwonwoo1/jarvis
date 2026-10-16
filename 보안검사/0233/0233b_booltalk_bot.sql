-- ============================================================
-- 0233b  삭제 막기 ② — 부일톡·봇  (보안 겹겹이 #11 #12 #13 #18 #19 #27 #29 #31④ #32)
-- 런하는 곳: Supabase SQL Editor  (0233a 다음에)
-- 되돌리기: 0233b_undo.sql   확인: 0233b_check.sql
-- ------------------------------------------------------------
-- 바뀌는 것
--  #11  부일톡 관리자 확인 한 함수 = chat_admin(): 관리자 + 재직 + 승인 + (잠금 켜지면) 승인된 기기.
--       퇴사 처리하면 관리자 권한도 같이 내리고 모든 방에서 빠집니다.
--  #12  발주시스템 역할(profiles)이 없는 계정은 봇에서 「없음」 — 전에는 사무실로 쳤습니다.
--       돈 보기(bot_sees_money)는 사장·사무실만.
--  #13  폰 알림 구독(push_subs)에 주인(owner) 칸 — 남의 구독을 덮거나 지우지 못합니다.
--  #18  방 멤버 표: 내 줄에서 고칠 수 있는 칸을 last_read·muted·favorite 로 한정
--       (전에는 room_id 를 바꿔 다른 방으로 옮겨 들어갈 수 있었습니다). 멤버 추가는 재직·승인 직원끼리만.
--  #19  직원 명단(chat_users) 읽기: 재직·승인 직원만 (전에는 로그인만 하면 전부).
--  #27  부일톡 자유 조회(bot_query): 사무실만 (돈·거래처가 다 보이므로).
--  #29  방 만들기: 재직·승인 직원만. 마지막 사람이 나가도 방·대화를 지우지 않습니다 (기록 보존).
--  #32  방 멤버 확인(is_member)에 재직·승인·기기 확인 — 대화 읽기·검색·멤버 보기·백업이 같이 잠깁니다.
-- ⚠ 봇(승인봇·재고 알림)은 서버 안 definer 함수로 보내므로 영향 없습니다.
-- ============================================================
begin;

-- ── #11 #31④ 부일톡 관리자 확인 ───────────────────────────────
create or replace function public.chat_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from chat_users
                  where id = auth.uid() and is_admin and active and approved)
     and device_gate()
$$;
revoke all on function public.chat_admin() from public, anon;
grant execute on function public.chat_admin() to authenticated, service_role;

-- ── #13 폰 알림 구독 주인 ───────────────────────────────────────
alter table public.push_subs add column if not exists owner uuid;
update public.push_subs set owner = null where owner is null;   -- (기존 줄은 주인 없음: 다음 저장 때 채워짐)

create or replace function public.push_sub_save(payload jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_ep   text := btrim(coalesce(payload->>'endpoint', ''));
  v_p256 text := btrim(coalesce(payload->>'p256dh', ''));
  v_auth text := btrim(coalesce(payload->>'auth', ''));
  v_id   bigint;
begin
  if not is_staff() then raise exception '로그인이 필요합니다'; end if;
  if v_ep = '' or v_p256 = '' or v_auth = '' then
    raise exception '알림 주소가 비어 있습니다';
  end if;

  -- 0233b(#13): 같은 주소를 남이 덮지 못합니다 — 주인이 없거나 나일 때만 갱신
  insert into push_subs (endpoint, p256dh, auth, label, who, ua, owner)
  values (v_ep, v_p256, v_auth,
          left(btrim(coalesce(payload->>'label', '')), 40),
          coalesce(actor_name(), ''),
          left(btrim(coalesce(payload->>'ua', '')), 200),
          auth.uid())
  on conflict (endpoint) do update
     set p256dh = excluded.p256dh,
         auth   = excluded.auth,
         label  = coalesce(nullif(excluded.label, ''), push_subs.label),
         who    = excluded.who,
         ua     = excluded.ua,
         owner  = coalesce(push_subs.owner, excluded.owner),
         fail_cnt = 0
   where push_subs.owner is null or push_subs.owner = auth.uid()
  returning id into v_id;
  if v_id is null then raise exception '다른 사람의 알림 주소입니다'; end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;

create or replace function public.push_sub_drop(payload jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_ep text := btrim(coalesce(payload->>'endpoint', ''));
begin
  if not is_staff() then raise exception '로그인이 필요합니다'; end if;
  -- 0233b(#13): 내 것(또는 주인 없는 옛 줄)만 지웁니다
  delete from push_subs where endpoint = v_ep and (owner is null or owner = auth.uid());
  return jsonb_build_object('ok', true);
end;
$function$;

-- ── #18 방 멤버 표 ───────────────────────────────────────────────
revoke insert, update, delete on table public.room_members from anon, authenticated;
grant insert (room_id, user_id)            on table public.room_members to authenticated;
grant update (last_read, muted, favorite)  on table public.room_members to authenticated;

drop policy if exists members_add on public.room_members;
create policy members_add on public.room_members for insert to authenticated
  with check (
    is_member(room_id)
    and exists (select 1 from chat_users c where c.id = user_id and c.active and c.approved)
    and exists (select 1 from rooms r where r.id = room_id and r.kind = 'group')   -- 1:1 방에는 제3자를 못 넣음
  );

-- ── #19 직원 명단 읽기 ──────────────────────────────────────────
drop policy if exists users_read on public.chat_users;
create policy users_read on public.chat_users for select to authenticated
  using (id = auth.uid() or bot_can());

-- ── 함수들 ───────────────────────────────────────────────────────
-- ── add_staff
CREATE OR REPLACE FUNCTION public.add_staff(p_email text, p_name text, p_dept text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  if not (chat_admin()
          or coalesce(my_role() = '사장', false)) then
    raise exception '부일톡 관리자만 직원을 추가할 수 있습니다' using errcode = '42501';
  end if;
  select id into v_id from auth.users where email = p_email;
  if v_id is null then
    raise exception '먼저 Supabase Authentication 에서 % 계정을 만들어 주세요.', p_email;
  end if;
  insert into chat_users (id, display_name, dept) values (v_id, p_name, p_dept)
    on conflict (id) do update set display_name = excluded.display_name, dept = excluded.dept;
  return v_id;
end
$function$
;

-- ── approve_staff
CREATE OR REPLACE FUNCTION public.approve_staff(p_user uuid, p_ok boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if not chat_admin() then
    return json_build_object('ok', false, 'message', '관리자만 할 수 있습니다.');
  end if;

  if p_ok then
    update chat_users set approved = true where id = p_user;
    insert into room_members (room_id, user_id)
    select r.id, p_user from rooms r where r.kind = 'group' and r.open_to_all
    on conflict do nothing;
    return json_build_object('ok', true, 'message', '승인했습니다.');
  else
    update chat_users set approved = false where id = p_user;
    delete from room_members where user_id = p_user;
    return json_build_object('ok', true, 'message', '승인을 취소했습니다.');
  end if;
end $function$
;

-- ── backup_dump
CREATE OR REPLACE FUNCTION public.backup_dump()
 RETURNS TABLE(room_name text, room_kind text, at timestamp with time zone, sender_name text, kind text, body text, file_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not chat_admin() then
    raise exception '관리자만 백업할 수 있습니다.';
  end if;

  return query
    select r.name, r.kind, m.created_at,
           coalesce(c.display_name, '알 수 없음'),
           m.kind,
           case when m.deleted_at is not null then '(삭제된 메시지)' else m.body end,
           m.file_name
    from messages m
    join rooms r on r.id = m.room_id
    left join chat_users c on c.id = m.sender_id
    order by r.name, m.created_at;
end $function$
;

-- ── bot_query
CREATE OR REPLACE FUNCTION public.bot_query(p_sql text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text; why text; v json; n int;
begin
  if not bot_sees_money() then raise exception '사무실 직원만 조회할 수 있습니다.'; end if;   -- 0233b(#27): 자유 조회는 사무실만 (돈·거래처가 다 보이므로)

  why := bot_sql_check(p_sql);
  if why is not null then
    return json_build_object('ok', false, 'error', why);
  end if;
  s := regexp_replace(btrim(p_sql), ';\s*$', '');

  begin
    set local role bot_reader;
    set local statement_timeout = '5000';
    execute 'select coalesce(json_agg(t), ''[]''::json) from (select * from (' || s || ') x limit 51) t'
      into v;
    reset role;
  exception when others then
    reset role;
    return json_build_object('ok', false, 'error', sqlerrm);
  end;

  n := json_array_length(v);
  return json_build_object(
    'ok', true,
    'rows', case when n > 50 then (select json_agg(e) from (select e from json_array_elements(v) e limit 50) q) else v end,
    'more', n > 50
  );
end $function$
;

-- ── bot_role
CREATE OR REPLACE FUNCTION public.bot_role()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select p.role from profiles p where p.id = auth.uid()), '없음');   -- 0233b(#12): 역할이 없으면 「없음」 (전에는 사무실로 쳤음)
$function$
;

-- ── bot_sees_money
CREATE OR REPLACE FUNCTION public.bot_sees_money()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select bot_can()
     and coalesce((select p.role from profiles p where p.id = auth.uid()), '없음') in ('사장', '사무실');   -- 0233b(#12): 사장·사무실만
$function$
;

-- ── create_room
CREATE OR REPLACE FUNCTION public.create_room(p_name text, p_kind text DEFAULT 'group'::text, p_open boolean DEFAULT false)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
        v_id  bigint;
begin
  if v_uid is null then raise exception '로그인이 필요합니다.'; end if;
  if not bot_can() then   -- 0233b(#29): 재직·승인된 직원만 (전에는 승인 전·퇴사자도 방을 만들 수 있었음)
    raise exception '가입이 완료되지 않았습니다.';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception '채팅방 이름을 입력해 주세요.';
  end if;
  if p_kind not in ('group','direct') then p_kind := 'group'; end if;

  insert into rooms (name, kind, created_by, open_to_all)
  values (btrim(p_name), p_kind, v_uid, coalesce(p_open, false))
  returning id into v_id;

  if p_open then
    -- 전 직원 참여 방
    insert into room_members (room_id, user_id)
    select v_id, c.id from chat_users c on conflict do nothing;
  else
    insert into room_members (room_id, user_id) values (v_id, v_uid) on conflict do nothing;
  end if;

  return v_id;
end $function$
;

-- ── event_del
CREATE OR REPLACE FUNCTION public.event_del(p_id bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
        v_owner uuid;
begin
  select author_id into v_owner from events where id = p_id;
  if not exists (select 1 from events where id = p_id) then
    return json_build_object('ok', false, 'message', '일정을 찾을 수 없습니다.');
  end if;

  if v_owner is distinct from v_uid
     and not chat_admin() then
    return json_build_object('ok', false, 'message', '올린 사람과 관리자만 지울 수 있습니다.');
  end if;

  delete from events where id = p_id;
  return json_build_object('ok', true, 'message', '일정을 지웠습니다.');
end $function$
;

-- ── is_member
CREATE OR REPLACE FUNCTION public.is_member(p_room bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select bot_can()   -- 0233b(#32): 재직·승인된 직원이고 (잠금 켜지면) 승인된 기기일 때만
     and exists (select 1 from room_members m where m.room_id = p_room and m.user_id = auth.uid());
$function$
;

-- ── leave_room
CREATE OR REPLACE FUNCTION public.leave_room(p_room bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
        v_name text;
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not exists (select 1 from room_members where room_id = p_room and user_id = v_uid) then
    return json_build_object('ok', false, 'message', '참여 중인 방이 아닙니다.');
  end if;

  select display_name into v_name from chat_users where id = v_uid;
  delete from room_members where room_id = p_room and user_id = v_uid;

  -- 0233b(#29): 아무도 안 남아도 방과 대화는 지우지 않습니다 (기록 보존 — 마지막 사람이 나가며 대화를 없앨 수 있었음)
  if not exists (select 1 from room_members where room_id = p_room) then
    return json_build_object('ok', true, 'message', '방을 나갔습니다.');
  end if;

  insert into messages (room_id, sender_id, kind, body)
  values (p_room, v_uid, 'system', v_name || ' 님이 나갔습니다.');

  return json_build_object('ok', true, 'message', '방을 나갔습니다.');
end $function$
;

-- ── notice_add
CREATE OR REPLACE FUNCTION public.notice_add(p_title text, p_body text, p_pinned boolean DEFAULT false)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
        v_admin boolean;
begin
  if not exists (select 1 from chat_users cu where cu.id = v_uid and cu.active and cu.approved) then
    return json_build_object('ok', false, 'message', '부일톡 직원만 올릴 수 있습니다.');
  end if;
  if p_title is null or btrim(p_title) = '' then
    return json_build_object('ok', false, 'message', '제목을 입력해 주세요.');
  end if;

  v_admin := chat_admin();   -- 0233b: 재직·승인·기기 확인까지

  insert into notices (title, body, author_id, pinned)
  values (btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), v_uid,
          coalesce(p_pinned, false) and coalesce(v_admin, false));

  return json_build_object('ok', true, 'message', '공지를 올렸습니다.');
end $function$
;

-- ── notice_del
CREATE OR REPLACE FUNCTION public.notice_del(p_id bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
        v_owner uuid;
begin
  select n.author_id into v_owner from notices n where n.id = p_id;
  if not exists (select 1 from notices n where n.id = p_id) then
    return json_build_object('ok', false, 'message', '공지를 찾을 수 없습니다.');
  end if;
  if v_owner is distinct from v_uid
     and not chat_admin() then
    return json_build_object('ok', false, 'message', '올린 사람과 관리자만 지울 수 있습니다.');
  end if;

  delete from notices where id = p_id;
  return json_build_object('ok', true, 'message', '공지를 지웠습니다.');
end $function$
;

-- ── notice_edit
CREATE OR REPLACE FUNCTION public.notice_edit(p_id bigint, p_title text, p_body text, p_pinned boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
        v_admin boolean;
        v_owner uuid;
begin
  v_admin := chat_admin();   -- 0233b: 재직·승인·기기 확인까지
  select n.author_id into v_owner from notices n where n.id = p_id;

  if v_owner is null and not exists (select 1 from notices n where n.id = p_id) then
    return json_build_object('ok', false, 'message', '공지를 찾을 수 없습니다.');
  end if;
  if v_owner is distinct from v_uid and not coalesce(v_admin, false) then
    return json_build_object('ok', false, 'message', '올린 사람과 관리자만 고칠 수 있습니다.');
  end if;
  if p_title is null or btrim(p_title) = '' then
    return json_build_object('ok', false, 'message', '제목을 입력해 주세요.');
  end if;

  update notices
     set title = btrim(p_title),
         body = nullif(btrim(coalesce(p_body, '')), ''),
         pinned = case when coalesce(v_admin, false) then coalesce(p_pinned, false) else pinned end,
         updated_at = now()
   where id = p_id;

  return json_build_object('ok', true, 'message', '공지를 고쳤습니다.');
end $function$
;

-- ── set_active
CREATE OR REPLACE FUNCTION public.set_active(p_user uuid, p_active boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not chat_admin() then
    return json_build_object('ok', false, 'message', '관리자만 할 수 있습니다.');
  end if;
  if p_user = v_uid then
    return json_build_object('ok', false, 'message', '자기 자신은 바꿀 수 없습니다.');
  end if;

  update chat_users
     set active   = coalesce(p_active, true),
         is_admin = case when coalesce(p_active, true) then is_admin else false end   -- 0233b(#11): 퇴사자는 관리자 권한도 내림
   where id = p_user;
  if not coalesce(p_active, true) then
    delete from room_members where user_id = p_user;                                  -- 0233b(#11): 퇴사자는 방에서도 빠짐
  end if;
  return json_build_object('ok', true, 'message',
    case when p_active then '다시 사용하도록 했습니다.' else '퇴사 처리했습니다.' end);
end $function$
;

-- ── set_bank_users
CREATE OR REPLACE FUNCTION public.set_bank_users(p_users uuid[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
        v_ok  uuid[];
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not chat_admin() then
    return json_build_object('ok', false, 'message', '관리자만 정할 수 있습니다.');
  end if;

  -- 부일톡 직원인 사람만 남깁니다 (지워진 계정이 남아 알림이 새지 않게)
  select coalesce(array_agg(u.id), '{}')
    into v_ok
    from chat_users u
   where u.id = any(coalesce(p_users, '{}'));

  if array_length(v_ok, 1) is null then
    delete from app_config where key = 'bank_notify_users';
    return json_build_object('ok', true, 'message', '입금 도착 알림을 껐습니다.', 'count', 0);
  end if;

  insert into app_config (key, value)
  values ('bank_notify_users', to_jsonb(v_ok)::text)
  on conflict (key) do update set value = excluded.value;

  return json_build_object('ok', true,
    'message', array_length(v_ok, 1) || '명에게 입금 도착 알림을 보냅니다.',
    'count', array_length(v_ok, 1));
end $function$
;

-- ── set_bot_ai
CREATE OR REPLACE FUNCTION public.set_bot_ai(p_on boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not chat_admin() then
    return json_build_object('ok', false, 'message', '관리자만 바꿀 수 있습니다.');
  end if;

  insert into app_config (key, value)
  values ('bot_ai', case when p_on then 'on' else 'off' end)
  on conflict (key) do update set value = excluded.value;

  return json_build_object('ok', true, 'on', p_on);
end $function$
;

-- ── set_order_room
CREATE OR REPLACE FUNCTION public.set_order_room(p_room bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not chat_admin() then
    return json_build_object('ok', false, 'message', '관리자만 정할 수 있습니다.');
  end if;

  if p_room is null then
    delete from app_config where key = 'order_room_id';
    return json_build_object('ok', true, 'message', '발주 알림을 껐습니다.');
  end if;

  if not exists (select 1 from rooms where id = p_room) then
    return json_build_object('ok', false, 'message', '채팅방을 찾을 수 없습니다.');
  end if;

  insert into app_config (key, value) values ('order_room_id', p_room::text)
  on conflict (key) do update set value = excluded.value;
  return json_build_object('ok', true, 'message', '이 채팅방으로 발주 알림을 받습니다.');
end $function$
;

-- ── set_order_users
CREATE OR REPLACE FUNCTION public.set_order_users(p_users uuid[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
        v_ok  uuid[];
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not chat_admin() then
    return json_build_object('ok', false, 'message', '관리자만 정할 수 있습니다.');
  end if;

  -- 부일톡 직원인 사람만 남깁니다 (지워진 계정이 남아 알림이 새지 않게)
  select coalesce(array_agg(u.id), '{}')
    into v_ok
    from chat_users u
   where u.id = any(coalesce(p_users, '{}'));

  if array_length(v_ok, 1) is null then
    delete from app_config where key = 'order_notify_users';
    return json_build_object('ok', true, 'message', '주문·견적 알림을 껐습니다.', 'count', 0);
  end if;

  insert into app_config (key, value)
  values ('order_notify_users', to_jsonb(v_ok)::text)
  on conflict (key) do update set value = excluded.value;

  return json_build_object('ok', true,
    'message', array_length(v_ok, 1) || '명에게 새 주문·견적 알림을 보냅니다.',
    'count', array_length(v_ok, 1));
end $function$
;

-- ── set_pay_sender
CREATE OR REPLACE FUNCTION public.set_pay_sender(p_user uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not chat_admin() then
    return json_build_object('ok', false, 'message', '관리자만 정할 수 있습니다.');
  end if;

  if p_user is null then
    delete from app_config where key = 'pay_sender_id';
    return json_build_object('ok', true, 'message', '첫 관리자 이름으로 보냅니다.');
  end if;
  if not exists (select 1 from chat_users where id = p_user) then
    return json_build_object('ok', false, 'message', '그 직원을 찾을 수 없습니다.');
  end if;

  insert into app_config (key, value) values ('pay_sender_id', p_user::text)
  on conflict (key) do update set value = excluded.value;
  return json_build_object('ok', true, 'message', '이 계정 이름으로 입금 알림을 보냅니다.');
end $function$
;

-- ── set_pay_users
CREATE OR REPLACE FUNCTION public.set_pay_users(p_users uuid[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
        v_ok  uuid[];
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not chat_admin() then
    return json_build_object('ok', false, 'message', '관리자만 정할 수 있습니다.');
  end if;

  -- 부일톡 직원인 사람만 남깁니다 (지워진 계정이 남아 알림이 새지 않게)
  select coalesce(array_agg(u.id), '{}')
    into v_ok
    from chat_users u
   where u.id = any(coalesce(p_users, '{}'));

  if array_length(v_ok, 1) is null then
    delete from app_config where key = 'pay_notify_users';
    return json_build_object('ok', true, 'message', '입금 알림을 껐습니다.', 'count', 0);
  end if;

  insert into app_config (key, value)
  values ('pay_notify_users', to_jsonb(v_ok)::text)
  on conflict (key) do update set value = excluded.value;

  return json_build_object('ok', true,
    'message', array_length(v_ok, 1) || '명에게 입금 알림을 보냅니다.',
    'count', array_length(v_ok, 1));
end $function$
;

-- ── set_signup_code
CREATE OR REPLACE FUNCTION public.set_signup_code(p_code text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if not chat_admin() then
    return json_build_object('ok', false, 'message', '관리자만 바꿀 수 있습니다.');
  end if;
  if p_code is null or length(btrim(p_code)) < 4 then
    return json_build_object('ok', false, 'message', '가입코드는 4자 이상이어야 합니다.');
  end if;
  insert into app_config (key, value) values ('signup_code', btrim(p_code))
  on conflict (key) do update set value = excluded.value;
  return json_build_object('ok', true, 'message', '가입코드를 바꿨습니다.');
end $function$
;

-- ── set_signup_mode
CREATE OR REPLACE FUNCTION public.set_signup_mode(p_mode text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if not chat_admin() then
    return json_build_object('ok', false, 'message', '관리자만 바꿀 수 있습니다.');
  end if;
  if p_mode not in ('code','approve') then
    return json_build_object('ok', false, 'message', '알 수 없는 방식입니다.');
  end if;
  insert into app_config (key, value) values ('signup_mode', p_mode)
  on conflict (key) do update set value = excluded.value;
  return json_build_object('ok', true, 'message',
    case when p_mode = 'approve' then '이제 관리자 승인 후 사용할 수 있습니다.'
         else '가입코드만 맞으면 바로 사용합니다.' end);
end $function$
;

insert into public.app_config (key, value) values ('mig_0233b', to_char(now(), 'YYYY-MM-DD HH24:MI'))
  on conflict (key) do update set value = excluded.value;
commit;

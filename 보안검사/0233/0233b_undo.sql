-- 0233b 되돌리기 — 런 전 모습으로 (push_subs.owner 칸은 남겨 두어도 해가 없어 그대로 둡니다)
begin;
grant insert, update, delete on table public.room_members to authenticated;
drop policy if exists members_add on public.room_members;
create policy members_add on public.room_members for insert to authenticated with check (is_member(room_id));
drop policy if exists users_read on public.chat_users;
create policy users_read on public.chat_users for select to authenticated using (true);

CREATE OR REPLACE FUNCTION public.push_sub_save(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  insert into push_subs (endpoint, p256dh, auth, label, who, ua)
  values (v_ep, v_p256, v_auth,
          left(btrim(coalesce(payload->>'label', '')), 40),
          coalesce(actor_name(), ''),
          left(btrim(coalesce(payload->>'ua', '')), 200))
  on conflict (endpoint) do update
     set p256dh = excluded.p256dh,
         auth   = excluded.auth,
         label  = coalesce(nullif(excluded.label, ''), push_subs.label),
         who    = excluded.who,
         ua     = excluded.ua,
         fail_cnt = 0
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.push_sub_drop(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ep text := btrim(coalesce(payload->>'endpoint', ''));
begin
  if not is_staff() then raise exception '로그인이 필요합니다'; end if;
  delete from push_subs where endpoint = v_ep;
  return jsonb_build_object('ok', true);
end;
$function$;

CREATE OR REPLACE FUNCTION public.add_staff(p_email text, p_name text, p_dept text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  if not (coalesce((select is_admin from chat_users where id = auth.uid()), false)
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

CREATE OR REPLACE FUNCTION public.approve_staff(p_user uuid, p_ok boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if not exists (select 1 from chat_users where id = v_uid and is_admin) then
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

CREATE OR REPLACE FUNCTION public.backup_dump()
 RETURNS TABLE(room_name text, room_kind text, at timestamp with time zone, sender_name text, kind text, body text, file_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from chat_users where id = auth.uid() and is_admin) then
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

CREATE OR REPLACE FUNCTION public.bot_query(p_sql text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text; why text; v json; n int;
begin
  if not bot_can() then raise exception '부일톡 직원만 조회할 수 있습니다.'; end if;

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

CREATE OR REPLACE FUNCTION public.bot_role()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select p.role from profiles p where p.id = auth.uid()), '사무실');
$function$
;

CREATE OR REPLACE FUNCTION public.bot_sees_money()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select bot_can()
     and coalesce((select p.role from profiles p where p.id = auth.uid()), '사무실') <> '창고';
$function$
;

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
  if not exists (select 1 from chat_users where id = v_uid) then
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
     and not exists (select 1 from chat_users where id = v_uid and is_admin) then
    return json_build_object('ok', false, 'message', '올린 사람과 관리자만 지울 수 있습니다.');
  end if;

  delete from events where id = p_id;
  return json_build_object('ok', true, 'message', '일정을 지웠습니다.');
end $function$
;

CREATE OR REPLACE FUNCTION public.is_member(p_room bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from room_members m where m.room_id = p_room and m.user_id = auth.uid());
$function$
;

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

  -- 아무도 안 남으면 방을 지운다
  if not exists (select 1 from room_members where room_id = p_room) then
    delete from messages where room_id = p_room;
    delete from rooms where id = p_room;
    return json_build_object('ok', true, 'message', '방을 나갔습니다.');
  end if;

  insert into messages (room_id, sender_id, kind, body)
  values (p_room, v_uid, 'system', v_name || ' 님이 나갔습니다.');

  return json_build_object('ok', true, 'message', '방을 나갔습니다.');
end $function$
;

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

  select cu.is_admin into v_admin from chat_users cu where cu.id = v_uid;

  insert into notices (title, body, author_id, pinned)
  values (btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), v_uid,
          coalesce(p_pinned, false) and coalesce(v_admin, false));

  return json_build_object('ok', true, 'message', '공지를 올렸습니다.');
end $function$
;

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
     and not exists (select 1 from chat_users cu where cu.id = v_uid and cu.is_admin) then
    return json_build_object('ok', false, 'message', '올린 사람과 관리자만 지울 수 있습니다.');
  end if;

  delete from notices where id = p_id;
  return json_build_object('ok', true, 'message', '공지를 지웠습니다.');
end $function$
;

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
  select cu.is_admin into v_admin from chat_users cu where cu.id = v_uid;
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

CREATE OR REPLACE FUNCTION public.set_active(p_user uuid, p_active boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not exists (select 1 from chat_users where id = v_uid and is_admin) then
    return json_build_object('ok', false, 'message', '관리자만 할 수 있습니다.');
  end if;
  if p_user = v_uid then
    return json_build_object('ok', false, 'message', '자기 자신은 바꿀 수 없습니다.');
  end if;

  update chat_users set active = coalesce(p_active, true) where id = p_user;
  return json_build_object('ok', true, 'message',
    case when p_active then '다시 사용하도록 했습니다.' else '퇴사 처리했습니다.' end);
end $function$
;

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
  if not exists (select 1 from chat_users where id = v_uid and is_admin) then
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

CREATE OR REPLACE FUNCTION public.set_bot_ai(p_on boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not exists (select 1 from chat_users where id = v_uid and is_admin) then
    return json_build_object('ok', false, 'message', '관리자만 바꿀 수 있습니다.');
  end if;

  insert into app_config (key, value)
  values ('bot_ai', case when p_on then 'on' else 'off' end)
  on conflict (key) do update set value = excluded.value;

  return json_build_object('ok', true, 'on', p_on);
end $function$
;

CREATE OR REPLACE FUNCTION public.set_order_room(p_room bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not exists (select 1 from chat_users where id = v_uid and is_admin) then
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
  if not exists (select 1 from chat_users where id = v_uid and is_admin) then
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

CREATE OR REPLACE FUNCTION public.set_pay_sender(p_user uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return json_build_object('ok', false, 'message', '로그인이 필요합니다.'); end if;
  if not exists (select 1 from chat_users where id = v_uid and is_admin) then
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
  if not exists (select 1 from chat_users where id = v_uid and is_admin) then
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

CREATE OR REPLACE FUNCTION public.set_signup_code(p_code text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if not exists (select 1 from chat_users where id = v_uid and is_admin) then
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

CREATE OR REPLACE FUNCTION public.set_signup_mode(p_mode text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
begin
  if not exists (select 1 from chat_users where id = v_uid and is_admin) then
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

drop function if exists public.chat_admin();
delete from public.app_config where key = 'mig_0233b';
commit;

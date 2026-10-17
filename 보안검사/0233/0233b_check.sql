-- 0233b 확인 — 전부 true 면 적용된 것입니다
select 'chat_admin 함수' as 항목, exists(select 1 from pg_proc where proname='chat_admin') as ok
union all select '관리자 함수 16개가 chat_admin 사용', (select count(*)=16 from pg_proc where proname in ('approve_staff','set_active','set_bank_users','set_bot_ai','set_order_room','set_order_users','set_pay_sender','set_pay_users','set_signup_code','set_signup_mode','event_del','notice_del','notice_add','notice_edit','backup_dump','add_staff') and position('chat_admin()' in prosrc)>0)
union all select 'is_member 재직·기기 확인', (select position('bot_can()' in prosrc)>0 from pg_proc where proname='is_member')
union all select 'bot_role 없음', (select position('''없음''' in prosrc)>0 from pg_proc where proname='bot_role')
union all select 'bot_sees_money 사장·사무실만', (select position('in (''사장'', ''사무실'')' in prosrc)>0 from pg_proc where proname='bot_sees_money')
union all select 'bot_query 사무실만', (select position('bot_sees_money()' in prosrc)>0 from pg_proc where proname='bot_query')
union all select 'create_room 재직만', (select position('bot_can()' in prosrc)>0 from pg_proc where proname='create_room')
union all select 'leave_room 기록 보존', (select position('delete from rooms' in prosrc)=0 from pg_proc where proname='leave_room')
union all select 'push_subs.owner 칸', exists(select 1 from information_schema.columns where table_name='push_subs' and column_name='owner')
union all select 'push_sub_save 주인 확인', (select position('push_subs.owner' in prosrc)>0 from pg_proc where proname='push_sub_save')
union all select 'room_members 표 전체 UPDATE 없음', not has_table_privilege('authenticated','public.room_members','update')
union all select 'room_members last_read 만 UPDATE', has_column_privilege('authenticated','public.room_members','last_read','update') and not has_column_privilege('authenticated','public.room_members','room_id','update')
union all select 'members_add 재직·단체방 확인', (select with_check like '%approved%' and with_check like '%group%' from pg_policies where tablename='room_members' and policyname='members_add')
union all select 'users_read 재직만', (select qual like '%bot_can%' from pg_policies where tablename='chat_users' and policyname='users_read')
union all select '적용 표시', exists(select 1 from app_config where key='mig_0233b');

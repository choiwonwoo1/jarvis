-- 0233a 확인 — 전부 true 면 적용된 것입니다
select 'orders 트리거' as 항목, exists(select 1 from pg_trigger where tgname='orders_guard_bdu') as ok
union all select 'receipt_allocs 트리거', exists(select 1 from pg_trigger where tgname='receipt_allocs_guard_biu')
union all select 'ship_take_stock 못 부름', not has_function_privilege('authenticated','public.ship_take_stock(bigint,text,bigint,text)','execute')
union all select 'ship_give_back_stock 못 부름', not has_function_privilege('authenticated','public.ship_give_back_stock(text)','execute')
union all select 'ship_check_packer 못 부름', not has_function_privilege('authenticated','public.ship_check_packer(bigint,text)','execute')
union all select 'submit_order 사무실 확인', (select position('0233a(#14)' in prosrc)>0 from pg_proc where proname='submit_order')
union all select 'po_save 사무실만', (select position('need_office' in prosrc)>0 from pg_proc where proname='po_save')
union all select 'add_receipt 배정 검사', (select position('0233a(#15)' in prosrc)>0 from pg_proc where proname='add_receipt')
union all select 'bank_inbox_confirm 잠금', (select position('for update' in prosrc)>0 from pg_proc where proname='bank_inbox_confirm')
union all select '입금 보기 사무실만', (select qual like '%is_office%' from pg_policies where tablename='receipts' and policyname='입금 보기')
union all select '배정 보기 사무실만', (select qual like '%is_office%' from pg_policies where tablename='receipt_allocs' and policyname='배정 보기')
union all select '폰입금 보기 사무실만', (select qual like '%is_office%' from pg_policies where tablename='bank_inbox' and policyname='폰입금 보기')
union all select '구매발주 _write 정책 없음', not exists(select 1 from pg_policies where policyname in ('purchase_orders_write','purchase_order_items_write'))
union all select '적용 표시', exists(select 1 from app_config where key='mig_0233a');

# 0233 보안 SQL (Supabase SQL Editor 용) — 런 순서

1. 0233a_orders_stock_money.sql  주문·재고·돈
2. 0233b_booltalk_bot.sql        부일톡·봇
3. 0233c_customers_ratelimit.sql 고객·횟수 제한 (0233a 뒤에)
4. 0233d_search_path.sql         함수 경로 고정
5. 0233e_sessions.sql            세션 정리
6. 0233f_privileges.sql          권한 한 겹 더

0233_전부_한번에.sql = 위 여섯을 순서대로 합친 것. 각 파일마다 _undo / _check 가 있음.

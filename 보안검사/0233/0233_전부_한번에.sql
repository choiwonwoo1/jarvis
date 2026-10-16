-- 0233 전체 (a→f 순서대로 한 번에). 중간에 빨간 줄이 나오면 그 줄을 알려 주세요 — 앞 토막들은 각각 commit 되어 그대로 남고, 그 토막만 다시 하면 됩니다.


-- ########## 0233a_orders_stock_money ##########
-- ============================================================
-- 0233a  삭제 막기 ① — 주문·재고·돈  (보안 겹겹이 #1 #2 #14 #15 #16 #17 #20 #21)
-- 런하는 곳: Supabase SQL Editor  (한 번에 전체 붙여넣고 Run)
-- 되돌리기: 0233a_undo.sql   확인: 0233a_check.sql
-- ------------------------------------------------------------
-- 바뀌는 것
--  #1  주문 표를 직접 고쳐서 지우는 길을 막습니다 (트리거).
--      · 휴지통(deleted_at)에 안 넣은 주문은 아무도 못 지웁니다.
--      · 입금이 배정된 주문은 휴지통에도 못 넣고 지우지도 못합니다.
--      · 출고가 걸린 주문은 권한자 두 사람(kevin@, csm860611@)만 휴지통에 넣습니다.
--      ⇒ 화면 버튼(delete_orders·purge_trash)과 같은 규칙이라 평소 쓰는 데는 변화 없음.
--      ⇒ 서버 안에서 postgres 가 돌리는 함수·pg_cron·service_role 은 그대로 통과
--         (트리거는 로그인 계정(authenticated/anon)으로 들어온 SQL 에만 겁니다).
--  #2  재고 깎기·되돌리기 속 함수(ship_take_stock 등 3개)를 화면에서 직접 못 부르게.
--  #14 로그인한 직원이 주문서를 넣을 때 사무실만 (창고·역할 없음 계정 막기).
--  #15 입금 배정: 음수 줄로 합계 속이기 막기, 다른 거래처 주문에 얹기 막기 (+ 표 트리거).
--  #16 입금·배정·폰입금 표 읽기: 직원 전체 → 사무실만 (창고는 돈을 안 봅니다).
--  #17 폰입금 확정: 둘이 동시에 눌러도 한 번만.
--  #20 구매발주 표의 넓은 쓰기 정책(_write ALL) 삭제 — 좁은 정책(_ins/_upd/_del)만 남김.
--  #21 구매발주 저장(po_save): 사무실만.
-- ============================================================
begin;

-- ── #1 주문 지우기 트리거 ────────────────────────────────────
create or replace function public.orders_guard()
returns trigger
language plpgsql
set search_path = public          -- ⚠ definer 아님: definer 로 만들면 안에서 current_user 가 postgres 가 되어 검사가 빠집니다
as $$
declare
  v_email text;
  v_power boolean;
begin
  /* 로그인 계정으로 들어온 SQL(화면·REST)에만 겁니다.
     postgres 소유 definer 함수 안에서는 current_user 가 postgres, pg_cron 도 postgres,
     service_role 은 service_role 이라 모두 통과. */
  if current_user not in ('authenticated', 'anon') then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;

  if tg_op = 'DELETE' then
    if old.deleted_at is null then
      raise exception '휴지통에 넣은 주문만 지울 수 있습니다 (%)', old.order_no;
    end if;
    if exists (select 1 from receipt_allocs a where a.order_id = old.id) then
      raise exception '입금이 배정된 주문은 지울 수 없습니다 (%)', old.order_no;
    end if;
    return old;
  end if;

  -- UPDATE: 휴지통에 넣는 순간만 봅니다 (deleted_at  null → 값)
  if old.deleted_at is null and new.deleted_at is not null then
    if exists (select 1 from receipt_allocs a where a.order_id = old.id) then
      raise exception '입금이 배정된 주문은 지울 수 없습니다 — 입금 관리에서 배정을 먼저 풀어 주세요 (%)', old.order_no;
    end if;
    v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
    v_power := v_email in ('kevin@builindus.co.kr', 'csm860611@builindus.co.kr');
    if not v_power and exists (select 1 from shipments s where s.order_id = old.id and s.status <> '취소') then
      raise exception '출고가 걸린 주문은 지울 수 없습니다 (%)', old.order_no;
    end if;
  end if;
  return new;
end
$$;
revoke all on function public.orders_guard() from public, anon, authenticated;

drop trigger if exists orders_guard_bdu on public.orders;
create trigger orders_guard_bdu
  before update or delete on public.orders
  for each row execute function public.orders_guard();

-- ── #2 재고 속 함수 직접 호출 막기 ─────────────────────────────
-- (부르는 쪽 pack_shipment·unpack_shipment·direct_complete 등은 모두 postgres 소유 definer 라 영향 없음)
revoke execute on function public.ship_take_stock(bigint, text, bigint, text) from public, anon, authenticated;
revoke execute on function public.ship_give_back_stock(text)                 from public, anon, authenticated;
revoke execute on function public.ship_check_packer(bigint, text)            from public, anon, authenticated;

-- ── #15 배정 표 트리거 (직접 INSERT/UPDATE 로 넣는 길까지) ────────
create or replace function public.receipt_allocs_guard()
returns trigger
language plpgsql
set search_path = public          -- ⚠ definer 아님 (위와 같은 까닭)
as $$
declare
  v_r receipts%rowtype;
  v_used bigint;
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if new.amount <= 0 then
    raise exception '배정 금액은 0보다 커야 합니다';
  end if;
  select * into v_r from receipts where id = new.receipt_id;
  if not found then raise exception '그 입금 기록이 없습니다'; end if;
  if not exists (select 1 from orders o where o.id = new.order_id and o.customer_id = v_r.customer_id) then
    raise exception '다른 거래처의 주문에는 얹을 수 없습니다';
  end if;
  select coalesce(sum(amount), 0) into v_used
    from receipt_allocs where receipt_id = new.receipt_id
     and (tg_op = 'INSERT' or id <> old.id);
  if v_used + new.amount > v_r.amount then
    raise exception '배정 합계가 입금액을 넘습니다';
  end if;
  return new;
end
$$;
revoke all on function public.receipt_allocs_guard() from public, anon, authenticated;

drop trigger if exists receipt_allocs_guard_biu on public.receipt_allocs;
create trigger receipt_allocs_guard_biu
  before insert or update on public.receipt_allocs
  for each row execute function public.receipt_allocs_guard();

-- ── #16 돈 표 읽기: 사무실만 ────────────────────────────────────
drop policy if exists "입금 보기"   on public.receipts;
create policy "입금 보기"   on public.receipts       for select to authenticated using ((select is_office()));
drop policy if exists "배정 보기"   on public.receipt_allocs;
create policy "배정 보기"   on public.receipt_allocs for select to authenticated using ((select is_office()));
drop policy if exists "폰입금 보기" on public.bank_inbox;
create policy "폰입금 보기" on public.bank_inbox     for select to authenticated using ((select is_office()));

-- ── #20 구매발주 넓은 쓰기 정책 삭제 ──────────────────────────────
drop policy if exists purchase_orders_write      on public.purchase_orders;
drop policy if exists purchase_order_items_write on public.purchase_order_items;

-- ── #14 submit_order ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.submit_order(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_kind  text := coalesce(nullif(btrim(payload->>'kind'), ''), '발주');
  v_recv  text := coalesce(nullif(btrim(payload->>'recv'), ''), '택배');
  v_pay   text := coalesce(nullif(btrim(payload->>'shipPay'), ''), '착불');
  v_otel  text := left(btrim(coalesce(payload->>'officeTel', '')), 30);
  v_baddr text := left(btrim(coalesce(payload->>'bizAddr', '')), 200);
  v_rname text := left(btrim(coalesce(payload->>'rcvName', '')), 50);
  v_rtel  text := left(btrim(coalesce(payload->>'rcvTel', '')), 30);
  v_fax   text := left(btrim(coalesce(payload->>'fax', '')), 30);
  v_cust  text := btrim(coalesce(payload->>'cust', ''));
  v_bizno text := regexp_replace(coalesce(payload->>'bizno', ''), '[^0-9]', '', 'g');
  v_items jsonb := coalesce(payload->'items', '[]'::jsonb);
  v_tok   text  := coalesce(payload->>'token', '');   -- 0128: 회원 입장권(로그인 때 받음)
  v_scid  bigint;                                      -- 입장권이 가리키는 거래처
  v_login text;                                        -- 0135: 입장권의 아이디
  v_req   bigint := case when coalesce(payload->>'customer_id', '') ~ '^[0-9]+$'
                         then (payload->>'customer_id')::bigint end;   -- 0135: 발주서가 고른 사업장
  v_ord   bigint := case when coalesce(payload->>'orderer_id', '') ~ '^[0-9]+$'
                         then (payload->>'orderer_id')::bigint end;    -- 0179: 주문처(하도업체)
  v_ordn  text;                                                         -- 0179: 주문처 상호
  v_stat  text;
  v_cid   bigint;
  v_oid   bigint;
  v_no    text;
  v_day   text := to_char(now() at time zone 'Asia/Seoul', 'YYYYMMDD');
  v_seq   integer;
  v_line  jsonb;
  v_n     integer := 0;
  v_name  text;
  v_qty   integer;
  v_iid   bigint;            -- 방금 넣은 품목 줄 id (가공을 매달 자리)
  v_procs jsonb;             -- 그 줄에 딸린 가공들
  v_pl    jsonb;
  v_pk    text;
  v_pt    text;
  v_pq    integer;
  v_pn    integer := 0;      -- 받은 가공 줄 수
begin
  if v_kind not in ('발주', '견적') then
    raise exception '주문 종류가 올바르지 않습니다';
  end if;
  /* 0128: 발주는 ① 로그인한 회원(맞는 입장권) 또는 ② 사무실 담당자(관리자 화면,
     auth.uid() 가 있음)만 받습니다. 견적은 전처럼 누구나 됩니다. */
  v_scid  := cust_session_cid(v_tok);
  v_login := cust_session_login(v_tok);                                   -- 0135
  if v_kind = '발주' and v_scid is null and auth.uid() is null then
    raise exception '발주는 로그인한 회원만 할 수 있습니다. 다시 로그인해 주세요 (견적 요청은 로그인 없이도 됩니다)';
  end if;
  if v_recv not in ('택배', '화물', '방문', '직송') then
    v_recv := '택배';
  end if;
  if v_recv = '방문' or v_pay not in ('착불', '현불') then
    v_pay := '착불';
  end if;
  if v_cust = '' then
    raise exception '상호를 적어 주세요';
  end if;
  if length(v_cust) > 100 then
    raise exception '상호가 너무 깁니다';
  end if;
  if v_bizno <> '' and length(v_bizno) <> 10 then
    raise exception '사업자등록번호는 10자리입니다 (예: 123-45-67890)';
  end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception '품목을 하나 이상 담아 주세요';
  end if;
  if jsonb_array_length(v_items) > 200 then
    raise exception '한 번에 200줄까지 넣을 수 있습니다';
  end if;
  /* 0233a(#14): 로그인한 직원 계정이면 사무실만 주문을 넣습니다.
     전에는 창고 계정·역할 없는 계정도 이 길로 주문을 넣고 원장(연락처)을 고칠 수 있었습니다. */
  if auth.uid() is not null then
    perform need_office();
  end if;

  /* 0179: 주문처(하도업체)가 오면 — 그 하도업체의 청구처 목록에 있는 곳만.
     주문의 거래처(customer_id)는 청구처(본사업자)입니다. 상호 글자로 찾지 않습니다.
     0180: 사무실뿐 아니라 **회원**도 됩니다 — 주문처가 그 아이디에 연결된 거래처일 때만. */
  if v_ord is not null then
    if auth.uid() is not null then
      perform need_office();
    else
      if v_scid is null
         or not exists (select 1 from cust_allowed_cids(v_login) as t(cid) where t.cid = v_ord) then
        raise exception '이 계정으로 발주할 수 없는 거래처입니다. 다시 로그인해 주세요';
      end if;
      select status into v_stat from customers where id = v_ord;
      if v_kind = '발주' and v_stat = '가입검토' then
        raise exception '사무실에서 가입을 확인한 뒤 발주하실 수 있습니다. 확인이 끝나면 부일산업에서 연락드립니다 (견적 요청은 지금도 됩니다)';
      end if;
    end if;
    if v_req is null then
      raise exception '청구처를 골라 주세요';
    end if;
    if v_req = v_ord then
      raise exception '청구처가 주문처와 같습니다 — 자기 이름으로 받을 때는 주문처를 비워 보내야 합니다';
    end if;
    if not exists (select 1 from customer_bill_to where sub_id = v_ord and bill_id = v_req) then
      raise exception '이 주문처에 등록된 청구처가 아닙니다 — 거래처 관리에서 청구처를 다시 확인해 주세요';
    end if;
    select name into v_ordn from customers where id = v_ord;
    select id into v_cid from customers where id = v_req and merged_into is null;
    if v_cid is null then
      raise exception '청구처가 합쳐졌거나 없습니다 — 거래처 관리에서 다시 확인해 주세요';
    end if;
  /* 0128: 입장권이 있으면 그 거래처입니다 — 보낸 상호 글자로 찾지 않습니다 */
  elsif v_scid is not null then
    v_cid := v_scid;
    /* 0135: 발주서에서 다른 사업장(칩)을 골랐으면 — 이 아이디에 연결된 거래처만 됩니다.
       세션을 바꾸는 방식이 아니라 주문마다 검증합니다(PC·폰·탭 여러 개 동시 사용 안전). */
    if v_req is not null and v_req <> v_scid then
      if not exists (select 1 from cust_allowed_cids(v_login) as t(cid) where t.cid = v_req) then
        raise exception '이 계정으로 발주할 수 없는 거래처입니다. 부일산업(032-565-6262)에 연결을 요청해 주세요';
      end if;
      v_cid := v_req;
    end if;
    /* 0135: 사무실이 아직 본사업자를 연결하지 않은 가입은 견적만 됩니다 */
    select status into v_stat from customers where id = v_cid;
    if v_kind = '발주' and v_stat = '가입검토' then
      raise exception '사무실에서 가입을 확인한 뒤 발주하실 수 있습니다. 확인이 끝나면 부일산업에서 연락드립니다 (견적 요청은 지금도 됩니다)';
    end if;
  else
    select id into v_cid from customers where name = v_cust;
  end if;
  if v_cid is null then
    insert into customers (name, bizno, office_tel, fax, biz_addr,
                           person, tel, email, addr)
    values (v_cust,
            nullif(v_bizno, ''),
            nullif(v_otel, ''),
            nullif(v_fax, ''),
            nullif(v_baddr, ''),
            left(btrim(coalesce(payload->>'person', '')), 50),
            left(btrim(coalesce(payload->>'tel',    '')), 30),
            left(btrim(coalesce(payload->>'email',  '')), 100),
            left(btrim(coalesce(payload->>'addr',   '')), 200))
    returning id into v_cid;
  elsif v_ord is not null then
    /* 0179: 청구처(본사업자) 원장은 건드리지 않습니다 — 폼의 담당자·연락처·배송지는
       하도업체 것이라, 덮으면 본사업자 원장이 하도업체 연락처로 바뀝니다.
       이 주문의 연락처·배송지는 아래 orders 스냅샷에만 들어갑니다. */
    null;
  elsif v_scid is not null then
    /* 0135: 회원 발주는 원장을 덮지 않습니다 — **빈 칸만** 채웁니다.
       전에는 발주할 때마다 폼의 사무실전화·팩스·주소·담당자가 원장을 덮어서,
       한 사람이 A사↔B사를 오가며 발주하면 두 회사 원장이 서로를 덮어썼습니다.
       이 주문의 최신 연락처는 orders 스냅샷에 남고, 원장은 관리자(save_order_cust)로 고칩니다. */
    update customers set
      bizno      = case when v_bizno <> '' and coalesce(btrim(bizno), '') = ''
                        then v_bizno else bizno end,
      office_tel = coalesce(nullif(btrim(office_tel), ''), nullif(v_otel, '')),
      biz_addr   = coalesce(nullif(btrim(biz_addr), ''),   nullif(v_baddr, '')),
      fax        = coalesce(nullif(btrim(fax), ''),        nullif(v_fax, '')),
      person     = coalesce(nullif(btrim(person), ''),
                            nullif(left(btrim(coalesce(payload->>'person', '')), 50), '')),
      tel        = coalesce(nullif(btrim(tel), ''),
                            nullif(left(btrim(coalesce(payload->>'tel',    '')), 30), '')),
      email      = coalesce(nullif(btrim(email), ''),
                            nullif(left(btrim(coalesce(payload->>'email',  '')), 100), '')),
      addr       = coalesce(nullif(btrim(addr), ''),
                            nullif(left(btrim(coalesce(payload->>'addr',   '')), 200), ''))
     where id = v_cid;
  elsif auth.uid() is not null then
    -- 0195: 사무실 담당자가 관리자 화면에서 넣은 주문 — 연락처를 최신 값으로 갱신합니다 (0106 그대로)
    update customers set
      bizno  = case when v_bizno <> '' and coalesce(btrim(bizno), '') = ''
                    then v_bizno else bizno end,
      office_tel = coalesce(nullif(v_otel, ''), office_tel),
      biz_addr = coalesce(nullif(v_baddr, ''), biz_addr),
      fax    = coalesce(nullif(v_fax, ''), fax),
      person = coalesce(nullif(left(btrim(coalesce(payload->>'person', '')), 50), ''), person),
      tel    = coalesce(nullif(left(btrim(coalesce(payload->>'tel',    '')), 30), ''), tel),
      email  = coalesce(nullif(left(btrim(coalesce(payload->>'email',  '')), 100), ''), email),
      addr   = coalesce(nullif(left(btrim(coalesce(payload->>'addr',   '')), 200), ''), addr)
     where id = v_cid;
  else
    /* 0195: 비회원 견적 — 이미 있는 거래처 원장은 **건드리지 않습니다**.
       상호 글자만 같으면 로그인 없이 남의 회사 이메일·전화·주소를 바꿀 수 있었고,
       바뀐 이메일로 비밀번호 찾기를 하면 임시 비밀번호가 그 사람에게 갔습니다.
       빈 칸 채우기도 같은 구멍이라(이메일이 빈 회사) 하지 않습니다.
       이 견적의 연락처는 아래 orders 스냅샷에 그대로 남고, 원장은 사무실이 고칩니다. */
    null;
  end if;

  -- 사업자등록증 첨부 — 비공개 보관함(biz-certs)의 경로만 기억합니다
  -- 0153: 비회원은 원장에 등록증이 **없을 때만** 적습니다 (남의 상호를 적어 견적을 넣으면서
  -- 그 회사의 등록증을 갈아 끼우지 못하게). 0135 로 되돌리며(0152) 이 방어가 같이 빠졌던 것을 되살립니다.
  -- 0179: 주문처가 있으면 폼의 등록증은 하도업체 것이라 청구처 원장에 안 붙입니다.
  if coalesce(btrim(payload->>'cert'), '') <> '' and v_ord is null then
    update customers
       set cert_path = left(btrim(payload->>'cert'), 300),
           cert_at   = now()
     where id = v_cid
       and (v_scid is not null or auth.uid() is not null
            or coalesce(btrim(cert_path), '') = '');
  end if;

  perform pg_advisory_xact_lock(hashtext('order_no_' || v_day));
  select coalesce(max(split_part(order_no, '-', 2)::integer), 0) + 1
    into v_seq
    from orders
   where order_no like v_day || '-%';
  v_no := v_day || '-' || lpad(v_seq::text, 3, '0');

  insert into orders (order_no, customer_id, kind, recv_method, ship_pay,
                      rcv_name, rcv_tel,
                      sender_kind, sender_name, sender_tel, sender_addr,
                      stmt_enclosed,
                      person, tel, email, addr, memo, valid_until,
                      orderer_id, orderer_name)                                  -- 0179
  values (v_no, v_cid, v_kind, v_recv, v_pay,
          nullif(v_rname, ''), nullif(v_rtel, ''),
          case when btrim(coalesce(payload->>'senderKind', '')) in ('부일','주문처','지정')
               then btrim(payload->>'senderKind') else '부일' end,
          nullif(left(btrim(coalesce(payload->>'senderName', '')), 100), ''),
          nullif(left(btrim(coalesce(payload->>'senderTel',  '')),  30), ''),
          nullif(left(btrim(coalesce(payload->>'senderAddr', '')), 200), ''),
          coalesce((payload->>'stmtEnclosed')::boolean, true),
          left(btrim(coalesce(payload->>'person', '')), 50),
          left(btrim(coalesce(payload->>'tel',    '')), 30),
          left(btrim(coalesce(payload->>'email',  '')), 100),
          left(btrim(coalesce(payload->>'addr',   '')), 200),
          left(btrim(coalesce(payload->>'memo',   '')), 1000),
          case when v_kind = '견적'
               then (now() at time zone 'Asia/Seoul')::date + 14 end,
          v_ord, v_ordn)
  returning id into v_oid;

  for v_line in select * from jsonb_array_elements(v_items) loop
    v_name := btrim(coalesce(v_line->>'name', ''));
    if v_name = '' then
      raise exception '품명이 빈 줄이 있습니다';
    end if;
    v_qty := coalesce((v_line->>'qty')::integer, 0);
    if v_qty < 1 or v_qty > 100000 then
      raise exception '% — 수량은 1 이상 100000 이하로 적어 주세요', v_name;
    end if;

    insert into order_items (order_id, item_id, name, size, std, color,
                             qty, orig_qty)
    values (v_oid,
            /* 0191 — 상품 번호가 온 줄만 그 상품에 붙입니다. 번호 없이 품명만 온 줄(직접 입력)은
               품명이 같은 등록상품이 있어도 붙이지 않습니다 — 「말 그대로 직접 입력」(사장님 2026-10-07).
               0011 부터 품명으로 붙여 왔는데, 하계방염복처럼 품명이 같은 상품이 15종이라
               번호가 가장 작은 점퍼에 스판하의 줄이 붙었습니다(20261006-028). */
            (select i.id from items i
              where btrim(i.name) = v_name
                and i.id = (case when (v_line->>'item_id') ~ '^[0-9]+$'
                                 then (v_line->>'item_id')::bigint end)),
            left(v_name, 200),
            left(btrim(coalesce(v_line->>'size', '')), 50),
            nullif(left(btrim(coalesce(v_line->>'std',   '')), 50), ''),
            nullif(left(btrim(coalesce(v_line->>'color', '')), 50), ''),
            v_qty, v_qty)
    returning id into v_iid;
    v_n := v_n + 1;

    v_procs := v_line->'procs';
    if v_procs is not null and jsonb_typeof(v_procs) = 'array' then
      if jsonb_array_length(v_procs) > 20 then
        raise exception '% — 가공은 한 품목에 20줄까지 넣을 수 있습니다', v_name;
      end if;
      for v_pl in select * from jsonb_array_elements(v_procs) loop
        v_pk := btrim(coalesce(v_pl->>'kind', ''));
        v_pt := btrim(coalesce(v_pl->>'text', ''));
        v_pq := coalesce((v_pl->>'qty')::integer, 0);
        if v_pk = '' then
          raise exception '% — 어떤 가공인지 적어 주세요', v_name;
        end if;
        if v_pt = '' then
          raise exception '% % — 무엇을 넣을지 적어 주세요', v_name, v_pk;
        end if;
        if v_pq < 1 or v_pq > 100000 then
          raise exception '% % — 가공 수량은 1 이상 100000 이하로 적어 주세요',
                          v_name, v_pk;
        end if;
        insert into order_item_procs (order_item_id, kind, proc_text, qty)
        values (v_iid, left(v_pk, 40), left(v_pt, 300), v_pq);
        v_pn := v_pn + 1;
      end loop;
    end if;
  end loop;

  insert into order_events (order_id, kind, detail)
  values (v_oid, '주문접수', jsonb_build_object('종류', v_kind, '줄수', v_n,
                                              '수령', v_recv, '가공줄수', v_pn,
                                              '회원', (v_scid is not null),   -- 0128
                                              '주문처', v_ordn));              -- 0179

  /* 0151: 실제로 어느 사업장에 들어갔는지 돌려준다 — 완료 화면이 이 값을 크게 보여 준다.
     ⚠ 회원·사무실이면(자기 거래처) 원장 값을 그대로 준다. 비회원 견적은 자기가 적은
     값만 돌려준다 — 상호 글자로 찾아 붙인 «남의» 거래처의 사업자번호·내부 id 가
     응답에 실려 나가면 상호만 알아도 그 회사 사업자번호를 알아낼 수 있었다(0151). */
  if v_scid is not null or auth.uid() is not null then
    return jsonb_build_object('order_no', v_no, 'lines', v_n, 'procs', v_pn,
                              'customer_id', v_cid,
                              'orderer', v_ordn,                                   -- 0180
                              'cust',  (select cust_typed_name(name) from customers where id = v_cid),
                              'bizno', (select coalesce(bizno, '') from customers where id = v_cid));
  else
    return jsonb_build_object('order_no', v_no, 'lines', v_n, 'procs', v_pn,
                              'customer_id', null,
                              'cust',  v_cust,
                              'bizno', v_bizno);
  end if;
end;
$function$
;

-- ── #21 po_save ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.po_save(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id    bigint;
  v_no    text;
  v_stage text;
  v_sup   bigint;
  v_way   text;
  v_items jsonb;
  v_day   text;
  v_n     integer;
  v_try   integer := 0;
  v_lines bigint[] := '{}';   -- 0126 — 저장 전후로 이 발주서에 이어진 주문 줄
  v_sync  integer := 0;
  v_l     bigint;
begin
  perform need_office();   -- 0233a(#21): 구매발주 저장은 사무실만 (전에는 창고 계정도 됐습니다)
  perform set_config('buil.po_sync', '1', true);

  -- ── 들어온 것 살피기 ───────────────────────────────────────
  v_sup := nullif(btrim(coalesce(payload->>'supId', '')), '')::bigint;
  if v_sup is null then
    raise exception '공급처를 골라 주세요';
  end if;

  v_items := coalesce(payload->'items', '[]'::jsonb);
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception '품목을 하나 이상 넣어 주세요';
  end if;

  v_way := case when payload->>'recvWay' = '업체직송' then '업체직송' else '부일입고' end;
  if v_way = '업체직송'
     and btrim(coalesce(payload->>'shipToAddr', '')) = '' then
    raise exception '업체 직송은 보낼 주소가 있어야 합니다';
  end if;

  v_id := nullif(btrim(coalesce(payload->>'id', '')), '')::bigint;

  -- ── 헤더 ───────────────────────────────────────────────────
  if v_id is null then
    v_day := to_char((now() at time zone 'Asia/Seoul')::date, 'YYYYMMDD');
    perform pg_advisory_xact_lock(hashtext('po_no:' || v_day));

    loop
      v_try := v_try + 1;
      select coalesce(max(split_part(po_no, '-', 3)::int), 0) + 1
        into v_n
        from purchase_orders
       where po_no like 'PO-' || v_day || '-%';
      v_no := 'PO-' || v_day || '-' || lpad(v_n::text, 2, '0');

      begin
        insert into purchase_orders
          (po_no, supplier_id, po_date, want_date, ref, memo, staff, stage,
           recv_way, order_id, ship_to_name, ship_to_tel, ship_to_addr)
        values
          (v_no, v_sup,
           coalesce(nullif(btrim(coalesce(payload->>'date', '')), '')::date,
                    (now() at time zone 'Asia/Seoul')::date),
           nullif(btrim(coalesce(payload->>'want', '')), '')::date,
           left(coalesce(payload->>'ref', ''), 200),
           left(coalesce(payload->>'memo', ''), 500),
           left(coalesce(payload->>'staff', ''), 30),
           '작성중',
           v_way,
           nullif(btrim(coalesce(payload->>'orderId', '')), '')::bigint,
           left(nullif(btrim(coalesce(payload->>'shipToName', '')), ''), 50),
           left(nullif(btrim(coalesce(payload->>'shipToTel', '')), ''), 30),
           left(nullif(btrim(coalesce(payload->>'shipToAddr', '')), ''), 200))
        returning id into v_id;
        exit;
      exception when unique_violation then
        if v_try >= 20 then raise; end if;
      end;
    end loop;

  else
    select stage, po_no into v_stage, v_no
      from purchase_orders where id = v_id for update;
    if v_stage is null then
      raise exception '발주서를 찾을 수 없습니다';
    end if;
    if v_stage <> '작성중' then
      raise exception '작성중인 발주서만 고칠 수 있습니다 (지금 %)', v_stage;
    end if;

    update purchase_orders set
      supplier_id  = v_sup,
      po_date      = coalesce(nullif(btrim(coalesce(payload->>'date', '')), '')::date, po_date),
      want_date    = nullif(btrim(coalesce(payload->>'want', '')), '')::date,
      ref          = left(coalesce(payload->>'ref', ''), 200),
      memo         = left(coalesce(payload->>'memo', ''), 500),
      staff        = left(coalesce(payload->>'staff', ''), 30),
      recv_way     = v_way,
      order_id     = nullif(btrim(coalesce(payload->>'orderId', '')), '')::bigint,
      ship_to_name = left(nullif(btrim(coalesce(payload->>'shipToName', '')), ''), 50),
      ship_to_tel  = left(nullif(btrim(coalesce(payload->>'shipToTel', '')), ''), 30),
      ship_to_addr = left(nullif(btrim(coalesce(payload->>'shipToAddr', '')), ''), 200)
     where id = v_id;
  end if;

  -- ── 품목 갈아 끼우기 ───────────────────────────────────────
  select coalesce(array_agg(order_item_id), '{}') into v_lines
    from purchase_order_items where po_id = v_id and order_item_id is not null;
  delete from purchase_order_items where po_id = v_id;

  -- 0174 — std, color 되살림 (0105 에 있었는데 0129 가 다시 쓰며 빠뜨림)
  insert into purchase_order_items
    (po_id, item_id, name, size, std, color, unit, qty, unit_price, note, order_item_id, sort)
  select
    v_id,
    nullif(btrim(coalesce(e->>'itemId', '')), '')::bigint,
    left(coalesce(e->>'name', ''), 120),
    nullif(btrim(coalesce(e->>'size', '')), ''),
    nullif(btrim(coalesce(e->>'std', '')), ''),
    nullif(btrim(coalesce(e->>'color', '')), ''),
    coalesce(nullif(btrim(coalesce(e->>'unit', '')), ''), 'EA'),
    greatest(1, floor(coalesce(nullif(btrim(coalesce(e->>'qty', '')), ''), '0')::numeric)::int),
    greatest(0, floor(coalesce(nullif(btrim(coalesce(e->>'price', '')), ''), '0')::numeric)::int),
    left(nullif(btrim(coalesce(e->>'note', '')), ''), 200),
    nullif(btrim(coalesce(e->>'lineId', '')), '')::bigint,
    (n - 1)::int
  from jsonb_array_elements(v_items) with ordinality as t(e, n);

  perform set_config('buil.po_sync', '', true);
  for v_l in
    select distinct u.l from (
      select unnest(v_lines) as l
      union
      select order_item_id from purchase_order_items where po_id = v_id and order_item_id is not null
    ) u where u.l is not null
  loop
    v_sync := v_sync + direct_plan_sync_line(v_l, left(coalesce(payload->>'staff', ''), 30),
                                             '발주서 ' || v_no || ' 저장');
  end loop;

  return jsonb_build_object('id', v_id, 'poNo', v_no, 'synced', v_sync);
end;
$function$
;

-- ── #15 add_receipt ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.add_receipt(payload jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cust   bigint  := nullif(payload->>'customer_id', '')::bigint;
  v_amt    integer := coalesce(nullif(payload->>'amount', '')::integer, 0);
  v_paid   date    := coalesce(nullif(payload->>'paid_at', '')::date, current_date);
  v_staff  text    := left(btrim(coalesce(payload->>'staff', '')), 30);
  v_id     bigint;
  v_sum    bigint  := 0;
  v_row    jsonb;
  v_oid    bigint;
  v_oamt   integer;
  v_name   text;
begin
  if not is_office() then
    raise exception '사무실 권한이 필요합니다';
  end if;
  if v_cust is null then raise exception '거래처를 고르세요'; end if;
  if v_amt <= 0 then raise exception '입금액을 적으세요'; end if;

  -- 배정 합계가 입금액을 넘으면 막습니다.
  -- 모자란 것은 막지 않습니다 — 남은 만큼이 선수금입니다.
  for v_row in select * from jsonb_array_elements(coalesce(payload->'allocs', '[]'::jsonb))
  loop
    v_oid  := nullif(v_row->>'order_id', '')::bigint;
    v_oamt := coalesce(nullif(v_row->>'amount', '')::integer, 0);
    /* 0233a(#15): 음수 줄은 합계에서 빼 주지 않습니다 — 음수로 합계를 낮춰 입금액보다
       많이 배정할 수 있었습니다. 다른 거래처 주문에 얹는 것도 막습니다(alloc_receipt 와 같은 규칙). */
    if v_oamt < 0 then raise exception '배정 금액은 0보다 커야 합니다'; end if;
    if v_oid is not null and v_oamt > 0 then
      if not exists (select 1 from orders o where o.id = v_oid and o.customer_id = v_cust) then
        raise exception '다른 거래처의 주문에는 얹을 수 없습니다';
      end if;
      v_sum := v_sum + v_oamt;
    end if;
  end loop;
  if v_sum > v_amt then
    raise exception '배정한 금액(%)이 입금액(%)보다 많습니다', v_sum, v_amt;
  end if;

  insert into receipts (customer_id, amount, paid_at, payer, bank, memo, staff)
  values (v_cust, v_amt, v_paid,
          left(btrim(coalesce(payload->>'payer', '')), 60),
          left(btrim(coalesce(payload->>'bank',  '')), 30),
          left(btrim(coalesce(payload->>'memo',  '')), 300),
          v_staff)
  returning id into v_id;

  for v_row in select * from jsonb_array_elements(coalesce(payload->'allocs', '[]'::jsonb))
  loop
    v_oid  := nullif(v_row->>'order_id', '')::bigint;
    v_oamt := coalesce(nullif(v_row->>'amount', '')::integer, 0);
    if v_oid is not null and v_oamt > 0 then
      insert into receipt_allocs (receipt_id, order_id, amount)
      values (v_id, v_oid, v_oamt)
      on conflict (receipt_id, order_id)
        do update set amount = receipt_allocs.amount + excluded.amount;
    end if;
  end loop;

  select name into v_name from customers where id = v_cust;

  insert into activity_logs (customer_id, category, kind, title, body, staff, is_manual)
  values (v_cust, '입금', '입금확인',
          coalesce(v_name, '거래처') || ' ' || to_char(v_amt, 'FM999,999,999') || '원 입금 확인',
          '입금일 ' || to_char(v_paid, 'YYYY-MM-DD')
            || coalesce(' · 입금자 ' || nullif(btrim(coalesce(payload->>'payer','')), ''), '')
            || coalesce(' · ' || nullif(btrim(coalesce(payload->>'bank','')), ''), '')
            || ' · 배정 ' || to_char(v_sum, 'FM999,999,999') || '원'
            || case when v_amt - v_sum > 0
                    then ' · 선수금 ' || to_char(v_amt - v_sum, 'FM999,999,999') || '원'
                    else '' end,
          v_staff, true);

  return v_id;
end;
$function$
;

-- ── #17 bank_inbox_confirm ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.bank_inbox_confirm(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id   bigint  := nullif(payload->>'id', '')::bigint;
  v_cust bigint  := nullif(payload->>'customer_id', '')::bigint;
  v_amt  integer := nullif(payload->>'amount', '')::integer;
  v_row  bank_inbox%rowtype;
  v_rid  bigint;
  v_head text;
begin
  if not is_office() then raise exception '사무실 권한이 필요합니다'; end if;

  select * into v_row from bank_inbox where id = v_id for update;   -- 0233a(#17): 둘이 동시에 눌러도 한 번만
  if not found then raise exception '그 줄을 찾을 수 없습니다'; end if;
  if v_row.status <> '대기' then
    raise exception '이미 %(으)로 처리된 줄입니다', v_row.status;
  end if;
  if v_cust is null then raise exception '거래처를 고르세요'; end if;

  v_amt := coalesce(v_amt, v_row.amount);
  if v_amt is null or v_amt <= 0 then raise exception '입금액을 적으세요'; end if;

  /* 어디서 온 줄인지 메모에 남깁니다 — 「받은 돈」 표에서 바로 보입니다 */
  v_head := case when v_row.source = '엑셀' then '은행 엑셀에서 확인 · ' else '폰 알림에서 확인 · ' end;

  /* ⚠ 입금일은 **한국 날짜**여야 합니다 (0116 참조). 화면이 보낸 날짜를 먼저 씁니다. */
  v_rid := add_receipt(jsonb_build_object(
    'customer_id', v_cust,
    'amount',      v_amt,
    'paid_at',     coalesce(
                     nullif(payload->>'paid_at', ''),
                     to_char(coalesce(v_row.happened_at, v_row.got_at)
                               at time zone 'Asia/Seoul', 'YYYY-MM-DD')),
    'payer',       coalesce(nullif(payload->>'payer', ''), v_row.payer, ''),
    'bank',        coalesce(nullif(payload->>'bank',  ''), v_row.bank,  ''),
    'memo',        btrim(v_head || coalesce(payload->>'memo', '')),
    'staff',       coalesce(actor_name(), ''),
    'allocs',      coalesce(payload->'allocs', '[]'::jsonb)
  ));

  update bank_inbox
     set status = '확정', customer_id = v_cust, receipt_id = v_rid,
         done_by = coalesce(actor_name(), ''), done_at = now(),
         note = nullif(btrim(coalesce(payload->>'memo', '')), '')
   where id = v_id and status = '대기';
  if not found then raise exception '이미 처리된 줄입니다'; end if;

  return jsonb_build_object('ok', true, 'receipt_id', v_rid);
end;
$function$
;

insert into public.app_config (key, value) values ('mig_0233a', to_char(now(), 'YYYY-MM-DD HH24:MI'))
  on conflict (key) do update set value = excluded.value;
commit;


-- ########## 0233b_booltalk_bot ##########
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


-- ########## 0233c_customers_ratelimit ##########
-- ============================================================
-- 0233c  삭제 막기 ③ — 고객 계정·횟수 제한  (보안 겹겹이 #8 #9 #10 #22 #28)
-- 런하는 곳: Supabase SQL Editor  (⚠ 0233a 다음에 — submit_order 는 0233a 판 위에 고칩니다)
-- 되돌리기: 0233c_undo.sql (0233a 판으로 돌아감)   확인: 0233c_check.sql
-- ------------------------------------------------------------
-- 바뀌는 것
--  #22 로그인 없는 견적 요청: 10분에 전체 20건까지. 회원 가입: 1시간에 전체 10건까지.
--      (지난 30일 비회원 견적 52건 = 하루 2건 꼴이라 평소에는 걸리지 않습니다)
--  #28 부일톡 가입코드 틀리기: 10분에 전체 5번까지.
--  #9  비밀번호 찾기 전체 한도(1시간 60회)는 실제로 보낸 것만 셉니다 (막힌 요청이 남의 몫을 깎지 않게).
--  #10 임시 비밀번호로 로그인하면 그 계정의 옛 세션은 모두 끝납니다.
--  #8  회원이 이메일(복구 주소)을 바꾸면 사무실 기록(활동 내역)에 남기고, 화면에 emailChanged 를 돌려줍니다
--      (옛 주소로 안내 메일 보내기는 고객 화면 수정이 따라와야 해서 다음 배포 때).
--  횟수 기록은 새 표 rate_hits 에 남고 하루 지난 줄은 저절로 지워집니다.
-- ============================================================
begin;

create table if not exists public.rate_hits (
  id   bigint generated always as identity primary key,
  kind text not null,
  at   timestamptz not null default now()
);
create index if not exists rate_hits_kind_at on public.rate_hits (kind, at);
alter table public.rate_hits enable row level security;
revoke all on table public.rate_hits from public, anon, authenticated;

-- rate_hit(종류, 기간, 최대, 메시지): 기간 안 횟수가 최대 이상이면
--   메시지가 있으면 예외, 없으면 false. 아니면 한 번 기록하고 true.
create or replace function public.rate_hit(p_kind text, p_window interval, p_max integer, p_msg text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_n integer;
begin
  perform pg_advisory_xact_lock(hashtext('rate_hit_' || p_kind));
  select count(*) into v_n from rate_hits where kind = p_kind and at > now() - p_window;
  if v_n >= p_max then
    if p_msg is not null then raise exception '%', p_msg; end if;
    return false;
  end if;
  insert into rate_hits (kind) values (p_kind);
  delete from rate_hits where at < now() - interval '1 day';
  return true;
end
$$;
revoke all on function public.rate_hit(text, interval, integer, text) from public, anon, authenticated;

-- ── submit_order
CREATE OR REPLACE FUNCTION public.submit_order(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_kind  text := coalesce(nullif(btrim(payload->>'kind'), ''), '발주');
  v_recv  text := coalesce(nullif(btrim(payload->>'recv'), ''), '택배');
  v_pay   text := coalesce(nullif(btrim(payload->>'shipPay'), ''), '착불');
  v_otel  text := left(btrim(coalesce(payload->>'officeTel', '')), 30);
  v_baddr text := left(btrim(coalesce(payload->>'bizAddr', '')), 200);
  v_rname text := left(btrim(coalesce(payload->>'rcvName', '')), 50);
  v_rtel  text := left(btrim(coalesce(payload->>'rcvTel', '')), 30);
  v_fax   text := left(btrim(coalesce(payload->>'fax', '')), 30);
  v_cust  text := btrim(coalesce(payload->>'cust', ''));
  v_bizno text := regexp_replace(coalesce(payload->>'bizno', ''), '[^0-9]', '', 'g');
  v_items jsonb := coalesce(payload->'items', '[]'::jsonb);
  v_tok   text  := coalesce(payload->>'token', '');   -- 0128: 회원 입장권(로그인 때 받음)
  v_scid  bigint;                                      -- 입장권이 가리키는 거래처
  v_login text;                                        -- 0135: 입장권의 아이디
  v_req   bigint := case when coalesce(payload->>'customer_id', '') ~ '^[0-9]+$'
                         then (payload->>'customer_id')::bigint end;   -- 0135: 발주서가 고른 사업장
  v_ord   bigint := case when coalesce(payload->>'orderer_id', '') ~ '^[0-9]+$'
                         then (payload->>'orderer_id')::bigint end;    -- 0179: 주문처(하도업체)
  v_ordn  text;                                                         -- 0179: 주문처 상호
  v_stat  text;
  v_cid   bigint;
  v_oid   bigint;
  v_no    text;
  v_day   text := to_char(now() at time zone 'Asia/Seoul', 'YYYYMMDD');
  v_seq   integer;
  v_line  jsonb;
  v_n     integer := 0;
  v_name  text;
  v_qty   integer;
  v_iid   bigint;            -- 방금 넣은 품목 줄 id (가공을 매달 자리)
  v_procs jsonb;             -- 그 줄에 딸린 가공들
  v_pl    jsonb;
  v_pk    text;
  v_pt    text;
  v_pq    integer;
  v_pn    integer := 0;      -- 받은 가공 줄 수
begin
  if v_kind not in ('발주', '견적') then
    raise exception '주문 종류가 올바르지 않습니다';
  end if;
  /* 0128: 발주는 ① 로그인한 회원(맞는 입장권) 또는 ② 사무실 담당자(관리자 화면,
     auth.uid() 가 있음)만 받습니다. 견적은 전처럼 누구나 됩니다. */
  v_scid  := cust_session_cid(v_tok);
  v_login := cust_session_login(v_tok);                                   -- 0135
  if v_kind = '발주' and v_scid is null and auth.uid() is null then
    raise exception '발주는 로그인한 회원만 할 수 있습니다. 다시 로그인해 주세요 (견적 요청은 로그인 없이도 됩니다)';
  end if;
  if v_recv not in ('택배', '화물', '방문', '직송') then
    v_recv := '택배';
  end if;
  if v_recv = '방문' or v_pay not in ('착불', '현불') then
    v_pay := '착불';
  end if;
  if v_cust = '' then
    raise exception '상호를 적어 주세요';
  end if;
  if length(v_cust) > 100 then
    raise exception '상호가 너무 깁니다';
  end if;
  if v_bizno <> '' and length(v_bizno) <> 10 then
    raise exception '사업자등록번호는 10자리입니다 (예: 123-45-67890)';
  end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception '품목을 하나 이상 담아 주세요';
  end if;
  if jsonb_array_length(v_items) > 200 then
    raise exception '한 번에 200줄까지 넣을 수 있습니다';
  end if;
  /* 0233a(#14): 로그인한 직원 계정이면 사무실만 주문을 넣습니다.
     전에는 창고 계정·역할 없는 계정도 이 길로 주문을 넣고 원장(연락처)을 고칠 수 있었습니다. */
  if auth.uid() is not null then
    perform need_office();
  end if;
  /* 0233c(#22): 로그인 없는 견적은 10분에 전체 20건까지 (지난 30일 비회원 견적 52건 = 하루 2건 꼴) */
  if auth.uid() is null and v_scid is null then
    perform rate_hit('비회원견적', interval '10 minutes', 20,
                     '견적 요청이 잠시 몰려 있습니다. 10분 뒤에 다시 보내 주시거나 032-565-6262 로 전화해 주세요');
  end if;

  /* 0179: 주문처(하도업체)가 오면 — 그 하도업체의 청구처 목록에 있는 곳만.
     주문의 거래처(customer_id)는 청구처(본사업자)입니다. 상호 글자로 찾지 않습니다.
     0180: 사무실뿐 아니라 **회원**도 됩니다 — 주문처가 그 아이디에 연결된 거래처일 때만. */
  if v_ord is not null then
    if auth.uid() is not null then
      perform need_office();
    else
      if v_scid is null
         or not exists (select 1 from cust_allowed_cids(v_login) as t(cid) where t.cid = v_ord) then
        raise exception '이 계정으로 발주할 수 없는 거래처입니다. 다시 로그인해 주세요';
      end if;
      select status into v_stat from customers where id = v_ord;
      if v_kind = '발주' and v_stat = '가입검토' then
        raise exception '사무실에서 가입을 확인한 뒤 발주하실 수 있습니다. 확인이 끝나면 부일산업에서 연락드립니다 (견적 요청은 지금도 됩니다)';
      end if;
    end if;
    if v_req is null then
      raise exception '청구처를 골라 주세요';
    end if;
    if v_req = v_ord then
      raise exception '청구처가 주문처와 같습니다 — 자기 이름으로 받을 때는 주문처를 비워 보내야 합니다';
    end if;
    if not exists (select 1 from customer_bill_to where sub_id = v_ord and bill_id = v_req) then
      raise exception '이 주문처에 등록된 청구처가 아닙니다 — 거래처 관리에서 청구처를 다시 확인해 주세요';
    end if;
    select name into v_ordn from customers where id = v_ord;
    select id into v_cid from customers where id = v_req and merged_into is null;
    if v_cid is null then
      raise exception '청구처가 합쳐졌거나 없습니다 — 거래처 관리에서 다시 확인해 주세요';
    end if;
  /* 0128: 입장권이 있으면 그 거래처입니다 — 보낸 상호 글자로 찾지 않습니다 */
  elsif v_scid is not null then
    v_cid := v_scid;
    /* 0135: 발주서에서 다른 사업장(칩)을 골랐으면 — 이 아이디에 연결된 거래처만 됩니다.
       세션을 바꾸는 방식이 아니라 주문마다 검증합니다(PC·폰·탭 여러 개 동시 사용 안전). */
    if v_req is not null and v_req <> v_scid then
      if not exists (select 1 from cust_allowed_cids(v_login) as t(cid) where t.cid = v_req) then
        raise exception '이 계정으로 발주할 수 없는 거래처입니다. 부일산업(032-565-6262)에 연결을 요청해 주세요';
      end if;
      v_cid := v_req;
    end if;
    /* 0135: 사무실이 아직 본사업자를 연결하지 않은 가입은 견적만 됩니다 */
    select status into v_stat from customers where id = v_cid;
    if v_kind = '발주' and v_stat = '가입검토' then
      raise exception '사무실에서 가입을 확인한 뒤 발주하실 수 있습니다. 확인이 끝나면 부일산업에서 연락드립니다 (견적 요청은 지금도 됩니다)';
    end if;
  else
    select id into v_cid from customers where name = v_cust;
  end if;
  if v_cid is null then
    insert into customers (name, bizno, office_tel, fax, biz_addr,
                           person, tel, email, addr)
    values (v_cust,
            nullif(v_bizno, ''),
            nullif(v_otel, ''),
            nullif(v_fax, ''),
            nullif(v_baddr, ''),
            left(btrim(coalesce(payload->>'person', '')), 50),
            left(btrim(coalesce(payload->>'tel',    '')), 30),
            left(btrim(coalesce(payload->>'email',  '')), 100),
            left(btrim(coalesce(payload->>'addr',   '')), 200))
    returning id into v_cid;
  elsif v_ord is not null then
    /* 0179: 청구처(본사업자) 원장은 건드리지 않습니다 — 폼의 담당자·연락처·배송지는
       하도업체 것이라, 덮으면 본사업자 원장이 하도업체 연락처로 바뀝니다.
       이 주문의 연락처·배송지는 아래 orders 스냅샷에만 들어갑니다. */
    null;
  elsif v_scid is not null then
    /* 0135: 회원 발주는 원장을 덮지 않습니다 — **빈 칸만** 채웁니다.
       전에는 발주할 때마다 폼의 사무실전화·팩스·주소·담당자가 원장을 덮어서,
       한 사람이 A사↔B사를 오가며 발주하면 두 회사 원장이 서로를 덮어썼습니다.
       이 주문의 최신 연락처는 orders 스냅샷에 남고, 원장은 관리자(save_order_cust)로 고칩니다. */
    update customers set
      bizno      = case when v_bizno <> '' and coalesce(btrim(bizno), '') = ''
                        then v_bizno else bizno end,
      office_tel = coalesce(nullif(btrim(office_tel), ''), nullif(v_otel, '')),
      biz_addr   = coalesce(nullif(btrim(biz_addr), ''),   nullif(v_baddr, '')),
      fax        = coalesce(nullif(btrim(fax), ''),        nullif(v_fax, '')),
      person     = coalesce(nullif(btrim(person), ''),
                            nullif(left(btrim(coalesce(payload->>'person', '')), 50), '')),
      tel        = coalesce(nullif(btrim(tel), ''),
                            nullif(left(btrim(coalesce(payload->>'tel',    '')), 30), '')),
      email      = coalesce(nullif(btrim(email), ''),
                            nullif(left(btrim(coalesce(payload->>'email',  '')), 100), '')),
      addr       = coalesce(nullif(btrim(addr), ''),
                            nullif(left(btrim(coalesce(payload->>'addr',   '')), 200), ''))
     where id = v_cid;
  elsif auth.uid() is not null then
    -- 0195: 사무실 담당자가 관리자 화면에서 넣은 주문 — 연락처를 최신 값으로 갱신합니다 (0106 그대로)
    update customers set
      bizno  = case when v_bizno <> '' and coalesce(btrim(bizno), '') = ''
                    then v_bizno else bizno end,
      office_tel = coalesce(nullif(v_otel, ''), office_tel),
      biz_addr = coalesce(nullif(v_baddr, ''), biz_addr),
      fax    = coalesce(nullif(v_fax, ''), fax),
      person = coalesce(nullif(left(btrim(coalesce(payload->>'person', '')), 50), ''), person),
      tel    = coalesce(nullif(left(btrim(coalesce(payload->>'tel',    '')), 30), ''), tel),
      email  = coalesce(nullif(left(btrim(coalesce(payload->>'email',  '')), 100), ''), email),
      addr   = coalesce(nullif(left(btrim(coalesce(payload->>'addr',   '')), 200), ''), addr)
     where id = v_cid;
  else
    /* 0195: 비회원 견적 — 이미 있는 거래처 원장은 **건드리지 않습니다**.
       상호 글자만 같으면 로그인 없이 남의 회사 이메일·전화·주소를 바꿀 수 있었고,
       바뀐 이메일로 비밀번호 찾기를 하면 임시 비밀번호가 그 사람에게 갔습니다.
       빈 칸 채우기도 같은 구멍이라(이메일이 빈 회사) 하지 않습니다.
       이 견적의 연락처는 아래 orders 스냅샷에 그대로 남고, 원장은 사무실이 고칩니다. */
    null;
  end if;

  -- 사업자등록증 첨부 — 비공개 보관함(biz-certs)의 경로만 기억합니다
  -- 0153: 비회원은 원장에 등록증이 **없을 때만** 적습니다 (남의 상호를 적어 견적을 넣으면서
  -- 그 회사의 등록증을 갈아 끼우지 못하게). 0135 로 되돌리며(0152) 이 방어가 같이 빠졌던 것을 되살립니다.
  -- 0179: 주문처가 있으면 폼의 등록증은 하도업체 것이라 청구처 원장에 안 붙입니다.
  if coalesce(btrim(payload->>'cert'), '') <> '' and v_ord is null then
    update customers
       set cert_path = left(btrim(payload->>'cert'), 300),
           cert_at   = now()
     where id = v_cid
       and (v_scid is not null or auth.uid() is not null
            or coalesce(btrim(cert_path), '') = '');
  end if;

  perform pg_advisory_xact_lock(hashtext('order_no_' || v_day));
  select coalesce(max(split_part(order_no, '-', 2)::integer), 0) + 1
    into v_seq
    from orders
   where order_no like v_day || '-%';
  v_no := v_day || '-' || lpad(v_seq::text, 3, '0');

  insert into orders (order_no, customer_id, kind, recv_method, ship_pay,
                      rcv_name, rcv_tel,
                      sender_kind, sender_name, sender_tel, sender_addr,
                      stmt_enclosed,
                      person, tel, email, addr, memo, valid_until,
                      orderer_id, orderer_name)                                  -- 0179
  values (v_no, v_cid, v_kind, v_recv, v_pay,
          nullif(v_rname, ''), nullif(v_rtel, ''),
          case when btrim(coalesce(payload->>'senderKind', '')) in ('부일','주문처','지정')
               then btrim(payload->>'senderKind') else '부일' end,
          nullif(left(btrim(coalesce(payload->>'senderName', '')), 100), ''),
          nullif(left(btrim(coalesce(payload->>'senderTel',  '')),  30), ''),
          nullif(left(btrim(coalesce(payload->>'senderAddr', '')), 200), ''),
          coalesce((payload->>'stmtEnclosed')::boolean, true),
          left(btrim(coalesce(payload->>'person', '')), 50),
          left(btrim(coalesce(payload->>'tel',    '')), 30),
          left(btrim(coalesce(payload->>'email',  '')), 100),
          left(btrim(coalesce(payload->>'addr',   '')), 200),
          left(btrim(coalesce(payload->>'memo',   '')), 1000),
          case when v_kind = '견적'
               then (now() at time zone 'Asia/Seoul')::date + 14 end,
          v_ord, v_ordn)
  returning id into v_oid;

  for v_line in select * from jsonb_array_elements(v_items) loop
    v_name := btrim(coalesce(v_line->>'name', ''));
    if v_name = '' then
      raise exception '품명이 빈 줄이 있습니다';
    end if;
    v_qty := coalesce((v_line->>'qty')::integer, 0);
    if v_qty < 1 or v_qty > 100000 then
      raise exception '% — 수량은 1 이상 100000 이하로 적어 주세요', v_name;
    end if;

    insert into order_items (order_id, item_id, name, size, std, color,
                             qty, orig_qty)
    values (v_oid,
            /* 0191 — 상품 번호가 온 줄만 그 상품에 붙입니다. 번호 없이 품명만 온 줄(직접 입력)은
               품명이 같은 등록상품이 있어도 붙이지 않습니다 — 「말 그대로 직접 입력」(사장님 2026-10-07).
               0011 부터 품명으로 붙여 왔는데, 하계방염복처럼 품명이 같은 상품이 15종이라
               번호가 가장 작은 점퍼에 스판하의 줄이 붙었습니다(20261006-028). */
            (select i.id from items i
              where btrim(i.name) = v_name
                and i.id = (case when (v_line->>'item_id') ~ '^[0-9]+$'
                                 then (v_line->>'item_id')::bigint end)),
            left(v_name, 200),
            left(btrim(coalesce(v_line->>'size', '')), 50),
            nullif(left(btrim(coalesce(v_line->>'std',   '')), 50), ''),
            nullif(left(btrim(coalesce(v_line->>'color', '')), 50), ''),
            v_qty, v_qty)
    returning id into v_iid;
    v_n := v_n + 1;

    v_procs := v_line->'procs';
    if v_procs is not null and jsonb_typeof(v_procs) = 'array' then
      if jsonb_array_length(v_procs) > 20 then
        raise exception '% — 가공은 한 품목에 20줄까지 넣을 수 있습니다', v_name;
      end if;
      for v_pl in select * from jsonb_array_elements(v_procs) loop
        v_pk := btrim(coalesce(v_pl->>'kind', ''));
        v_pt := btrim(coalesce(v_pl->>'text', ''));
        v_pq := coalesce((v_pl->>'qty')::integer, 0);
        if v_pk = '' then
          raise exception '% — 어떤 가공인지 적어 주세요', v_name;
        end if;
        if v_pt = '' then
          raise exception '% % — 무엇을 넣을지 적어 주세요', v_name, v_pk;
        end if;
        if v_pq < 1 or v_pq > 100000 then
          raise exception '% % — 가공 수량은 1 이상 100000 이하로 적어 주세요',
                          v_name, v_pk;
        end if;
        insert into order_item_procs (order_item_id, kind, proc_text, qty)
        values (v_iid, left(v_pk, 40), left(v_pt, 300), v_pq);
        v_pn := v_pn + 1;
      end loop;
    end if;
  end loop;

  insert into order_events (order_id, kind, detail)
  values (v_oid, '주문접수', jsonb_build_object('종류', v_kind, '줄수', v_n,
                                              '수령', v_recv, '가공줄수', v_pn,
                                              '회원', (v_scid is not null),   -- 0128
                                              '주문처', v_ordn));              -- 0179

  /* 0151: 실제로 어느 사업장에 들어갔는지 돌려준다 — 완료 화면이 이 값을 크게 보여 준다.
     ⚠ 회원·사무실이면(자기 거래처) 원장 값을 그대로 준다. 비회원 견적은 자기가 적은
     값만 돌려준다 — 상호 글자로 찾아 붙인 «남의» 거래처의 사업자번호·내부 id 가
     응답에 실려 나가면 상호만 알아도 그 회사 사업자번호를 알아낼 수 있었다(0151). */
  if v_scid is not null or auth.uid() is not null then
    return jsonb_build_object('order_no', v_no, 'lines', v_n, 'procs', v_pn,
                              'customer_id', v_cid,
                              'orderer', v_ordn,                                   -- 0180
                              'cust',  (select cust_typed_name(name) from customers where id = v_cid),
                              'bizno', (select coalesce(bizno, '') from customers where id = v_cid));
  else
    return jsonb_build_object('order_no', v_no, 'lines', v_n, 'procs', v_pn,
                              'customer_id', null,
                              'cust',  v_cust,
                              'bizno', v_bizno);
  end if;
end;
$function$
;

-- ── cust_join
CREATE OR REPLACE FUNCTION public.cust_join(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_id     text := lower(btrim(coalesce(payload->>'loginId', '')));
  v_pw     text := coalesce(payload->>'pw', '');
  v_name   text := left(btrim(coalesce(payload->>'cust', '')), 100);
  v_person text := left(btrim(coalesce(payload->>'person', '')), 50);
  v_tel    text := left(btrim(coalesce(payload->>'tel', '')), 30);
  v_tel2   text := left(btrim(coalesce(payload->>'tel2', '')), 30);
  v_fax    text := left(btrim(coalesce(payload->>'fax', '')), 30);
  v_mail   text := left(btrim(coalesce(payload->>'email', '')), 200);
  v_addr   text := left(btrim(coalesce(payload->>'addr', '')), 200);
  v_bz     text := regexp_replace(coalesce(payload->>'bizno', ''), '[^0-9]', '', 'g');
  v_ceo    text := left(btrim(coalesce(payload->>'ceo', '')), 50);
  v_cert   text := left(btrim(coalesce(payload->>'cert', '')), 300);
  v_cid    bigint;
begin
  if v_id !~ '^[a-z0-9_-]{4,20}$' then
    raise exception '아이디는 영문 소문자·숫자 4~20자로 만들어 주세요';
  end if;
  if length(v_pw) < 6 then
    raise exception '비밀번호는 6자 이상으로 만들어 주세요';
  end if;
  if v_name = '' then
    raise exception '상호를 적어 주세요';
  end if;
  if v_person = '' then
    raise exception '담당자 성함을 적어 주세요';
  end if;
  if length(regexp_replace(v_tel, '[^0-9]', '', 'g')) not between 9 and 11 then
    raise exception '핸드폰 번호를 다시 확인해 주세요';
  end if;
  if v_bz <> '' and length(v_bz) <> 10 then
    raise exception '사업자등록번호는 10자리입니다 (모르면 비워 두세요)';
  end if;
  if v_fax <> '' and
     length(regexp_replace(v_fax, '[^0-9]', '', 'g')) not between 8 and 11 then
    raise exception '팩스 번호를 다시 확인해 주세요 (모르면 비워 두세요)';
  end if;
  if exists (select 1 from customer_accounts where login_id = v_id) then
    raise exception '이미 쓰고 있는 아이디입니다. 다른 아이디를 정해 주세요';
  end if;
  /* 0233c(#22): 가입은 1시간에 전체 10건까지 (거래처 표가 가짜 가입으로 차는 것 막기) */
  perform rate_hit('회원가입', interval '1 hour', 10,
                   '가입 신청이 잠시 몰려 있습니다. 잠시 뒤 다시 해 주시거나 032-565-6262 로 전화해 주세요');

  /* 0135: 상호 글자로 기존 거래처에 잇지 않는다. 「이미 가입된 상호」 검사도 없앤다 —
     같은 회사 두 번째 사람도 여기로 들어와 사무실이 같은 거래처에 연결한다.
     적어 낸 것은 「가입검토」 임시 줄에 그대로 담아 두고, 연결할 때 빈 칸만 옮긴다. */
  insert into customers (name, status, bizno, ceo, person, tel, office_tel, fax,
                         email, addr, cert_path, cert_at)
  values ('[가입검토] ' || v_name || ' (' || v_id || ')', '가입검토',
          nullif(v_bz, ''), nullif(v_ceo, ''), v_person, v_tel,
          nullif(v_tel2, ''), nullif(v_fax, ''),
          nullif(v_mail, ''), nullif(v_addr, ''),
          nullif(v_cert, ''), case when v_cert <> '' then now() end)
  returning id into v_cid;

  insert into customer_accounts (login_id, pass_hash, customer_id)
  values (v_id, crypt(v_pw, gen_salt('bf')), v_cid);

  perform signup_notify(v_id, v_cid);                              -- 0135

  return jsonb_build_object('ok', true,
                            'token', cust_session_new(v_id, v_cid),   -- 0128
                            'pending', true,                          -- 0135
                            'customerId', v_cid,
                            'msg', '가입되었습니다. 사무실에서 확인한 뒤 발주가 열립니다(영업시간 내). '
                                || '견적 요청은 지금도 하실 수 있습니다.');
end;
$function$
;

-- ── register_staff
CREATE OR REPLACE FUNCTION public.register_staff(p_name text, p_dept text, p_code text, p_position text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid();
        v_code text;
        v_mode text;
        v_ok   boolean;
begin
  if v_uid is null then
    return json_build_object('ok', false, 'message', '로그인 상태가 아닙니다.');
  end if;

  if exists (select 1 from chat_users where id = v_uid) then
    return json_build_object('ok', true, 'message', '이미 등록된 직원입니다.');
  end if;

  select value into v_code from app_config where key = 'signup_code';
  if v_code is null or btrim(lower(p_code)) is distinct from btrim(lower(v_code)) then
    /* 0233c(#28): 틀린 코드는 10분에 전체 5번까지만 */
    if not rate_hit('가입코드틀림', interval '10 minutes', 5, null) then
      return json_build_object('ok', false, 'message', '가입코드를 여러 번 틀렸습니다. 10분 뒤에 다시 해 주세요.');
    end if;
    return json_build_object('ok', false, 'message', '가입코드가 올바르지 않습니다. 관리자에게 문의하세요.');
  end if;

  if p_name is null or btrim(p_name) = '' then
    return json_build_object('ok', false, 'message', '이름을 입력해 주세요.');
  end if;

  select coalesce(value, 'code') into v_mode from app_config where key = 'signup_mode';
  v_ok := coalesce(v_mode, 'code') <> 'approve';

  insert into chat_users (id, display_name, dept, position, approved)
  values (v_uid, btrim(p_name), nullif(btrim(coalesce(p_dept, '')), ''),
                                nullif(btrim(coalesce(p_position, '')), ''), v_ok);

  if v_ok then
    insert into room_members (room_id, user_id)
    select r.id, v_uid from rooms r where r.kind = 'group' and r.open_to_all
    on conflict do nothing;
    return json_build_object('ok', true, 'approved', true, 'message', '가입이 완료되었습니다.');
  end if;

  return json_build_object('ok', true, 'approved', false,
    'message', '가입 신청이 접수되었습니다. 관리자 승인 후 사용할 수 있습니다.');
end $function$
;

-- ── cust_pw_reset_issue
CREATE OR REPLACE FUNCTION public.cust_pw_reset_issue(p_login text, p_email text, p_ip text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_id    text := lower(btrim(coalesce(p_login, '')));
  v_mail  text := lower(btrim(coalesce(p_email, '')));
  v_ip    text := left(btrim(coalesce(p_ip, '')), 60);
  v_cid   bigint;
  v_on    boolean;
  v_hit   boolean;
  v_cust  text;
  v_tmp   text := '';
  v_abc   text := 'abcdefghjkmnpqrstuvwxyz23456789';   -- 헷갈리는 0·o·1·l·i 는 뺍니다
  v_b     bytea := gen_random_bytes(8);
  v_log   bigint;
  i       int;
begin
  v_id   := left(v_id, 40);
  v_mail := left(v_mail, 200);

  if (select count(*) from cust_pw_resets
       where login_id = v_id and result <> '바꿈' and at > now() - interval '1 hour') >= 3
     or (v_ip <> '' and (select count(*) from cust_pw_resets
       where ip = v_ip and at > now() - interval '1 hour') >= 10)
     or (select count(*) from cust_pw_resets
       where result = '보냄' and at > now() - interval '1 hour') >= 60 then   -- 0233c(#9): 막힌 요청은 전체 한도에 안 셈
    insert into cust_pw_resets (login_id, email, ip, result) values (v_id, v_mail, v_ip, '막힘');
    return jsonb_build_object('send', false, 'limited', true);
  end if;

  select a.customer_id, a.active into v_cid, v_on
    from customer_accounts a where a.login_id = v_id;

  if v_cid is null then
    insert into cust_pw_resets (login_id, email, ip, result) values (v_id, v_mail, v_ip, '아이디없음');
    return jsonb_build_object('send', false);
  end if;

  with cids as (
    select v_cid as id
    union select c.merged_into from customers c where c.id = v_cid and c.merged_into is not null
    union select l.customer_id from customer_account_links l where l.login_id = v_id
  ), mails as (
    select lower(btrim(m)) as m
      from customers c join cids on cids.id = c.id,
           regexp_split_to_table(coalesce(c.email, ''), '[,;[:space:]]+') m
  )
  select exists (select 1 from mails where m <> '' and m = v_mail) into v_hit;

  if v_mail = '' or not coalesce(v_hit, false) then
    insert into cust_pw_resets (login_id, email, ip, result) values (v_id, v_mail, v_ip, '메일다름');
    return jsonb_build_object('send', false);
  end if;

  if not coalesce(v_on, true) then
    insert into cust_pw_resets (login_id, email, ip, result) values (v_id, v_mail, v_ip, '정지');
    return jsonb_build_object('send', false);
  end if;

  for i in 0..7 loop
    v_tmp := v_tmp || substr(v_abc, (get_byte(v_b, i) % length(v_abc)) + 1, 1);
  end loop;

  update customer_accounts
     set temp_hash  = crypt(v_tmp, gen_salt('bf')),
         temp_until = now() + interval '24 hours'
   where login_id = v_id;

  select cust_typed_name(name) into v_cust from customers where id = v_cid;

  insert into cust_pw_resets (login_id, email, ip, result)
  values (v_id, v_mail, v_ip, '보냄')
  returning id into v_log;

  return jsonb_build_object('send', true, 'logId', v_log, 'to', v_mail,
                            'loginId', v_id, 'cust', coalesce(v_cust, ''), 'temp', v_tmp);
end;
$function$
;

-- ── cust_login
CREATE OR REPLACE FUNCTION public.cust_login(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_id   text := lower(btrim(coalesce(payload->>'loginId', '')));
  v_pw   text := coalesce(payload->>'pw', '');
  v_cid  bigint;
  v_on   boolean;
  v_fail int;
  v_tmp  boolean := false;                     -- 0176: 임시 비밀번호로 들어왔나
begin
  select count(*) into v_fail
    from login_fails
   where login_id = v_id and tried_at > now() - interval '15 minutes';
  if v_fail >= 10 then
    return jsonb_build_object('found', false, 'locked', true,
      'msg', '비밀번호를 여러 번 틀렸습니다. 15분 뒤에 다시 해 주세요.');
  end if;

  select a.customer_id, a.active into v_cid, v_on
    from customer_accounts a
   where a.login_id = v_id
     and a.pass_hash = crypt(v_pw, a.pass_hash);

  /* 0176: 비밀번호가 틀렸으면 메일로 보낸 임시 비밀번호(24시간)인지 봅니다 */
  if v_cid is null then
    select a.customer_id, a.active into v_cid, v_on
      from customer_accounts a
     where a.login_id = v_id
       and a.temp_hash is not null
       and a.temp_until > now()
       and a.temp_hash = crypt(v_pw, a.temp_hash);
    v_tmp := v_cid is not null;
  end if;

  if v_cid is null then
    insert into login_fails (login_id) values (v_id);
    delete from login_fails where tried_at < now() - interval '1 day';
    return jsonb_build_object('found', false);
  end if;

  delete from login_fails where login_id = v_id;

  if not coalesce(v_on, true) then
    return jsonb_build_object('found', false, 'blocked', true,
      'msg', '지금은 쓸 수 없는 계정입니다. 부일산업(032-565-6262)으로 문의해 주세요.');
  end if;

  /* 0176: 임시 비밀번호로 들어왔으면 그것이 이제 비밀번호입니다(옛 것은 끝).
           옛 비밀번호로 들어왔으면 쓰지 않은 임시 비밀번호는 지웁니다. */
  if v_tmp then
    update customer_accounts
       set pass_hash = temp_hash, temp_hash = null, temp_until = null, pw_temp = true
     where login_id = v_id;
    delete from customer_sessions where login_id = v_id;   -- 0233c(#10): 옛 세션은 끝 (새 세션은 아래서 발급)
  else
    update customer_accounts
       set temp_hash = null, temp_until = null
     where login_id = v_id and temp_hash is not null;
  end if;

  return jsonb_build_object(
    'found', true,
    'cust',  (select cust_typed_name(name) from customers where id = v_cid),   -- 0135: 임시 줄은 적은 상호로
    'bizno', (select coalesce(bizno, '') from customers where id = v_cid),
    'token', cust_session_new(v_id, v_cid),     -- 0128
    'mustChange', (select pw_temp from customer_accounts where login_id = v_id)   -- 0176
  ) || cust_autofill(v_cid)
    || cust_login_extra(v_id, v_cid);           -- 0135: pending · customerId · custs
end;
$function$
;

-- ── cust_profile_save
CREATE OR REPLACE FUNCTION public.cust_profile_save(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_login  text := cust_session_login(payload->>'token');
  v_cid    bigint;
  v_pend   boolean;
  v_ceo    text := left(btrim(coalesce(payload->>'ceo', '')), 50);
  v_tel2   text := left(btrim(coalesce(payload->>'officeTel', '')), 30);
  v_fax    text := left(btrim(coalesce(payload->>'fax', '')), 30);
  v_baddr  text := left(btrim(coalesce(payload->>'bizAddr', '')), 200);
  v_person text := left(btrim(coalesce(payload->>'person', '')), 50);
  v_tel    text := left(btrim(coalesce(payload->>'tel', '')), 30);
  v_mail   text := left(btrim(coalesce(payload->>'email', '')), 200);
  v_addr   text := left(btrim(coalesce(payload->>'addr', '')), 200);
  v_part   text;
  v_clean  text := '';
  v_cnt    int := 0;
  v_old    text;      -- 0233c(#8)
  v_cname  text;
begin
  if v_login is null then
    return jsonb_build_object('ok', false, 'msg', '로그인이 풀렸습니다. 다시 로그인해 주세요.');
  end if;
  v_cid := cust_profile_target(v_login,
             case when coalesce(payload->>'customerId', '') ~ '^[0-9]+$'
                  then (payload->>'customerId')::bigint end);
  if v_cid is null then
    return jsonb_build_object('ok', false, 'msg', '이 계정으로 고칠 수 있는 정보가 없습니다.');
  end if;
  select status = '가입검토' into v_pend from customers where id = v_cid;

  /* 가입(cust_join)과 같은 검사 */
  if v_person = '' then
    return jsonb_build_object('ok', false, 'msg', '담당자 성함을 적어 주세요');
  end if;
  if length(regexp_replace(v_tel, '[^0-9]', '', 'g')) not between 9 and 11 then
    return jsonb_build_object('ok', false, 'msg', '핸드폰 번호를 다시 확인해 주세요');
  end if;
  if v_tel2 <> '' and length(regexp_replace(v_tel2, '[^0-9]', '', 'g')) not between 8 and 11 then
    return jsonb_build_object('ok', false, 'msg', '사무실 번호를 다시 확인해 주세요 (모르면 비워 두세요)');
  end if;
  if v_fax <> '' and length(regexp_replace(v_fax, '[^0-9]', '', 'g')) not between 8 and 11 then
    return jsonb_build_object('ok', false, 'msg', '팩스 번호를 다시 확인해 주세요 (모르면 비워 두세요)');
  end if;
  /* 이메일 — 쉼표·세미콜론으로 여러 개. 가입(cust_join)이 저장하던 「a@x.com, b@y.com」 꼴로 맞춘다 */
  for v_part in select btrim(x) from regexp_split_to_table(v_mail, '[,;]') as x loop
    if v_part = '' then continue; end if;
    if v_part !~ '^[^@ ]+@[^@ ]+[.][^@ ]+$' then
      return jsonb_build_object('ok', false, 'msg', '이메일 주소를 다시 확인해 주세요 (' || v_part || ')');
    end if;
    v_cnt := v_cnt + 1;
    v_clean := case when v_clean = '' then v_part else v_clean || ', ' || v_part end;
  end loop;
  if v_cnt = 0 then
    return jsonb_build_object('ok', false, 'msg', '이메일을 적어 주세요');
  end if;
  v_mail := left(v_clean, 200);

  perform cust_profile_reason(v_login);
  select email, name into v_old, v_cname from customers where id = v_cid;

  update customers
     set ceo        = nullif(v_ceo, ''),
         office_tel = nullif(v_tel2, ''),
         fax        = nullif(v_fax, ''),
         biz_addr   = nullif(v_baddr, ''),
         person     = v_person,
         tel        = v_tel,
         email      = v_mail,
         addr       = case when v_pend then nullif(v_addr, '') else addr end
   where id = v_cid;

  /* 0233c(#8): 복구 메일 주소가 바뀌면 사무실 기록에 남기고, 화면에도 알려 옛 주소로 안내 메일을 보내게 합니다 */
  if lower(coalesce(v_old, '')) <> lower(coalesce(v_mail, '')) then
    insert into activity_logs (customer_id, category, kind, title, body, staff, is_manual)
    values (v_cid, '회원', '이메일변경',
            coalesce(v_cname, '거래처') || ' 이메일 바뀜 (회원 ' || v_login || ')',
            '옛 주소: ' || coalesce(v_old, '(없음)') || ' → 새 주소: ' || v_mail, '', false);
    return jsonb_build_object('ok', true, 'msg', '저장했습니다.', 'emailChanged', true, 'oldEmail', coalesce(v_old, ''));
  end if;

  return jsonb_build_object('ok', true, 'msg', '저장했습니다.');
end;
$function$
;

insert into public.app_config (key, value) values ('mig_0233c', to_char(now(), 'YYYY-MM-DD HH24:MI'))
  on conflict (key) do update set value = excluded.value;
commit;


-- ########## 0233d_search_path ##########
-- ============================================================
-- 0233d  함수 경로 고정  (보안 겹겹이 #30, Supabase 자체 점검 「function_search_path_mutable」)
-- 런하는 곳: Supabase SQL Editor   되돌리기: 0233d_undo.sql   확인: 0233d_check.sql
-- ------------------------------------------------------------
-- public 스키마의 우리 함수 가운데 search_path 가 고정되지 않은 것 전부(약 65개)에
-- 「set search_path = public」 을 붙입니다. 함수 내용은 바뀌지 않습니다.
-- (확장(pg_trgm) 이 만든 C 함수는 건너뜁니다. 암호 함수를 쓰는 cust_* 는 이미 'public, extensions' 로 고정돼 있어 해당 없음)
-- ============================================================
begin;
do $$
declare r record; n integer := 0;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
      join pg_language l on l.oid = p.prolang
     where ns.nspname = 'public'
       and l.lanname in ('sql', 'plpgsql')
       and p.prokind = 'f'
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')   -- 확장 소속 제외
       and (p.proconfig is null
            or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
  loop
    execute format('alter function %s set search_path = public', r.sig);
    n := n + 1;
  end loop;
  raise notice '경로 고정한 함수: % 개', n;
end $$;
insert into public.app_config (key, value) values ('mig_0233d', to_char(now(), 'YYYY-MM-DD HH24:MI'))
  on conflict (key) do update set value = excluded.value;
commit;


-- ########## 0233e_sessions ##########
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


-- ########## 0233f_privileges ##########
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


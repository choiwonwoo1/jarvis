-- 0233a 되돌리기 — 0233a 를 런하기 전 모습으로 (함수 4개는 런 전 원본 그대로)
begin;
drop trigger if exists orders_guard_bdu on public.orders;
drop function if exists public.orders_guard();
drop trigger if exists receipt_allocs_guard_biu on public.receipt_allocs;
drop function if exists public.receipt_allocs_guard();

grant execute on function public.ship_take_stock(bigint, text, bigint, text) to authenticated, service_role;
grant execute on function public.ship_give_back_stock(text)                 to authenticated, service_role;
grant execute on function public.ship_check_packer(bigint, text)            to authenticated, service_role;

drop policy if exists "입금 보기"   on public.receipts;
create policy "입금 보기"   on public.receipts       for select to authenticated using ((select is_staff()));
drop policy if exists "배정 보기"   on public.receipt_allocs;
create policy "배정 보기"   on public.receipt_allocs for select to authenticated using ((select is_staff()));
drop policy if exists "폰입금 보기" on public.bank_inbox;
create policy "폰입금 보기" on public.bank_inbox     for select to authenticated using ((select is_staff()));

create policy purchase_orders_write on public.purchase_orders for all to authenticated
  using ((select is_office())) with check ((select is_office()));
create policy purchase_order_items_write on public.purchase_order_items for all to authenticated
  using ((select is_office())) with check ((select is_office()));

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
  perform need_staff();
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
    v_sum := v_sum + coalesce(nullif(v_row->>'amount', '')::integer, 0);
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

  select * into v_row from bank_inbox where id = v_id;
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
   where id = v_id;

  return jsonb_build_object('ok', true, 'receipt_id', v_rid);
end;
$function$
;

delete from public.app_config where key = 'mig_0233a';
commit;

-- 0233c 되돌리기 — 함수 6개를 0233c 런 전(=0233a 판)으로. rate_hits 표는 비워 두고 남겨도 해가 없습니다.
begin;
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
       where result <> '바꿈' and at > now() - interval '1 hour') >= 60 then
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

  return jsonb_build_object('ok', true, 'msg', '저장했습니다.');
end;
$function$
;

drop function if exists public.rate_hit(text, interval, integer, text);
drop table if exists public.rate_hits;
delete from public.app_config where key = 'mig_0233c';
commit;

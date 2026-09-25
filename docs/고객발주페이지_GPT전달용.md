# 부일산업 고객용 발주서 페이지 — 구조 설명 + 리디자인 요청 (GPT 전달용)

## 0. 요청
아래는 우리 회사 **거래처(고객)용 온라인 발주서 페이지**의 현재 구조다.
구조를 먼저 이해한 뒤 **디자인만 새로** 해 달라. 기능·동작은 그대로 유지해야 한다.

## 1. 회사·사용자
- 부일산업㈜: 방염복 제조, 절연화·안전화, 한전 배전공사용 활선·무정전 공구 판매.
- 사용자는 거래처 담당자이고 **50~60대가 많다.** 화면이 조금만 복잡해도 전화로 주문한다.
  → **단순함이 기능보다 우선.** 글씨 크게, 버튼 크게(터치영역 44px 이상), 한 화면에 할 일 하나.
- 품목 약 245개. 모델명(KV-80, BI6-SJ 등)만으로는 구분이 안 돼 **상품 사진이 필수**.
- 휴대폰과 PC 둘 다 쓴다. (모바일 비중 큼)
- 회원가입은 선택. 비회원도 주문 가능.
- 기본적으로 **고객 화면에는 단가가 안 보인다** (관리자 설정 `showPrice`가 켜진 경우에만 금액 표시).

## 2. 기술 구조 (바꾸면 안 되는 것)
- 파일: `v2/public/index.html` **한 파일**(약 3000줄) = 인라인 `<style>`(약 700줄) + HTML 마크업(약 460줄) + 인라인 `<script>`(약 1800줄).
- 외부: `js/config.js`, `js/api.js`(Supabase 연결. `google.script.run` 형태로 감싸져 있음), 글꼴 Pretendard(jsDelivr CDN).
- 프레임워크 없음. 순수 HTML/CSS/바닐라 JS. 빌드 도구 없음. Cloudflare Pages 무료 호스팅.
- **JS가 요소를 `id`로 찾는다** (`$('rName')` 식). → **모든 id, `data-*` 속성(data-kind, data-rv, data-pay, data-s), 버튼 종류는 그대로 둬야 한다.**
- 화면 전환은 JS가 `hidden` 속성을 켜고 끈다. CSS에 `[hidden]{display:none !important}` 가 있어야 한다.
- 입력 오류 표시 클래스: `.bad`(빨간 테두리), `.fmsg`(칸 아래 빨간 안내문). alert 대신 이걸 쓴다.
- 선택 상태 표시: 칩·버튼은 `aria-pressed="true"` 또는 클래스 `.on` 으로 켜진다.
- 반응형 기준: **999px 이하 = 모바일**, **1000px 이상 = PC**. (JS도 `matchMedia('(max-width:999px)')`, `(min-width:1000px)` 를 쓴다)

현재 색상 토큰:
```
--bg:#F5F7FA  --card:#FFFFFF  --ink:#1F2937  --muted:#6B7280  --line:#E5E7EB
--blue:#165DFF  --blue-dk:#0E4285  --amber:#F07D22  --green:#3F9C35  --soft:#F6F9FC  --r:10px
오류색 #C0392B
```

## 3. 페이지 뼈대
```
<header>              로고 + "부일산업(주) 발주서" + 전화번호 (모바일에서 상단 고정)
<main id="app">
  #demo               미리보기 모드 배너
  .phero              PC: 제목 "온라인 발주서 작성" + 단계표시 #hSteps (① 거래처정보 ② 상품선택 ③ 발주확인)
                      모바일: 제목 숨기고 단계 동그라미만
  .pcgrid             PC에서 2단: 왼쪽 .sidebl(회사 소개 카드) + 오른쪽 .content
    .content
      #nav            모바일 상단 진행줄: [← #navBack] #navTitle + #dots(1·2·3)
      #form
        #vStart       시작(로그인/회원가입) 화면
        #vInfo        1단계 고객 정보
        #vItems       2단계 상품 선택
        #vCart        3단계 발주 확인
      #done           제출 완료 화면
#kindAsk              팝업: "발주하기 / 견적 받기" 선택
#pcLayer              팝업: 주소 찾기(다음 우편번호)
#lb                   팝업: 상품 사진 크게 보기(여러 장 넘김)
.bizfoot              회사 사업자정보 푸터
<footer id="bar">     모바일 하단 고정바(2단계에서만): 담은 수량 #tot + [장바구니 보기 #toCart]
```

## 4. 화면별 상세

### 시작 #vStart (관리자 설정이 '회원제'일 때만 나옴)
- **로그인 #gateBox**: 아이디 #loginId, 비밀번호 #loginPw, 오류문 #loginErr, [로그인 #loginGo],
  "또는", [처음이세요? 회원가입하기 #bizJoin], [비회원으로 주문하기 #guestGo]
- **회원가입 #joinBox**: 아이디 #jId, 비번 #jPw, 비번확인 #jPw2, 상호 #jName(필수),
  사업자번호 #jBizno, 대표자 #jCeo, 사무실번호 #jTel2, 팩스 #jFax, 담당자 #jPerson(필수),
  핸드폰 #jTel(필수), 이메일 #jMail + [＋ #jMailAdd](이메일 칸 여러 개, #jMailBox 안에 .mailrow 추가됨),
  기본배송지 #jAddr + [주소 찾기 #jFindAddr], 사업자등록증 첨부 #jCertBtn/#jCertName/#jCertFile,
  오류문 #joinErr, [가입하고 발주 시작하기 #joinGo], [← 돌아가기 #joinBack]

### 1단계 #vInfo — 고객 정보 (카드 3장 + 다음 버튼)
- [← 로그인 화면으로 #backLogin]
- **카드 01 거래처 정보 #rcvCard**
  - 제목 옆 토글 #kindSel: [발주하기 data-kind="발주"] [견적 받기 data-kind="견적"]
  - 상호/이름 #rName(필수), 사업자등록번호 #rBizno(개인은 비움)
  - 사무실 전화 #oTel, 팩스 #oFax
  - 사업자 주소 #bAddr + [주소 찾기 #bFindAddr]
  - 공사명 #pjName, 세금계산서 발행요청일 #taxDate, 세금계산용 메일 #taxMail, 사업자등록증 #certBtn/#certName/#certFile
- **카드 02 담당자 정보**
  - (회원이면) 담당자 고르기 칩 #personChips (＋ 새 담당자 칩은 점선 `.chip.addchip`)
  - 담당자 #pName(필수), 연락처 #pTel(필수), 이메일 #pMail(필수) + 체크 "세금계산서 메일과 동일" #taxSame
- **카드 03 배송 정보** (제목 #sec3t, 받는 방법에 따라 바뀜)
  - 받는 방법 4개 알약버튼 `.rpill` data-rv: **택배 / 화물 / 방문 / 직송** + 설명 #rcvTip
  - 운임 #payWrap: [착불] [현불] `.paybtn` data-pay + 설명 #payTip (방문이면 숨김)
  - 체크 "받는 분이 담당자와 같습니다" #rcvSame → 받는 분 성함 #rcvName, 전화 #rcvTel
  - 배송지 #addrWrap: #rAddr + [주소 찾기 #findAddr], 체크 "사업자 주소와 동일" #bizAddrSame,
    (회원) "기본 배송지와 동일" #addrSame, (회원) 배송지 선택 #addrSel, 안내 #addrTip (방문이면 숨김)
  - 상세주소 #rAddr2 (#addr2Box), 요청사항 #memo(textarea)
  - 개인정보 안내 #reqTip + 개인정보 처리방침 링크
- .nextband: 보안 안내문 + **[다음 단계 — 상품 선택하기 → #next1]**
- 다음을 누르면 필수칸 검사 → 틀린 칸은 `.bad` + `.fmsg` 로 표시 → 통과하면 #kindAsk 팝업(발주/견적 확인) 뒤 2단계로.

### 2단계 #vItems — 상품 선택 (`.card.ipgrid`: PC에서 좌우 2단)
- **왼쪽 .ilist**
  - 탭 #itemTabs (회원: 전체 / 최근 주문 / 자주 주문)
  - 분류 칩 #cats: 전체 / 방염복 / 절연화 및 안전화 / 간접활선 작업용 공구 / 안전장구 / 일반공구 /
    계측기 / 무정전공사 장비&공구 / 전동공구 / 유압공구 / 지중공사용 공구
  - 검색 #q ("품명이나 품번으로 검색")
  - 상품 목록 #items (`.list` 안에 `.row` 가 JS로 그려짐: 사진 썸네일(누르면 확대) · 품번/품명 · 분류·규격(·단가) · 담은 수량 표시)
- **오른쪽 aside.ipick** (모바일에서는 목록 아래/팝업처럼 보임)
  - 안내 #pickHint ("왼쪽 목록에서 상품을 누르면 여기서 사이즈와 수량을 고릅니다")
  - 고른 상품 #pick:
    - #hero (사진 + 품명/품번)
    - 사이즈 #szWrap: 칩 #szs (여러 개 선택 가능, `.chip.sz`) + '기타' 고르면 직접입력 #szEtc
    - 규격 #opStdWrap/#opStds, 색상 #opColorWrap/#opColors(하나만), 형태 #opFormWrap/#opForms + #opFormHint
    - 빠진 필수옵션 경고 #opNeed
    - **조합별 수량표 #szQty** (사이즈×규격×색상×형태 조합마다 한 줄 + 수량 − / +)
    - 단일 수량 #qtyWrap: [− #minus] #qty [+ #plus] (옵션 없는 상품)
    - 인쇄·자수 가공 #pcWrap: 칩 #pcs, 안내 #pcHint, 가공별 문구·수량 #pcQty
    - **[발주서에 담기 #add]**
  - PC 미니 장바구니 #sidecart: "담은 품목 #scCnt" + 목록 #scList + [장바구니 확인 → #scGo]
- 모바일 하단 고정바 #bar: 담은 수량 #tot + [장바구니 보기 #toCart]

### 3단계 #vCart — 발주 확인
- .slip: "담은 품목 #cnt" + 표 (품목 · 사이즈 · 수량 · 삭제×) tbody #cart
- #priceBox (단가 표시 켰을 때만): 상품금액 #pAmt, 배송비, 부가세 #pVat, 합계 #pSum, 안내 #pNote
- 버튼: **[발주서 제출 #send]**, [견적 요청 #quote] (1단계에서 고른 종류 하나만 보임), [← 상품 더 고르기 #backToItems]

### 완료 #done
- ✓ 표시, 제목 #doneTitle ("발주서가 정상적으로 접수되었습니다" / "견적 요청이 접수되었습니다"), 설명 #doneMsg
- 주문번호 #orderNoBox: #orderNoVal(읽기전용) + [복사 #copyNo]
- [새 발주서 쓰기 #again]

## 5. 지금 디자인의 문제 (개선 포인트)
- 1단계 입력칸이 너무 많아 한 화면에 빽빽하다. 필수/선택 구분이 약하다.
- 2단계 PC 좌우 2단은 괜찮지만, 모바일에서 상품을 고른 뒤 사이즈·수량 패널로 가는 흐름이 헷갈린다.
- 사진이 작아 품목 구분이 어렵다.
- 버튼 위계(주 버튼/보조 버튼)가 약하다.
- 전체적으로 "관공서 서식" 느낌. 깔끔하고 믿음 가는 B2B 주문 화면이면 좋겠다.

## 6. 원하는 결과물
1. 먼저 **개선 방향**을 짧게 제안 (모바일/PC 각각, 단계별 레이아웃).
2. 그다음 **새 `<style>` 전체**와, 필요하면 **HTML 마크업 수정본**(`<body>` ~ `<footer id="bar">` 까지)을 준다.
3. 지켜야 할 것:
   - 위에 적은 **id · data-* · 클래스 `.on` `.bad` `.fmsg` `.chip` `.row` `.list` `.add` `.send` `.quote` 이름은 그대로**
   - `<script>`(JS)는 건드리지 않는다. 새 기능 추가 금지.
   - 순수 CSS (Tailwind·Bootstrap 등 라이브러리 금지), 글꼴은 Pretendard 유지.
   - 999px / 1000px 기준 유지. 모바일 터치영역 44px 이상, 본문 글씨 15px 이상.
   - 단가는 기본적으로 안 보이는 전제로 디자인.
   - 색상은 CSS 변수(`:root`)로 정리해서 나중에 바꾸기 쉽게.

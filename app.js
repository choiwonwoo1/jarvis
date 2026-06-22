const chat = document.getElementById("chat");
const listenBtn = document.getElementById("listenBtn");
const stopBtn = document.getElementById("stopBtn");
const clearBtn = document.getElementById("clearBtn");
const sendBtn = document.getElementById("sendBtn");
const textInput = document.getElementById("textInput");
const statusDot = document.getElementById("statusDot");
const statusText = document.getElementById("statusText");
const memoList = document.getElementById("memoList");
const orb = document.getElementById("orb");

let recognition = null;
let memos = JSON.parse(localStorage.getItem("jarvis_memos") || "[]");

function addMsg(role, text) {
  const div = document.createElement("div");
  div.className = `msg ${role}`;
  div.textContent = text;
  chat.appendChild(div);
  chat.scrollTop = chat.scrollHeight;
}

function speak(text) {
  if (!("speechSynthesis" in window)) return;
  speechSynthesis.cancel();

  const utter = new SpeechSynthesisUtterance(text);
  utter.lang = "ko-KR";
  utter.rate = 1.02;
  speechSynthesis.speak(utter);
}

function setStatus(active, text) {
  statusDot.classList.toggle("on", active);
  orb.classList.toggle("listening", active);
  statusText.textContent = text;
}

function renderMemos() {
  memoList.innerHTML = "";
  memos.forEach((m, i) => {
    const li = document.createElement("li");
    li.textContent = `${i + 1}. ${m}`;
    memoList.appendChild(li);
  });
}

function saveMemo(text) {
  memos.unshift(text);
  memos = memos.slice(0, 30);
  localStorage.setItem("jarvis_memos", JSON.stringify(memos));
  renderMemos();
}

function safeCalc(expression) {
  const cleaned = expression
    .replaceAll("더하기", "+")
    .replaceAll("플러스", "+")
    .replaceAll("빼기", "-")
    .replaceAll("마이너스", "-")
    .replaceAll("곱하기", "*")
    .replaceAll("나누기", "/")
    .replace(/[^0-9+\-*/().\s]/g, "");

  if (!cleaned.trim()) return null;

  try {
    const result = Function(`"use strict"; return (${cleaned})`)();
    if (!Number.isFinite(result)) return null;
    return `${expression.trim()} = ${result.toLocaleString()}`;
  } catch {
    return null;
  }
}

function handleCommand(raw) {
  const original = raw.trim();
  const text = original.replace(/^자비스[, ]*/i, "").trim();

  addMsg("user", original);

  let response = "";

  if (!text) {
    response = "네, 말씀해주세요.";
  } else if (text.includes("메모")) {
    const memo = text.replace("메모", "").replace("해줘", "").trim();

    if (memo) {
      saveMemo(memo);
      response = `메모했습니다. ${memo}`;
    } else {
      response = "메모할 내용을 같이 말해주세요.";
    }
  } else if (text.includes("메모 보여") || text.includes("메모 목록")) {
    response = memos.length
      ? "저장된 메모입니다.\n" + memos.map((m, i) => `${i + 1}. ${m}`).join("\n")
      : "저장된 메모가 없습니다.";
  } else if (text.includes("계산") || /[0-9]/.test(text)) {
    const result = safeCalc(text.replace("계산해줘", "").replace("계산", ""));
    response = result || "계산식을 숫자와 더하기, 빼기, 곱하기, 나누기로 말해주세요.";
  } else if (text.includes("안녕")) {
    response = "안녕하세요. 모바일 자비스 준비됐습니다.";
  } else if (text.includes("도움") || text.includes("뭐 할 수")) {
    response = `현재 가능한 기능입니다.

1. 메모 저장
2. 메모 목록 확인
3. 간단 계산
4. 음성으로 답변

예시:
자비스, 메모 태양광 견적 확인
자비스, 1502 나누기 30 계산해줘`;
  } else {
    response = `아직 연결되지 않은 명령입니다.

지금 가능한 명령:
- 자비스, 메모 내용
- 자비스, 메모 보여줘
- 자비스, 1502 나누기 30 계산해줘`;
  }

  addMsg("bot", response);
  speak(response.split("\n")[0]);
}

function setupSpeech() {
  const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;

  if (!SpeechRecognition) {
    addMsg("bot", "이 브라우저는 음성 인식을 지원하지 않습니다. Android Chrome에서 실행해보세요. iPhone은 브라우저 음성 인식 지원이 제한될 수 있습니다.");
    return;
  }

  recognition = new SpeechRecognition();
  recognition.lang = "ko-KR";
  recognition.continuous = false;
  recognition.interimResults = false;

  recognition.onstart = () => setStatus(true, "듣는 중");
  recognition.onend = () => setStatus(false, "대기 중");
  recognition.onerror = () => setStatus(false, "오류");
  recognition.onresult = (event) => {
    const text = event.results[0][0].transcript;
    handleCommand(text);
  };
}

listenBtn.addEventListener("click", () => {
  if (!recognition) setupSpeech();
  if (recognition) recognition.start();
});

stopBtn.addEventListener("click", () => {
  if (recognition) recognition.stop();
  if ("speechSynthesis" in window) speechSynthesis.cancel();
  setStatus(false, "대기 중");
});

clearBtn.addEventListener("click", () => {
  chat.innerHTML = "";
});

sendBtn.addEventListener("click", () => {
  const value = textInput.value.trim();
  if (!value) return;
  handleCommand(value);
  textInput.value = "";
});

textInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") sendBtn.click();
});

document.querySelectorAll(".chip").forEach(btn => {
  btn.addEventListener("click", () => handleCommand(btn.textContent));
});

renderMemos();
addMsg("bot", "모바일 자비스가 준비됐습니다. 버튼을 누르고 말하거나 직접 입력해보세요.");

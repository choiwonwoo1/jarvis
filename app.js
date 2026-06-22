const chat=document.getElementById("chat");
const listenBtn=document.getElementById("listenBtn");
const stopBtn=document.getElementById("stopBtn");
const clearBtn=document.getElementById("clearBtn");
const sendBtn=document.getElementById("sendBtn");
const textInput=document.getElementById("textInput");
const memoList=document.getElementById("memoList");
const calcInput=document.getElementById("calcInput");
const calcBtn=document.getElementById("calcBtn");
const calcResult=document.getElementById("calcResult");
const deleteMemoBtn=document.getElementById("deleteMemoBtn");
const voiceStatus=document.getElementById("voiceStatus");
const footerStatus=document.getElementById("footerStatus");
const wave=document.querySelector(".wave");
const timeText=document.getElementById("timeText");
const dateText=document.getElementById("dateText");
const cpu=document.getElementById("cpu");
const mem=document.getElementById("mem");

let recognition=null;
let memos=JSON.parse(localStorage.getItem("jarvis_memos")||"[]");

function tick(){
  const d=new Date();
  timeText.textContent=d.toLocaleTimeString("ko-KR",{hour12:false});
  dateText.textContent=d.toLocaleDateString("ko-KR",{year:"numeric",month:"2-digit",day:"2-digit",weekday:"short"});
  cpu.textContent=(14+Math.floor(Math.random()*12))+"%";
  mem.textContent=(29+Math.floor(Math.random()*10))+"%";
}
setInterval(tick,1000); tick();

function addMsg(role,text){
  const div=document.createElement("div");
  div.className=`msg ${role}`;
  div.textContent=text;
  chat.appendChild(div);
  chat.scrollTop=chat.scrollHeight;
}
function speak(text){
  if(!("speechSynthesis" in window)) return;
  speechSynthesis.cancel();
  const u=new SpeechSynthesisUtterance(text);
  u.lang="ko-KR";
  u.rate=1.02;
  speechSynthesis.speak(u);
}
function setListening(on){
  listenBtn.classList.toggle("listening",on);
  wave.classList.toggle("listening-wave",on);
  voiceStatus.textContent=on?"LISTENING":"STANDBY";
  footerStatus.textContent=on?"음성 명령을 듣고 있습니다":"명령을 기다리고 있습니다";
}
function renderMemos(){
  memoList.innerHTML="";
  memos.forEach((m,i)=>{
    const li=document.createElement("li");
    li.textContent=`${i+1}. ${m}`;
    memoList.appendChild(li);
  });
}
function saveMemo(text){
  memos.unshift(text);
  memos=memos.slice(0,50);
  localStorage.setItem("jarvis_memos",JSON.stringify(memos));
  renderMemos();
}
function safeCalc(expression){
  const cleaned=expression
    .replaceAll("더하기","+").replaceAll("플러스","+")
    .replaceAll("빼기","-").replaceAll("마이너스","-")
    .replaceAll("곱하기","*").replaceAll("나누기","/")
    .replace(/[^0-9+\-*/().\s]/g,"");
  if(!cleaned.trim()) return null;
  try{
    const result=Function(`"use strict"; return (${cleaned})`)();
    if(!Number.isFinite(result)) return null;
    return `${expression.trim()} = ${result.toLocaleString()}`;
  }catch{return null}
}
function handleCommand(raw){
  const original=raw.trim();
  const body=original.replace(/^자비스[, ]*/i,"").trim();
  addMsg("user",original);
  let response="";
  if(!body){
    response="네, 말씀해주세요.";
  }else if(body.includes("메모 보여")||body.includes("메모 목록")){
    response=memos.length?"저장된 메모입니다.\n"+memos.map((m,i)=>`${i+1}. ${m}`).join("\n"):"저장된 메모가 없습니다.";
  }else if(body.includes("메모")){
    const memo=body.replace("메모","").replace("해줘","").trim();
    if(memo){saveMemo(memo);response=`메모했습니다. ${memo}`;}
    else response="메모할 내용을 같이 말해주세요.";
  }else if(body.includes("계산")||/[0-9]/.test(body)){
    const result=safeCalc(body.replace("계산해줘","").replace("계산",""));
    response=result||"계산식을 숫자와 더하기, 빼기, 곱하기, 나누기로 말해주세요.";
  }else if(body.includes("안녕")){
    response="안녕하세요. 자비스 시스템 온라인입니다.";
  }else if(body.includes("도움")||body.includes("뭐 할 수")){
    response="현재 가능한 기능입니다.\n\n1. 메모 저장\n2. 메모 목록 확인\n3. 간단 계산\n4. 음성 답변\n5. 노트북/핸드폰 반응형 화면";
  }else{
    response="아직 연결되지 않은 명령입니다.\n\n가능한 명령:\n- 자비스, 메모 내용\n- 자비스, 메모 보여줘\n- 자비스, 1502 나누기 30 계산해줘";
  }
  addMsg("bot",response);
  speak(response.split("\n")[0]);
}
function setupSpeech(){
  const SpeechRecognition=window.SpeechRecognition||window.webkitSpeechRecognition;
  if(!SpeechRecognition){
    addMsg("bot","이 브라우저는 음성 인식을 지원하지 않습니다. PC Chrome 또는 Android Chrome에서 열어보세요.");
    return;
  }
  recognition=new SpeechRecognition();
  recognition.lang="ko-KR";
  recognition.continuous=false;
  recognition.interimResults=false;
  recognition.onstart=()=>setListening(true);
  recognition.onend=()=>setListening(false);
  recognition.onerror=()=>setListening(false);
  recognition.onresult=e=>handleCommand(e.results[0][0].transcript);
}
listenBtn.addEventListener("click",()=>{if(!recognition)setupSpeech();if(recognition)recognition.start();});
stopBtn.addEventListener("click",()=>{if(recognition)recognition.stop();if("speechSynthesis" in window)speechSynthesis.cancel();setListening(false);});
clearBtn.addEventListener("click",()=>chat.innerHTML="");
sendBtn.addEventListener("click",()=>{const v=textInput.value.trim();if(!v)return;handleCommand(v);textInput.value="";});
textInput.addEventListener("keydown",e=>{if(e.key==="Enter")sendBtn.click();});
calcBtn.addEventListener("click",()=>{const r=safeCalc(calcInput.value);calcResult.textContent=r||"계산식을 다시 입력해주세요.";});
deleteMemoBtn.addEventListener("click",()=>{memos=[];localStorage.removeItem("jarvis_memos");renderMemos();addMsg("bot","메모를 모두 삭제했습니다.");});
document.querySelectorAll(".chip").forEach(btn=>btn.addEventListener("click",()=>handleCommand(btn.textContent)));
renderMemos();
addMsg("bot","JARVIS HUD 웹앱이 준비됐습니다. 중앙 코어를 누르거나 명령어를 입력하세요.");

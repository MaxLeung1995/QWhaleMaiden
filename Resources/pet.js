"use strict";
const $=s=>document.querySelector(s);
const post=body=>window.webkit?.messageHandlers?.starbud?.postMessage(body);
let state={settings:{},activity:"idle"},mode="idle",transientUntil=0,transient="idle",lastInteract=Date.now(),menuOpen=false,forcedSleep=false;
let dragging=false,press=null,trail=[],pending={x:0,y:0},spring={x:0,y:0},flight=null,raf=0,lastFrame=0,walkUntil=0,walkDirection=1,moreOpen=false,menuTimer=0,widgetsExpanded=false,actionPending=false,lastMenuAction="",lastMenuActionAt=0;
let nativeMoving=false,menuBlockedUntil=0,queuedWalk=false,fleeing=false;
window.onPetAnimationEnded=()=>{if(state.edgeQuiet||!queuedWalk||mode!=="idle"||forcedSleep||dragging||press||nativeMoving||menuOpen||!state.settings.walk||state.settings.reducedMotion||state.activity!=="idle")return false;queuedWalk=false;post({type:"nativeWalk"});setTimeout(()=>{if(!nativeMoving)DSHPet.resumeIdle()},300);return true};
let lockedBubble=null,lastBubble=null,localLineTimer=0,packSignature="",spriteFrame=0,spriteColumns=1,lastSprite=0;
const chatterBags=new Map();
function line(group){let bag=chatterBags.get(group)||[];if(!bag.length)bag=[...(state.chatter?.[group]||state.chatter?.idle||["我在这儿陪着你。"])].sort(()=>Math.random()-.5);const text=bag.pop();chatterBags.set(group,bag);return text}
function local(text){if(!$("#notice").hidden)return;$("#localLine").textContent=text;$("#localLine").hidden=false;clearTimeout(localLineTimer);localLineTimer=setTimeout(()=>{$("#localLine").hidden=true;regions()},2300);regions()}
function burst(name,ms=2400){transient=name;transientUntil=Date.now()+(state.pack?ms:Math.max(ms,10000));lastInteract=Date.now();forcedSleep=false;updateMode()}
function stopMotion(){post({type:"stopMotion"});flight=null;pending={x:0,y:0};spring={x:0,y:0};walkUntil=0}
function loop(time){
 raf=0;lastFrame=time;
 try{updateSprite(time)}catch(error){post({type:"runtimeDiagnostic",event:"js_error",message:String(error)})}
 if(state.pack?.manifest.renderer==="spritesheet"&&!state.settings.reducedMotion)raf=requestAnimationFrame(loop);
}
function startLoop(){if(!raf){lastFrame=0;raf=requestAnimationFrame(loop)}}
function regions(){
 const head=$(state.pack?"#customArt":"#pet").getBoundingClientRect();$("#stage").style.setProperty("--pet-center",(head.x+head.width/2)+"px");$("#stage").style.setProperty("--speech-bottom",(innerHeight-head.top+8)+"px");
 const view=state.overlayViewport||{left:0,right:innerWidth,top:0,bottom:innerHeight},stage=$("#stage");
 let controlEdge=head.bottom+34;if(controlEdge>view.bottom-8)controlEdge=head.top-6;
 controlEdge=Math.max(view.top+(moreOpen?248:28)+8,Math.min(controlEdge,view.bottom-8));stage.style.setProperty("--controls-bottom",(innerHeight-controlEdge)+"px");
 const width=Math.max($("#notice").getBoundingClientRect().width,$("#localLine").getBoundingClientRect().width,1),center=head.x+head.width/2;
 stage.style.setProperty("--notice-center",Math.max(view.left+width/2+8,Math.min(center,view.right-width/2-8))+"px");
 const selectors=[state.pack?"#customArt":"#pet","#notice:not([hidden])","#petMenu:not([hidden])","#morePanel:not([hidden])"];
 const rects=selectors.map(s=>$(s)).filter(Boolean).map(el=>{const r=el.getBoundingClientRect();return{x:r.x,y:r.y,w:r.width,h:r.height}});
 post({type:"hitRegions",rects});
 const menuRects=["#petMenu:not([hidden])","#morePanel:not([hidden])"].map(s=>$(s)).filter(Boolean).map(el=>{const r=el.getBoundingClientRect();return{x:r.x,y:r.y,w:r.width,h:r.height}});post({type:"menuRegions",rects:menuRects});
}
function updateMode(){
 const userAction=Date.now()<transientUntil&&["eat","play","joy","wake","dragRelease","preview"].includes(transient);let next=dragging?"drag":state.edgeQuiet?"edgeQuiet":userAction?transient:forcedSleep?"sleep":Date.now()<walkUntil?"walk":state.activity!=="idle"?state.activity:Date.now()<transientUntil?transient:"idle";
 if(next!==mode){$("#stage").classList.remove("mode-"+mode);mode=next;$("#stage").classList.add("mode-"+mode);document.body.dataset.mode=mode;applyPack();regions()}
}
function packAction(){const m=state.pack?.manifest;return m?(m.actions[mode]||m.actions.idle):null}
function applyPack(){
 const pack=state.pack,a=packAction(),signature=pack?pack.id+":"+a.file: "builtin";
 if(signature===packSignature){if(!pack)DSHPet.set(mode,!!state.settings.reducedMotion);return;}packSignature=signature;$("#art").hidden=!!pack;$("#customArt").hidden=!pack;
 const el=$("#customArt");el.replaceChildren();el.style.backgroundImage="none";
 if(!pack){DSHPet.set(mode,!!state.settings.reducedMotion);regions();return}DSHPet.stop();const url="starbud-asset://local/"+pack.id+"/"+a.file;
 const image=new Image();image.onerror=()=>post({type:"motionError"});
 if(pack.manifest.renderer==="svg"){image.src=url;el.append(image);image.onload=regions}
 else{image.onload=()=>{spriteColumns=Math.floor(image.naturalWidth/a.frameWidth);el.style.backgroundImage=`url("${url}")`;el.style.backgroundSize=`${image.naturalWidth/a.frameWidth*el.clientWidth}px ${image.naturalHeight/a.frameHeight*(el.clientWidth*a.frameHeight/a.frameWidth)/a.frameHeight}px`;el.style.height=el.clientWidth*a.frameHeight/a.frameWidth+"px";spriteFrame=0;startLoop();regions()};image.src=url}
}
function updateSprite(time){const pack=state.pack,a=packAction();if(!pack||pack.manifest.renderer!=="spritesheet"||!a)return;if(time-lastSprite<1000/a.fps)return;lastSprite=time;const el=$("#customArt");spriteFrame=state.settings.reducedMotion?0:(spriteFrame+1)%a.frames;if(spriteFrame===0&&mode==="idle")window.onPetAnimationEnded();const w=el.clientWidth,h=w*a.frameHeight/a.frameWidth;el.style.backgroundPosition=`${-(spriteFrame%spriteColumns)*w}px ${-Math.floor(spriteFrame/spriteColumns)*h}px`}
const noticeMeasure=document.createElement("canvas").getContext("2d");
function sizeAgentNotice(){
 const notice=$("#notice");if(notice.dataset.kind!=="agent")return;
 const text=$("#noticeText"),font=getComputedStyle(text),body=getComputedStyle($("#noticeBody"));
 noticeMeasure.font=font.font||`${font.fontWeight} ${font.fontSize} ${font.fontFamily}`;
 const needed=Math.ceil(noticeMeasure.measureText(text.textContent).width+parseFloat(body.paddingLeft)+parseFloat(body.paddingRight)+4);
 notice.style.setProperty("--agent-width",Math.max(170,Math.min(260,needed))+"px");
}
window.render=function(next){state=next;const half=111.158*(state.settings.size||1)/2;$("#stage").classList.toggle("menus-right",!!state.menusOnRight);$("#stage").style.setProperty("--pet-center",(260+Math.max(66,half))+"px");$("#art").style.setProperty("--pet-scale",state.settings.size||1);$("#customArt").style.width=132*(state.settings.size||1)+"px";document.body.classList.toggle("reduced",!!state.settings.reducedMotion);if(state.settings.reducedMotion||!state.settings.walk){queuedWalk=false;if(!fleeing||state.settings.reducedMotion)walkUntil=0;if(state.settings.reducedMotion)stopMotion()}
 if(state.edgeQuiet){queuedWalk=false;closeBar();$("#localLine").hidden=true}const bubble=state.edgeQuiet?null:state.bubble;lastBubble=bubble;
 $("#notice").hidden=!bubble;$("#notice").dataset.kind=bubble?.agent?"agent":["focus","rest","water"].includes(bubble?.category)?"wellness":bubble?.category==="whisper"?"whisper":"reminder";
 if(bubble){$("#localLine").hidden=true;$("#noticeSource").textContent=bubble.title;$("#noticeText").textContent=bubble.summary;$("#position").textContent=state.count>1?`${state.index}/${state.count}`:"";$("#prev").hidden=$("#next").hidden=state.count<=1;$("#noticeBody").title=bubble.agent?"前往 "+bubble.title.split(" · ")[0]:"查看提醒";$("#later").hidden=bubble.category!=="waiting"&&!["rest","water"].includes(bubble.category);$("#later").title=bubble.category==="waiting"?"30 分钟后再提醒":"10 分钟后再提醒"}
 const wellness=["focus","rest","water"].includes(bubble?.category);$("#ackReminder").hidden=!wellness;
 if(wellness){$("#ackReminder").textContent=bubble.id.startsWith("preview-reminder:")?"知道啦":bubble.category==="focus"?"查看番茄钟":bubble.category==="rest"?"已休息":"喝过啦";$("#later").textContent="稍后 10 分钟";$("#noticeBody").title="确认这条提醒"}else $("#later").textContent="稍后";
 sizeAgentNotice();updateMode();applyPack();renderControls();regions();};
window.command=function({name,action,dragged,flung,direction,remaining,token,flee}){
 if(name==="revealPetMenu"){if(!press&&!dragging&&!nativeMoving&&Date.now()>=menuBlockedUntil)revealBar();return}
 if(name==="nativeMotionStarted"){queuedWalk=false;nativeMoving=true;closeBar();return}
 if(name==="reminderFeedback"){if(!nativeMoving&&!dragging&&!forcedSleep&&!state.settings.reducedMotion&&state.activity==="idle"&&!state.pack){transient="preview";transientUntil=Date.now()+10000;DSHPet.preview(action);lastInteract=Date.now();}return}
 if(name==="nativeWalkDirection"){queuedWalk=false;fleeing=!!flee;forcedSleep=false;transientUntil=0;if(token!==undefined)DSHPet.setWalkToken(token);if(flee)local(["哎呀别戳啦，先跑为敬～","好啦好啦，去那边玩咯～","戳够了嘛，先走一步！"][Math.floor(Math.random()*3)]);walkDirection=direction<0?-1:1;walkUntil=Infinity;$("#stage").style.setProperty("--walk-facing",walkDirection);DSHPet.setRunDirection(walkDirection);updateMode();if(state.pack)post({type:"walkAnimationReady",token});return}

 if(name==="nativeDragStarted"){nativeMoving=true;closeBar();dragging=true;burst("drag");local(line("drag"));return}
 if(name==="nativeRelease"){nativeMoving=!!flung;menuBlockedUntil=Date.now()+700;dragging=false;press=null;closeBar();lastInteract=Date.now();if(dragged){burst("dragRelease",1500);local(line("release"))}else{burst("joy",1000);local(line("touch"))}regions();return}
 if(name==="nativeMotionStopped"){nativeMoving=false;menuBlockedUntil=Date.now()+700;closeBar();dragging=false;press=null;walkUntil=0;fleeing=false;updateMode();regions();return}
if(name==="dismissUI"){closeBar();return;}if(name==="speak"){if(!forcedSleep&&state.activity==="idle")burst("whisper",10000);return;}if(name==="builtinAction"){if(!state.pack){transient="preview";transientUntil=Date.now()+12000;DSHPet.preview(action);lastInteract=Date.now();}return;}if(name==="sleep"){queuedWalk=false;stopMotion();transientUntil=0;forcedSleep=true;lastInteract=0;updateMode();local(line("sleep"))}else if(name==="wake"){burst("wake");local(line("wake"))}else if(name==="celebrate"||name==="error"){burst(name,name==="error"?2500:3000)}else if(name==="pauseMotion"){stopMotion();post({type:"busy",value:false})}else if(name==="walk"&&state.settings.walk&&!state.settings.reducedMotion&&!dragging&&!menuOpen&&!forcedSleep&&!nativeMoving){queuedWalk=true;if(state.pack?.manifest.renderer==="svg")window.onPetAnimationEnded()}};
function showBar(){if(state.edgeQuiet||press||dragging||nativeMoving||Date.now()<menuBlockedUntil)return;post({type:"requestPetMenu"})}
function revealBar(){clearTimeout(menuTimer);menuOpen=true;$("#petMenu").hidden=false;regions()}
function closeMore(restore=true){if(moreOpen)post({type:"menuFocus",active:false});moreOpen=false;$("#morePanel").hidden=true;$("#controlsButton").setAttribute("aria-expanded","false");if(restore)$("#controlsButton").focus();regions()}
function afterMenuAction(name,fn){closeBar();actionPending=true;setTimeout(()=>{actionPending=false;lastMenuAction=name;lastMenuActionAt=Date.now();fn();regions()},500)}
function closeBar(){clearTimeout(menuTimer);closeMore(false);menuOpen=false;$("#petMenu").hidden=true;regions()}
function laterHide(){clearTimeout(menuTimer);menuTimer=setTimeout(()=>{if(!moreOpen&&!document.activeElement?.closest("#petMenu")&&!document.querySelector("#petMenu:hover,#pet:hover"))closeBar()},1600)}
function selectMore(tab){document.querySelectorAll("[data-more-tab]").forEach(b=>{const on=b.dataset.moreTab===tab;b.setAttribute("aria-selected",String(on));b.tabIndex=on?0:-1});document.querySelectorAll("[data-more-page]").forEach(p=>p.hidden=p.dataset.morePage!==tab);regions()}
function renderInlineWidgets(){
 $("#miniFocusContent").hidden=widgetsExpanded;$("#miniWidgets").hidden=!widgetsExpanded;$("#toggleWidgets").setAttribute("aria-expanded",String(widgetsExpanded));
 const w=state.weather,city=w?.city||state.settings.city?.name,description=code=>code===0?"晴":code<=3?"多云":code<=48?"雾":code<=67?"雨":code<=77?"雪":code<=82?"阵雨":code<=86?"阵雪":"雷雨";
 $("#miniWeatherSummary").textContent=w?`${city} · ${Math.round(w.temperature)}°C · ${description(w.code)}`:city?city+" · 天气待更新":"尚未设置天气城市";
 $("#miniWeatherMeta").textContent=w?(Date.now()/1000-w.fetchedAt>1800?"缓存天气 · ":"")+"更新于 "+new Date(w.fetchedAt*1000).toLocaleTimeString("zh-CN",{hour:"2-digit",minute:"2-digit"}):state.weatherError?"天气暂不可用，请稍后再试":"在全部设置中选择城市";
 const now=new Date(),start=new Date(now.getFullYear(),now.getMonth(),now.getDate()),end=new Date(now.getFullYear(),now.getMonth(),now.getDate()+1);
 const today=(state.calendar||[]).filter(e=>e.start*1000<end.getTime()&&(e.end*1000>start.getTime()||e.start*1000>=start.getTime())).sort((a,b)=>(b.allDay?1:0)-(a.allDay?1:0)||a.start-b.start);
 $("#miniCalendarDate").textContent=now.toLocaleDateString("zh-CN",{month:"numeric",day:"numeric",weekday:"short"})+" · 今日日历 ↗";
 const host=$("#miniCalendarItems");host.replaceChildren();for(const e of today.slice(0,2)){const row=document.createElement("div");row.textContent=(e.allDay?"全天":e.start*1000<start.getTime()?"跨日":new Date(e.start*1000).toLocaleTimeString("zh-CN",{hour:"2-digit",minute:"2-digit"}))+" · "+e.title;host.append(row)}
 if(!today.length){const row=document.createElement("div");row.className="calendar-empty";row.textContent=state.settings.calendarEnabled?(state.calendarStatus&&!state.calendarStatus.startsWith("只读")?state.calendarStatus:"今天暂无日程"):"尚未连接系统日历";host.append(row)}else if(today.length>2){const row=document.createElement("div");row.className="calendar-empty";row.textContent="还有 "+(today.length-2)+" 项，点击查看";host.append(row)}
 $("#inlineWidgetSettings").hidden=!!city&&!!state.settings.calendarEnabled;
}
$("#toggleWidgets").onclick=()=>{widgetsExpanded=!widgetsExpanded;renderInlineWidgets();regions()};
$("#miniCalendar").onclick=()=>afterMenuAction("calendar",()=>post({type:"openCalendar"}));
function renderControls(){renderInlineWidgets();const rem=state.reminders||{},active=["running","paused"].includes(rem.focusMode);$("#focusToggle").textContent=active?"关闭番茄钟":"开始番茄钟";$("#focusToggle").classList.toggle("active",active);const left=Math.max(0,Math.ceil(rem.focusRemaining??2700)),clock=String(Math.floor(left/60)).padStart(2,"0")+":"+String(left%60).padStart(2,"0");$("#focusToggle").title=active?"剩余 "+clock+" · 点击结束":"开始 45 分钟专注";$("#miniClock").textContent=clock;$("#miniFocusState").textContent=(rem.focusPhase==="break"?"休息":"专注")+({running:"进行中",paused:"已暂停",finished:"已完成",stopped:"未开始"}[rem.focusMode]||"未开始");$("#pauseQuick").textContent=rem.focusMode==="paused"?"继续":"暂停";$("#pauseQuick").dataset.quickFocus=rem.focusMode==="paused"?"resume":"pause";$("#pauseQuick").disabled=!active;$("#sleepToggle").dataset.pet=forcedSleep?"wake":"sleep";$("#sleepToggle").innerHTML=forcedSleep?"唤醒<span>醒来活动一下</span>":"打个盹<span>安静休息一会儿</span>";document.querySelectorAll("[data-pet-setting]").forEach(e=>e.checked=!!state.settings[e.dataset.petSetting]);}
$("#focusToggle").onclick=()=>{const name=["running","paused"].includes(state.reminders?.focusMode)?"cancel":"start";afterMenuAction("focus:"+name,()=>post({type:"focus",name}))};
$("#controlsButton").onclick=event=>{if(moreOpen){closeMore();return}moreOpen=true;selectMore($("[data-more-tab][aria-selected=true]")?.dataset.moreTab||"interact");post({type:"menuFocus",active:true});$("#morePanel").hidden=false;$("#controlsButton").setAttribute("aria-expanded","true");renderControls();regions();if(event.isTrusted&&event.detail===0)$("#closeMore").focus()};
$("#closeMore").onclick=()=>closeMore();
document.querySelectorAll("[data-more-tab]").forEach(b=>{b.onclick=()=>selectMore(b.dataset.moreTab);b.onkeydown=e=>{if(!["ArrowLeft","ArrowRight"].includes(e.key))return;e.preventDefault();const tabs=[...document.querySelectorAll("[data-more-tab]")],next=tabs[(tabs.indexOf(b)+(e.key==="ArrowRight"?1:tabs.length-1))%tabs.length];selectMore(next.dataset.moreTab);next.focus()}});
document.querySelectorAll("[data-quick-focus]").forEach(b=>b.onclick=()=>{const name=b.dataset.quickFocus;afterMenuAction("focus:"+name,()=>post({type:"focus",name}))});
document.querySelectorAll("[data-pet-setting]").forEach(e=>e.onchange=()=>{const key=e.dataset.petSetting,value=e.checked;afterMenuAction("setting:"+key,()=>post({type:"petSetting",key,value}))});
document.querySelectorAll("[data-control]").forEach(b=>b.onclick=()=>{const name=b.dataset.control;afterMenuAction(name,()=>post({type:"control",name}))});
document.querySelectorAll("[data-open-tab]").forEach(b=>b.onclick=()=>{const tab=b.dataset.openTab;afterMenuAction("settings:"+tab,()=>post({type:"settings",tab}))});
$("#saySomething").onclick=()=>afterMenuAction("whisper",()=>post({type:"whisper"}));
for(const id of ["pet","customArt","petMenu","morePanel"]){$("#"+id).addEventListener("pointerenter",showBar);$("#"+id).addEventListener("pointerleave",laterHide)}
document.addEventListener("keydown",e=>{if(e.key==="Escape"){e.preventDefault();moreOpen?closeMore():closeBar()}else if(e.key==="Tab"&&moreOpen){const items=[...$("#morePanel").querySelectorAll("button,input")].filter(x=>!x.disabled&&x.offsetParent!==null&&x.tabIndex>=0);const i=items.indexOf(document.activeElement);if(e.shiftKey&&i<=0){e.preventDefault();items[items.length-1]?.focus()}else if(!e.shiftKey&&i===items.length-1){e.preventDefault();items[0]?.focus()}}});
window.uiDiagnostics=()=>{const n=$("#notice"),r=n.getBoundingClientRect(),h=$(state.pack?"#customArt":"#pet").getBoundingClientRect(),c=getComputedStyle(n);return{edgeQuiet:!!state.edgeQuiet,manageButtons:[...document.querySelectorAll(".manage-actions button")].map(b=>b.textContent),manageFits:$("#morePanel").scrollHeight<=$("#morePanel").clientHeight,manageLayout:[...document.querySelectorAll(".manage-actions button")].map(b=>{const r=b.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height}}),queuedWalk,fleeing,reminderText:$("#noticeText").textContent,reminderTitle:$("#noticeSource").textContent,ackVisible:!$("#ackReminder").hidden,laterVisible:!$("#later").hidden,noticeHidden:n.hidden,kind:n.dataset.kind,summaryFitsOneLine:$("#noticeText").clientHeight<=parseFloat(getComputedStyle($("#noticeText")).lineHeight)+1,withinViewport:r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight,width:r.width,height:r.height,centerX:r.x+r.width/2,headCenterX:h.x+h.width/2,headGap:h.top-r.bottom,background:c.backgroundColor,summaryFont:getComputedStyle($("#noticeText")).fontSize,agentActionButtons:["#dismiss","#later"].map(id=>{const e=$(id),b=e.getBoundingClientRect();return{id,visible:!e.hidden,x:b.x,y:b.y,width:b.width,height:b.height,rightInset:r.right-b.right,topInset:b.top-r.top,bottomInset:r.bottom-b.bottom}}),closeButtons:["#closeMore","#dismiss"].map(id=>{const b=$(id).getBoundingClientRect(),i=$(id+" svg").getBoundingClientRect();return{id,width:b.width,height:b.height,centerError:Math.max(Math.abs(b.x+b.width/2-i.x-i.width/2),Math.abs(b.y+b.height/2-i.y-i.height/2))}}),moreButton:!!$("#controlsButton"),barWidth:$("#petMenu").getBoundingClientRect().width,barHeight:$("#petMenu").getBoundingClientRect().height,borderRadius:c.borderRadius,dismissIconSize:getComputedStyle($("#dismiss svg")).width,barActions:[...$("#petMenu").querySelectorAll("button")].map(b=>b.textContent),moreOpen,gaps:(()=>{const p=$(state.pack?"#customArt":"#pet").getBoundingClientRect(),m=$("#morePanel").getBoundingClientRect(),b=$("#petMenu").getBoundingClientRect();return{toolbarSide:state.menusOnRight?m.left-b.right:b.left-m.right,bottomAlignment:Math.abs(m.bottom-b.bottom),bar:b.top-p.bottom,side:state.menusOnRight?m.left-p.right:p.left-m.right}})(),menusOnRight:!!state.menusOnRight,bubbleID:lastBubble?.id,actionPending,lastMenuAction,lastMenuActionAt,toolsLayout:[".mini-focus","#toggleWidgets","#focusSettings"].map(selector=>{const e=$(selector),r=e.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height}}),moreSize:{width:$("#morePanel").getBoundingClientRect().width,height:$("#morePanel").getBoundingClientRect().height},overlap:(()=>{const a=$(state.pack?"#customArt":"#pet").getBoundingClientRect(),intersects=b=>b.width>0&&b.height>0&&a.left<b.right&&a.right>b.left&&a.top<b.bottom&&a.bottom>b.top;return{more:intersects($("#morePanel").getBoundingClientRect()),bar:intersects($("#petMenu").getBoundingClientRect())}})(),widgetsExpanded,clockVisible:!$("#miniFocusContent").hidden,weatherText:$("#miniWeatherSummary").textContent,todayCalendar:$("#miniCalendarItems").textContent,rightAction:$("#focusSettings").textContent,barVisible:!$("#petMenu").hidden,moreTab:$("[data-more-tab][aria-selected=true]")?.dataset.moreTab}};
function lock(){lockedBubble=lastBubble?.id||null;post({type:"bubbleLock",locked:true})}
$("#notice").addEventListener("pointerenter",lock);
$("#notice").addEventListener("pointerleave",()=>{if(!press)post({type:"bubbleLock",locked:false,releasePress:true})});
$("#noticeBody").addEventListener("pointerdown",lock);
$("#ackReminder").onclick=()=>{if(lastBubble)post({type:"openBubble",id:lastBubble.id});post({type:"bubbleLock",locked:false,releasePress:true})};
$("#noticeBody").addEventListener("click",()=>{if(lockedBubble)post({type:"openBubble",id:lockedBubble})});
for(const [id,type] of [["dismiss","dismiss"],["later","snooze"]])$("#"+id).onclick=e=>{e.stopPropagation();if(lastBubble)post({type,id:lastBubble.id});post({type:"bubbleLock",locked:false,releasePress:true})};
$("#prev").onclick=()=>post({type:"cycle",delta:-1});$("#next").onclick=()=>post({type:"cycle",delta:1});
function interact(name){closeBar();if(name==="walk"){forcedSleep=false;window.command({name});local(line("walk"))}else if(name==="sleep"||name==="wake")window.command({name});else{burst(name,name==="play"?3500:2400);local(line(name));if(!state.settings.reducedMotion){for(let i=0;i<4;i++){const fx=document.createElement("span");fx.className="fx";fx.textContent=i%2?"✧":"♡";fx.style.cssText=`left:${38+Math.random()*24}%;top:${40+Math.random()*20}%;animation:floatUp 1.5s ease-out`;$("#art").append(fx);setTimeout(()=>fx.remove(),1600)}}}regions()}
document.querySelectorAll("[data-pet]").forEach(b=>b.onclick=()=>{const name=b.dataset.pet;afterMenuAction(name,()=>interact(name))});
document.addEventListener("pointerdown",e=>{
 if(e.button===0&&moreOpen&&!e.target.closest("#petMenu,#morePanel"))closeMore(false);
 if(e.button!==0||!e.target.closest("#pet,#customArt")||e.target.closest("#notice,#petMenu,#morePanel"))return;
 queuedWalk=false;nativeMoving=true;menuBlockedUntil=Date.now()+700;stopMotion();press={x:e.screenX,y:e.screenY};e.target.setPointerCapture?.(e.pointerId);closeBar();post({type:"beginGrab"});
});
document.addEventListener("pointerup",()=>{if(press)post({type:"releaseGrab"})});
document.addEventListener("pointercancel",()=>{if(press)post({type:"cancelGrab",reason:"pointer_cancel"})});
document.addEventListener("contextmenu",e=>{if(e.target.closest("#notice"))return;e.preventDefault();if(state.edgeQuiet||press||dragging||nativeMoving||Date.now()<menuBlockedUntil)return;closeMore(false);showBar();lastInteract=Date.now();forcedSleep=false;regions()});
window.addEventListener("blur",()=>{if(press)post({type:"cancelGrab",reason:"blur"});post({type:"bubbleLock",locked:false,releasePress:true})});
window.addEventListener("resize",()=>{packSignature="";applyPack();regions()});
setInterval(()=>{updateMode();regions()},250);
document.body.dataset.mode=mode;post({type:"ready"});regions();

window.addEventListener("error",e=>post({type:"runtimeDiagnostic",event:"js_error",message:String(e.message).slice(0,240)}));
window.addEventListener("unhandledrejection",e=>post({type:"runtimeDiagnostic",event:"promise_error",message:String(e.reason).slice(0,240)}));

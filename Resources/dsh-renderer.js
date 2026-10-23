"use strict";
// Trusted bundled HEVC-with-alpha assets. Imported packs retain their separate validator.
const DSHPet=(()=>{
 const art=document.querySelector('#art'),videos=[...art.querySelectorAll('video')],poster=document.querySelector('#poster');
 let active=-1,request=0,currentMode='',action='',reduced=false,disabled=false,previewing=false,lastError='',wanted='',lastCategory='',history=[];
 const groupBags=new Map(),directionRequests=new Map();let runDirection=1,nextWalkAction='',walkToken=0;
 // Verified against decoded frames: both side-on clips face left. Floating steps face front.
 const runClips={'原地左转奔跑':{facing:-1,start:2,end:4},'螃蟹走路':{facing:-1,start:2,end:7}};
 const movingActions=new Set(Object.keys(runClips));
 function orient(video,name,direction){video.style.setProperty('--clip-mirror',movingActions.has(name)?(direction===runClips[name].facing?1:-1):1)}
 function chooseDirection(token,name){
  if(currentMode==='walk')return Promise.resolve(runDirection);
  return new Promise(resolve=>{
   const timer=setTimeout(()=>{directionRequests.delete(token);resolve(0)},1500);
   directionRequests.set(token,direction=>{clearTimeout(timer);directionRequests.delete(token);resolve(direction)});
   window.webkit?.messageHandlers?.starbud?.postMessage({type:'runAnimationDirection',token,action:name});
  });
 }
 window.resolveRunDirection=({token,direction})=>directionRequests.get(token)?.(direction<0?-1:1);
 const shuffle=xs=>xs.map(x=>({x,k:Math.random()})).sort((a,b)=>a.k-b.k).map(x=>x.x);
 function randomAction(){
  const groups=DSH_CATALOG.randomGroups.filter(g=>g.actions.some(n=>n!==action)),total=groups.reduce((n,g)=>n+g.weight,0);let roll=Math.random()*total,group=groups[groups.length-1];
  for(const g of groups){roll-=g.weight;if(roll<0){group=g;break}}
  let bag=groupBags.get(group.id)||[];if(!bag.length)bag=shuffle(group.actions);
  if(bag.length>1&&bag[bag.length-1]===action)[bag[0],bag[bag.length-1]]=[bag[bag.length-1],bag[0]];
  const next=bag.pop();groupBags.set(group.id,bag);lastCategory=group.id;return next;
 }
 const pick=items=>items[Math.floor(Math.random()*items.length)];
 const pools={idle:['待机呼吸休闲'],think:['工作状态-思考冒泡','工作状态-忙碌点按','工作状态-清点归档'],wait:['工作状态-原地踱步张望'],celebrate:['工作状态-雀跃庆祝'],error:['工作状态-垂头叹气冒汗'],drag:['被鼠标拖拽悬空反馈'],dragRelease:['打瞌睡被惊醒'],walk:['原地左转奔跑','螃蟹走路'],edgeQuiet:['原地重力下蹲压缩'],sleep:['原地小憩沉眠'],wake:['超大伸懒腰'],joy:DSH_CATALOG.clicks,welcome:['点击回应-元气挥手'],eat:DSH_CATALOG.eat,play:DSH_CATALOG.play,whisper:DSH_CATALOG.whisper};
 function pickMode(mode){const name=mode==='walk'&&nextWalkAction?nextWalkAction:pick(pools[mode]||pools.idle);nextWalkAction='';return name}
 async function play(name){
  if(!DSH_CATALOG.all.includes(name)||disabled)return;
  const token=++request;wanted=name;
  for(const [old,resolve] of directionRequests)if(old!==token)resolve(0);
  const direction=movingActions.has(name)?await chooseDirection(token,name):1;
  if(token!==request)return;
  if(!direction){play('待机呼吸休闲');return}
  const slot=active===0?1:0,v=videos[slot];orient(v,name,direction);
  v.oncanplay=null;v.onseeked=null;v.onerror=null;v.onended=null;v.ontimeupdate=null;v.pause();v.classList.remove('active');v.muted=true;v.loop=currentMode==='edgeQuiet';
  const segment=currentMode==='walk'?runClips[name]:null;
  // Seek before exposing a running clip. Its full version includes a turn and a fall.
  const start=async()=>{
   if(token!==request||v.seeking)return;
   if(segment&&v.currentTime<segment.start-.02){v.currentTime=segment.start;return}
   v.oncanplay=null;v.onseeked=null;
   try{
    await v.play();if(token!==request){v.pause();return}
    if(reduced)v.pause();
    const old=active;active=slot;action=name;history.push(name);if(history.length>24)history.shift();lastError='';v.classList.add('active');poster.hidden=true;
    if(currentMode==='walk')window.webkit?.messageHandlers?.starbud?.postMessage({type:'walkAnimationReady',token:walkToken});
    if(old>=0&&old!==slot){videos[old].classList.remove('active');videos[old].pause()}
   }catch(error){lastError=String(error);poster.hidden=active>=0;window.webkit?.messageHandlers?.starbud?.postMessage({type:'runtimeDiagnostic',event:'video_error',message:lastError});}
  };
  v.oncanplay=start;v.onseeked=start;
  v.onerror=()=>{if(token!==request)return;lastError='无法解码 '+name;window.webkit?.messageHandlers?.starbud?.postMessage({type:'runtimeDiagnostic',event:'video_error',message:lastError});/* Keep previous frame or poster, never show a black replacement. */};
  v.ontimeupdate=()=>{if(token===request&&segment&&['walk','edgeQuiet'].includes(currentMode)&&v.currentTime>=segment.end-.15&&!v.seeking)v.currentTime=segment.start};
  v.onended=()=>{if(token!==request||disabled||reduced)return;if(currentMode==='idle'&&window.onPetAnimationEnded?.())return;if(previewing){previewing=false;play('待机呼吸休闲');return}if(currentMode==='idle'){play(randomAction());return}play(pickMode(currentMode))};
  v.src='dsh/mov/'+encodeURIComponent(name)+'.mov';v.load();
 }
 return {
  setWalkToken(token){walkToken=token},
  resumeIdle(){if(currentMode==='idle'&&videos[active]?.ended)play(randomAction())},
  setNextWalkAction(name){if(pools.walk.includes(name))nextWalkAction=name},
  setRunDirection(direction){runDirection=direction<0?-1:1;if(currentMode==='walk')videos.forEach((v,index)=>{if(index===active)orient(v,action,runDirection);else orient(v,wanted,runDirection)})},
  set(mode,quiet){
   const quietChanged=reduced!==quiet,changed=currentMode!==mode||quietChanged||disabled;disabled=false;reduced=quiet;
   if(mode==='preview'&&previewing){if(quietChanged&&active>=0){if(quiet)videos[active].pause();else videos[active].play().catch(e=>{lastError=String(e)})}return;}
   if(!changed)return;previewing=false;currentMode=mode;if(mode==='walk'&&active>=0)orient(videos[active],action,runDirection);play(pickMode(mode));
  },
  stop(){disabled=true;++request;videos.forEach(v=>v.pause());},
  preview(name){if(!DSH_CATALOG.all.includes(name))return;disabled=false;previewing=true;currentMode='preview';play(name)},
  diagnostics(){
   const v=videos[active],r=document.querySelector('#pet').getBoundingClientRect();let alpha=null;
   if(v&&v.readyState>=2){try{const c=document.createElement('canvas');c.width=640;c.height=360;const x=c.getContext('2d',{willReadFrequently:true});x.drawImage(v,0,0,640,360);const p=x.getImageData(0,0,640,360).data;let transparent=0,exactTransparent=0,visible=0,minX=640,minY=360,maxX=0,maxY=0;for(let i=3;i<p.length;i+=4){if(p[i]===0)exactTransparent++;if(p[i]<=2)transparent++;if(p[i]>32){visible++;const n=(i-3)/4,px=n%640,py=Math.floor(n/640);minX=Math.min(minX,px);maxX=Math.max(maxX,px);minY=Math.min(minY,py);maxY=Math.max(maxY,py)}}alpha={transparent,exactTransparent,transparentThreshold:2,visible,bounds:[minX,minY,maxX,maxY]}}catch(e){alpha={error:String(e)}}}
   return{edgeLoop:currentMode==='edgeQuiet'&&!!v?.loop,runDirection,baseFacing:runClips[action]?.facing||0,runSegment:currentMode==='walk'?runClips[action]||null:null,clipTransform:v?getComputedStyle(v).transform:"",clipMirror:v?Number(v.style.getPropertyValue('--clip-mirror')||1):1,visibleVideoCount:videos.filter(v=>{const s=getComputedStyle(v);return s.visibility!=='hidden'&&Number(s.opacity)>0}).length,videoTransition:getComputedStyle(videos[0]).transitionDuration,renderer:'dsh-hevc-alpha',randomCount:DSH_CATALOG.randomCount,randomCategory:lastCategory,history:[...history],action,wanted,mode:currentMode,ready:!!v&&v.readyState>=2,time:v?.currentTime||0,paused:v?.paused??true,error:lastError,body:{x:r.x,y:r.y,width:r.width,height:r.height},alpha};
  }
 };
})();
window.petDiagnostics=()=>DSHPet.diagnostics();

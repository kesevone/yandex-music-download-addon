((send) => {
  const host=document.createElement('div');host.id='ym-downloads-manager';
  host.style.cssText='position:fixed;right:24px;bottom:124px;z-index:2147483600;font-family:"YS Text",sans-serif;color:#f5f5f5';
  const root=host.attachShadow({mode:'open'});
  root.innerHTML=`<style>
    *{box-sizing:border-box}[hidden]{display:none!important}button{font:inherit;cursor:pointer;border:0;color:inherit}button:focus-visible{outline:2px solid #ffdb00;outline-offset:3px}
    svg{width:20px;height:20px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}
    .chip{position:relative;z-index:3;width:44px;height:44px;display:grid;place-items:center;border-radius:50%;background:#262626;color:#eee;box-shadow:0 3px 18px #0007;transition:background .3s ease}
    .chip:hover,.chip[aria-expanded=true]{background:#383838}.chip>svg{width:22px;height:22px}
    .ring{position:absolute;inset:1px;width:42px!important;height:42px!important;transform:rotate(-90deg);color:#ffdb00;pointer-events:none}
    .ring circle{stroke-width:1.8;stroke-dasharray:113.1;transition:stroke-dashoffset .2s ease}.ring.spin{animation:spin 1.5s linear infinite}
    .badge{position:absolute;right:-3px;top:-3px;min-width:18px;height:18px;border-radius:9px;display:grid;place-items:center;padding:0 4px;background:#ffdb00;color:#181818;font-size:10px;font-weight:600;border:2px solid #181818}
    .box{position:absolute;z-index:2;right:0;bottom:56px;width:340px;max-width:calc(100vw - 48px);background:#262626;border:1px solid #ffffff14;border-radius:20px;box-shadow:0 12px 48px #0009;overflow:hidden}
    .header{display:flex;align-items:center;justify-content:space-between;padding:17px 18px 14px}.header strong{font-size:15px;font-weight:600}.count{font-size:11px;color:#999;margin-left:7px}
    .close,.action{width:26px;height:26px;display:grid;place-items:center;background:transparent;border-radius:50%;color:#999;padding:4px;transition:background .3s ease,color .3s ease}.close:hover,.action:hover{color:#fff;background:#ffffff14}.close svg,.action svg{width:17px;height:17px}
    .list{max-height:min(430px,calc(100vh - 240px));overflow:auto;padding:0 10px 10px;scrollbar-width:thin;scrollbar-color:#ffffff30 transparent}
    .item{display:flex;gap:10px;padding:10px 8px;border-radius:12px}.item:hover{background:#ffffff07}.cover{width:36px;height:36px;border-radius:7px;object-fit:cover;flex:0 0 36px;background:#ffffff0a}.fallback{display:grid;place-items:center;color:#888}
    .info{flex:1;min-width:0}.title{font-size:12px;line-height:17px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.artists{font-size:10px;color:#aaa;line-height:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.meta{display:flex;justify-content:space-between;gap:8px;margin-top:5px;font-size:10px;color:#999;line-height:14px}.item[data-status=error] .meta{color:#f8a5a0}.item[data-status=done] .meta{color:#b6d09e}
    .bar{height:3px;background:#ffffff14;overflow:hidden;border-radius:3px;margin-top:7px}.fill{height:100%;width:0;background:#ffdb00;transition:width .15s linear}.bar.indeterminate .fill{width:30%!important;animation:flow 1.2s ease-in-out infinite}
    .byte-count{font-size:10px;line-height:14px;color:#999;margin-top:4px}
    .empty{padding:12px 18px 24px;font-size:12px;color:#aaa;line-height:18px}.footer{border-top:1px solid #ffffff12;padding:12px 18px;font-size:10px;color:#999;line-height:15px}
    .notice{padding:0 18px 12px;font-size:11px;line-height:16px;color:#f8a5a0}
    .toast{position:absolute;z-index:2;right:0;bottom:56px;width:300px;min-height:112px;max-width:calc(100vw - 48px);border:1px solid #ffffff14;border-radius:16px;padding:15px 16px;background:#262626;box-shadow:0 8px 32px #0008;pointer-events:none;transform-origin:right bottom}
    .toast-label{font-size:10px;color:#aaa;margin-bottom:6px}.toast-title{font-size:13px;font-weight:600;line-height:18px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.toast-sub{font-size:11px;color:#aaa;margin-top:3px;line-height:16px}.toast .bar{margin-top:12px}
    .morphing{background:transparent!important;border-color:transparent!important;box-shadow:none!important;pointer-events:none}
    .liquid{position:fixed;z-index:1;background:#262626;border:1px solid #ffffff14;box-shadow:0 8px 32px #0008;pointer-events:none;will-change:left,top,width,height,border-radius}
    .flight{position:fixed;z-index:5;left:0;top:0;display:grid;place-items:center;overflow:hidden;border-radius:10px;background:#383838;box-shadow:0 5px 18px #0008;pointer-events:none;will-change:transform,opacity}.flight img{width:100%;height:100%;object-fit:cover}.flight svg{width:24px;height:24px;color:#ffdb00}
    .arrival{position:fixed;z-index:4;width:44px;height:44px;border:1.5px solid #ffdb00;border-radius:50%;pointer-events:none}
    @keyframes flow{from{transform:translateX(-100%)}to{transform:translateX(430%)}}@keyframes spin{to{transform:rotate(270deg)}}
    @media(prefers-reduced-motion:reduce){*{transition:none!important}.ring.spin,.bar.indeterminate .fill{animation:none!important}}
  </style>
  <div class="toast" hidden><div class="toast-label" role="status" aria-live="polite"></div><div class="toast-title"></div><div class="toast-sub"></div><div class="bar" aria-hidden="true"><div class="fill"></div></div></div>
  <section class="box" role="dialog" aria-label="Очередь скачивания" hidden><div class="header"><div><strong>Загрузки</strong><span class="count"></span></div><button class="close" aria-label="Закрыть очередь"><svg viewBox="0 0 24 24"><path d="m6 6 12 12M18 6 6 18"/></svg></button></div><div class="notice" role="status" aria-live="polite" hidden></div><div class="list"></div><div class="empty">Здесь появятся очередь и история скачиваний.</div><div class="footer">Файлы сохраняются в Загрузки / Yandex Music</div></section>
  <button class="chip" type="button" title="Очередь и история скачиваний" aria-label="Открыть очередь скачивания" aria-expanded="false"><svg viewBox="0 0 24 24"><path d="M12 3v12m-5-5 5 5 5-5M5 17v4h14v-4"/></svg><svg class="ring" viewBox="0 0 40 40" hidden><circle cx="20" cy="20" r="18"/></svg><span class="badge" hidden></span></button>`;
  document.body.append(host);
  const chip=root.querySelector('.chip'),box=root.querySelector('.box'),list=root.querySelector('.list'),toast=root.querySelector('.toast');
  const nodes=new Map(),terminal=new Set(['done','error','cancelled']),motions=new Map(),origins=new Map(),effects=new Set();
  let jobs=[],boxOpen=false,toastId,toastTimer,noticeTimer,toastAnimation,toastClosing=false,boxAnimation;
  const reduced=()=>matchMedia('(prefers-reduced-motion:reduce)').matches;
  const label=job=>({queued:'В очереди',source:'Подготовка',downloading:'Скачивание',extracting:'Сохранение FLAC',done:'Скачано',error:'Ошибка',cancelled:'Отменено'}[job.status] || 'Подготовка');
  const bytes=value=>value>=1048576?(value/1048576).toFixed(1)+' МБ':Math.round((value || 0)/1024)+' КБ';
  const progress=job=>Number.isFinite(job.percent)?Math.round(job.percent)+'%':job.status==='queued'?'':label(job);
  const active=job=>!terminal.has(job.status);
  function setBar(bar,job){
    bar.hidden=terminal.has(job.status);bar.classList.toggle('indeterminate',job.status!=='queued' && !Number.isFinite(job.percent));
    bar.querySelector('.fill').style.width=(Number.isFinite(job.percent)?job.percent:0)+'%';
    if(!bar.hasAttribute('aria-hidden')){
      bar.setAttribute('role','progressbar');bar.setAttribute('aria-label',label(job));bar.setAttribute('aria-valuemin','0');bar.setAttribute('aria-valuemax','100');
      if(Number.isFinite(job.percent))bar.setAttribute('aria-valuenow',String(Math.round(job.percent)));else bar.removeAttribute('aria-valuenow');
    }
  }
  function morphSurface(element,open){
    const previous=motions.get(element),startRect=previous?.surface.getBoundingClientRect();
    const opacity=element.hidden?0:Number(getComputedStyle(element).opacity);
    const startRadius=previous?getComputedStyle(previous.surface).borderRadius:open?'50%':getComputedStyle(element).borderRadius;
    previous?.cancel();element.hidden=false;
    const panelRect=element.getBoundingClientRect(),chipRect=chip.getBoundingClientRect();
    const from=startRect || (open?chipRect:panelRect),to=open?panelRect:chipRect;
    const surface=document.createElement('div');surface.className='liquid';surface.dataset.kind=element===box?'queue':'notice';surface.setAttribute('aria-hidden','true');root.append(surface);
    const radius=element===box?'20px':'16px';
    const frame=(t,borderRadius,overshoot=0)=>({
      left:(from.left+(to.left-from.left)*t-overshoot/2)+'px',top:(from.top+(to.top-from.top)*t-overshoot/2)+'px',
      width:(from.width+(to.width-from.width)*t+overshoot)+'px',height:(from.height+(to.height-from.height)*t+overshoot)+'px',borderRadius
    });
    const frames=open?[
      {...frame(0,startRadius),offset:0},
      {...frame(.22,'47% 53% 45% 55% / 54% 46% 54% 46%'),offset:.23},
      {...frame(.87,'38px 48px 34px 42px'),offset:.57},
      {...frame(1,radius,5),offset:.82},
      {...frame(1,radius),offset:1}
    ]:[
      {...frame(0,startRadius),offset:0},
      {...frame(.13,'32px 38px 36px 32px'),offset:.23},
      {...frame(.71,'47% 53% 55% 45% / 48% 52% 46% 54%'),offset:.65},
      {...frame(1,'50%'),offset:1}
    ];
    element.classList.add('morphing');
    const duration=reduced()?0:open?540:430;
    const geometry=surface.animate(frames,{duration,easing:'cubic-bezier(.22,.7,.22,1)',fill:'forwards'});
    const content=element.animate(open?[
      {opacity,offset:0},{opacity:0,offset:.42},{opacity:1,offset:.92},{opacity:1,offset:1}
    ]:[{opacity},{opacity:0,offset:.3},{opacity:0}],{duration,fill:'forwards'});
    let motion,clipFrame,targetRect=panelRect;
    const started=performance.now();
    const clip=()=>{
      const r=surface.getBoundingClientRect(),b=element.getBoundingClientRect();
      element.style.clipPath=`inset(${Math.min(b.height,Math.max(0,r.top-b.top))}px ${Math.min(b.width,Math.max(0,b.right-r.right))}px ${Math.min(b.height,Math.max(0,b.bottom-r.bottom))}px ${Math.min(b.width,Math.max(0,r.left-b.left))}px round 20px)`;
      clipFrame=requestAnimationFrame(clip);
    };
    clip();
    const clean=()=>{cancelAnimationFrame(clipFrame);surface.remove();element.style.removeProperty('clip-path');element.classList.remove('morphing');if(motions.get(element)===motion)motions.delete(element);};
    motion={surface,
      retarget(){
        if(!open || reduced())return;
        const next=element.getBoundingClientRect();
        if(['left','top','width','height'].every(key=>Math.abs(next[key]-targetRect[key])<.5))return;
        targetRect=next;
        const now=surface.getBoundingClientRect(),rounded=getComputedStyle(surface).borderRadius;
        const dimensions=(r,borderRadius,extra=0)=>({left:r.left-extra/2+'px',top:r.top-extra/2+'px',width:r.width+extra+'px',height:r.height+extra+'px',borderRadius});
        const remaining=Math.max(240,duration-(performance.now()-started));
        geometry.effect.setKeyframes([{...dimensions(now,rounded),offset:0},{...dimensions(next,radius,3),offset:.8},{...dimensions(next,radius),offset:1}]);
        geometry.effect.updateTiming({duration:remaining});geometry.currentTime=0;
        const currentOpacity=Number(getComputedStyle(element).opacity);
        content.effect.setKeyframes([{opacity:currentOpacity,offset:0},{opacity:currentOpacity,offset:.35},{opacity:1,offset:1}]);content.effect.updateTiming({duration:remaining});content.currentTime=0;
      },
      cancel(){geometry.cancel();content.cancel();clean();},finished:geometry.finished.then(()=>{content.cancel();geometry.cancel();clean();})};
    motions.set(element,motion);return motion;
  }
  function animateBox(open){
    if(open===boxOpen)return;
    boxOpen=open;chip.setAttribute('aria-expanded',String(open));
    if(open)hideToast(true);
    const animation=morphSurface(box,open);boxAnimation=animation;
    animation.finished.then(()=>{if(boxAnimation!==animation)return;if(!boxOpen)box.hidden=true;animation.cancel();boxAnimation=null;}).catch(()=>{});
  }
  chip.onclick=()=>animateBox(!boxOpen);root.querySelector('.close').onclick=()=>animateBox(false);
  const outside=event=>{if(!event.composedPath().includes(host) && boxOpen)animateBox(false);};document.addEventListener('pointerdown',outside);
  root.addEventListener('keydown',event=>{if(event.key==='Escape'){animateBox(false);chip.focus();}});
  function hideToast(immediate=false){
    clearTimeout(toastTimer);if(toast.hidden)return;
    if(immediate){toastAnimation?.cancel();toastAnimation=null;toast.hidden=true;toastClosing=false;return;}
    toastClosing=true;
    const animation=morphSurface(toast,false);toastAnimation=animation;
    animation.finished.then(()=>{if(toastAnimation!==animation)return;toast.hidden=true;animation.cancel();toastAnimation=null;toastClosing=false;}).catch(()=>{});
  }
  function updateToast(job){
    if(!job)return;
    root.querySelector('.toast-label').textContent=label(job)+(job.format?' '+job.format.toUpperCase():'');
    root.querySelector('.toast-title').textContent=job.title;root.querySelector('.toast-sub').textContent=(job.artists || []).join(', ');
    setBar(toast.querySelector('.bar'),job);
  }
  function showToast(job){
    if(boxOpen)return;const same=toastId===job.id && !toast.hidden && !toastClosing;toastId=job.id;updateToast(job);clearTimeout(toastTimer);
    toastClosing=false;
    if(!same){
      const animation=morphSurface(toast,true);toastAnimation=animation;
      animation.finished.then(()=>{if(toastAnimation===animation)toastAnimation=null;}).catch(()=>{});
    }
    toastTimer=setTimeout(hideToast,2800);
  }
  function prepareTransfer(id,source,track){
    const rect=source?.getBoundingClientRect();
    if(!rect || !rect.width || !rect.height)return;
    origins.set(id,{rect:{left:rect.left,top:rect.top,width:rect.width,height:rect.height},cover:track.cover,time:Date.now()});
  }
  function transient(element,keyframes,options){
    root.append(element);effects.add(element);
    const animation=element.animate(keyframes,options);
    animation.finished.catch(()=>{}).finally(()=>{element.remove();effects.delete(element);});return animation;
  }
  function flyTrack(job){
    const origin=origins.get(job.id);origins.delete(job.id);
    if(!origin || Date.now()-origin.time>15000 || reduced())return;
    let target=chip;
    const rowCover=nodes.get(job.id)?.querySelector('.cover');
    if(boxOpen && rowCover && !rowCover.hidden){const r=rowCover.getBoundingClientRect(),b=list.getBoundingClientRect();if(r.top>=b.top && r.bottom<=b.bottom)target=rowCover;}
    const destination=target.getBoundingClientRect(),size=Math.min(origin.rect.width,56);
    const start={x:origin.rect.left+origin.rect.width/2,y:origin.rect.top+origin.rect.height/2};
    const end={x:destination.left+destination.width/2,y:destination.top+destination.height/2};
    const control={x:start.x+(end.x-start.x)*.52,y:Math.min(start.y,end.y)-Math.min(110,Math.hypot(end.x-start.x,end.y-start.y)*.18)};
    const flight=document.createElement('div');flight.className='flight';flight.dataset.jobId=job.id;flight.style.width=size+'px';flight.style.height=size+'px';flight.setAttribute('aria-hidden','true');
    if(origin.cover && /^https:\/\//.test(origin.cover)){const img=document.createElement('img');img.src=origin.cover;img.alt='';flight.append(img);}
    else flight.innerHTML='<svg viewBox="0 0 24 24"><path d="M12 3v12m-5-5 5 5 5-5M5 17v4h14v-4"/></svg>';
    const frames=[0,.24,.55,.82,1].map(t=>{
      const x=(1-t)*(1-t)*start.x+2*(1-t)*t*control.x+t*t*end.x,y=(1-t)*(1-t)*start.y+2*(1-t)*t*control.y+t*t*end.y;
      const scale=1-.76*t,angle=Math.sin(Math.PI*t)*8*(end.x>=start.x?1:-1);
      return {offset:t,transform:`translate3d(${x-size/2}px,${y-size/2}px,0) scale(${scale}) rotate(${angle}deg)`,opacity:t===1?0:1,borderRadius:(10+18*t)+'px'};
    });
    const animation=transient(flight,frames,{duration:680,easing:'cubic-bezier(.3,.05,.45,1)',fill:'forwards'});
    animation.finished.then(()=>{
      if(!host.isConnected)return;
      const pulse=document.createElement('div');pulse.className='arrival';pulse.style.left=end.x-22+'px';pulse.style.top=end.y-22+'px';pulse.setAttribute('aria-hidden','true');
      transient(pulse,[{opacity:.6,transform:'scale(.55)'},{opacity:0,transform:'scale(1.7)'}],{duration:330,easing:'ease-out'});
    }).catch(()=>{});
  }
  function createItem(job){
    const element=document.createElement('div');element.className='item';
    element.innerHTML='<img class="cover" alt=""><div class="info"><div class="title"></div><div class="artists"></div><div class="meta"><span class="phase"></span><span class="percent"></span></div><div class="bar"><div class="fill"></div></div><div class="byte-count" hidden></div></div><button class="action" type="button" hidden></button>';
    const action=element.querySelector('.action');
    action.onclick=()=>{const current=jobs.find(item=>item.id===job.id);if(current?.status==='queued')send({action:'cancel',id:job.id});else if(current?.status==='done')send({action:'reveal',id:job.id});};
    return element;
  }
  function render(snapshot){
    jobs=Array.isArray(snapshot.jobs)?snapshot.jobs:[];
    const pending=jobs.filter(active),current=pending.find(job=>job.status!=='queued');
    chip.title=pending.length?'Загрузки: '+pending.length+' в работе и очереди':'Очередь и история скачиваний';
    const badge=root.querySelector('.badge');badge.hidden=!pending.length;badge.textContent=pending.length>99?'99+':String(pending.length);
    const ring=root.querySelector('.ring');ring.hidden=!current;ring.classList.toggle('spin',!!current && !Number.isFinite(current.percent));ring.querySelector('circle').style.strokeDashoffset=String(113.1*(1-(Number.isFinite(current?.percent)?current.percent:22)/100));
    root.querySelector('.count').textContent=pending.length?String(pending.length)+' в очереди':'';
    root.querySelector('.empty').hidden=jobs.length>0;
    const ordered=[...pending.sort((a,b)=>a.createdAt-b.createdAt),...jobs.filter(job=>terminal.has(job.status)).sort((a,b)=>b.createdAt-a.createdAt)];
    for(const [id,node] of nodes)if(!jobs.some(job=>job.id===id)){node.remove();nodes.delete(id);}
    let index=0;
    for(const job of ordered){
      let node=nodes.get(job.id);if(!node){node=createItem(job);nodes.set(job.id,node);}
      node.dataset.status=job.status;node.querySelector('.title').textContent=job.title;node.querySelector('.title').title=job.title;
      node.querySelector('.artists').textContent=(job.artists || []).join(', ');
      const cover=node.querySelector('.cover');if(job.cover && /^https:\/\//.test(job.cover)){if(cover.getAttribute('src')!==job.cover)cover.src=job.cover;cover.hidden=false;}else{cover.removeAttribute('src');cover.hidden=true;}
      const queuedIndex=pending.filter(item=>item.status==='queued').findIndex(item=>item.id===job.id)+1;
      node.querySelector('.phase').textContent=(job.format || '').toUpperCase()+' · '+label(job)+(job.status==='queued'?' '+queuedIndex:'');
      node.querySelector('.percent').textContent=job.status==='done'?new Date(job.finishedAt || job.createdAt).toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'}):progress(job);
      node.title=job.status==='error'?(job.message || 'Ошибка скачивания'):job.file || job.title;
      setBar(node.querySelector('.bar'),job);
      const byteCount=node.querySelector('.byte-count');byteCount.hidden=job.status!=='downloading';byteCount.textContent=bytes(job.received)+(job.total?' / '+bytes(job.total):'');
      const action=node.querySelector('.action');action.hidden=!['queued','done'].includes(job.status);
      action.setAttribute('aria-label',job.status==='queued'?'Убрать из очереди':'Показать файл в папке');action.title=action.getAttribute('aria-label');
      action.innerHTML=job.status==='queued'?'<svg viewBox="0 0 24 24"><path d="m6 6 12 12M18 6 6 18"/></svg>':'<svg viewBox="0 0 24 24"><path d="M3 7h7l2 2h9v11H3V7Z"/><path d="M3 7V4h7l2 3"/></svg>';
      if(list.children[index]!==node)list.insertBefore(node,list.children[index] || null);index++;
    }
    const notified=jobs.find(job=>job.id===snapshot.jobId);
    if(notified && snapshot.reason==='enqueue')flyTrack(notified);
    for(const [id,origin] of origins)if(Date.now()-origin.time>15000)origins.delete(id);
    if(snapshot.notice){
      const notice=root.querySelector('.notice');notice.textContent=snapshot.notice;notice.hidden=false;clearTimeout(noticeTimer);noticeTimer=setTimeout(()=>{notice.hidden=true;},6000);
      showToast({id:'notice',status:'error',title:snapshot.notice,artists:[]});
    }
    if(notified && ['enqueue','start','done','error','duplicate'].includes(snapshot.reason))showToast(notified);
    if(toastId && !toast.hidden)updateToast(jobs.find(job=>job.id===toastId));
    for(const motion of motions.values())motion.retarget();
  }
  function getJob(track,format){
    const matches=jobs.filter(job=>job.track===track && (!format || job.format===format));
    return matches.find(job=>active(job) && job.status!=='queued') || matches.find(active) || matches.sort((a,b)=>b.createdAt-a.createdAt)[0];
  }
  return {render,getJob,label,bytes,active,prepareTransfer,jobs:()=>jobs,
    state:()=>({count:jobs.length,pending:jobs.filter(active).length,open:boxOpen}),
    destroy(){clearTimeout(toastTimer);clearTimeout(noticeTimer);toastAnimation?.cancel();boxAnimation?.cancel();for(const motion of motions.values())motion.cancel();for(const element of effects){for(const animation of element.getAnimations())animation.cancel();element.remove();}effects.clear();origins.clear();document.removeEventListener('pointerdown',outside);host.remove();}
  };
})

(() => {
  if(window !== window.top || location.origin !== 'music-application://desktop')return {installed:false};
  if (window.__ymRuntimeDownload) return {installed:true};
  const activeTrack = __YM_ACTIVE_TRACK__;
  const createQueue = __YM_DOWNLOAD_QUEUE__;
  const host = document.createElement('span');
  host.id = 'ym-runtime-download';
  host.style.cssText = 'display:inline-flex;flex:0 0 var(--ym-size,48px);width:var(--ym-size,48px);height:var(--ym-size,48px);align-self:center;position:relative;color:inherit;z-index:20';
  const root = host.attachShadow({mode:'open'});
  root.innerHTML = `<style>
    :host{font-family:var(--ym-font,"YS Text",sans-serif);color:inherit}
    *{box-sizing:border-box}
    button{font:inherit;color:inherit;border:0;cursor:pointer}
    .icon{display:grid;place-items:center;width:var(--ym-size,48px);height:var(--ym-size,48px);padding:var(--ym-pad,12px);background:var(--ym-btn-bg,#ffffff14);border-radius:var(--ym-radius,100px);color:var(--ym-btn-color,#ffffffb3);transition:background-color .3s ease,color .3s ease}
    .icon:hover,.icon[aria-expanded=true]{background:#ffffff18}
    .icon:focus-visible{outline:2px solid #ffcf00;outline-offset:2px}
    button:disabled{opacity:.4;cursor:default}
    svg{width:24px;height:24px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
    .busy svg{animation:pulse .9s ease-in-out infinite alternate}
    @keyframes pulse{to{opacity:.25}}
    .panel{position:fixed;inset:auto;margin:0;width:320px;max-width:calc(100vw - 24px);padding:18px;border:1px solid #ffffff14;border-radius:20px;background:#262626;color:#f5f5f5;box-shadow:0 12px 48px #0009;font-family:var(--ym-font,"YS Text",sans-serif);z-index:2147483647;display:flex;flex-direction:column;overflow:visible;max-height:calc(100vh - 24px)}
    .panel-content{min-height:0;overflow:auto}
    .panel::before{content:"";position:absolute;width:12px;height:12px;right:-7px;top:var(--ym-tip-y,26px);background:#262626;border-top:1px solid #ffffff14;border-right:1px solid #ffffff14;transform:rotate(45deg);pointer-events:none}
    .panel[data-attachment=player]::before{top:auto;bottom:-7px;right:14px;border-top:0;border-bottom:1px solid #ffffff14}
    .panel::backdrop{background:transparent}
    [hidden]{display:none!important}
    .header{display:flex;flex-shrink:0;align-items:center;justify-content:space-between;gap:16px;margin-bottom:15px}
    .header h2{font-size:15px;line-height:20px;font-weight:600;margin:0}
    .close{width:24px;height:24px;display:grid;place-items:center;background:transparent;padding:3px;color:#aaa;border-radius:50%}
    .close:hover{color:#fff;background:#ffffff12}.close svg{width:18px;height:18px}
    .track{display:flex;align-items:center;gap:12px;margin-bottom:18px;min-width:0}
    .cover{width:56px;height:56px;flex:0 0 56px;display:grid;place-items:center;background:#ffffff0d;border-radius:10px;overflow:hidden;color:#777}
    .cover img{width:100%;height:100%;object-fit:cover}.cover svg{width:25px;height:25px}
    .meta{min-width:0;flex:1}.title{font-size:14px;line-height:19px;font-weight:600;overflow-wrap:anywhere;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
    .artists{font-size:12px;line-height:17px;color:#b3b3b3;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-top:3px}
    .duration{font-size:11px;line-height:15px;color:#919191;margin-top:4px}
    .choices{display:grid;grid-template-columns:1fr 1fr;gap:8px}
    .choice{min-height:64px;padding:11px 10px;border-radius:12px;text-align:left;background:#ffffff14;color:#f5f5f5;transition:background-color .3s ease,color .3s ease}
    .close{transition:background-color .3s ease,color .3s ease}
    .choice:hover{background:#ffffff22}.choice[data-format=flac]{background:#ffdb00;color:#161616}.choice[data-format=flac]:hover{background:#ffe64d}
    .choice strong{display:block;font-size:14px;line-height:18px;font-weight:600}.choice small{display:block;opacity:.65;margin-top:4px;font-size:11px;line-height:15px}
    .status{padding:12px 0 0;line-height:17px;font-size:12px;overflow-wrap:anywhere;max-height:140px;overflow:auto;white-space:pre-line}
    .status[data-kind=error]{color:#ffb0a9}.status[data-kind=done]{color:#c6e7ae}
    .destination{border-top:1px solid #ffffff12;padding-top:12px;margin-top:14px;color:#919191;font-size:11px;line-height:15px}
    @media(prefers-reduced-motion:reduce){.busy svg{animation:none}.icon,.choice,.close{transition:none}}
    .status:empty{display:none}
  </style><button class="icon" type="button" aria-label="Скачать текущий трек" aria-haspopup="dialog" aria-expanded="false" title="Скачать текущий трек"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v12m-5-5 5 5 5-5M5 17v4h14v-4"/></svg></button>
  <section class="panel" popover="manual" role="dialog" aria-label="Скачать трек" hidden>
    <div class="header"><h2>Скачать трек</h2><button class="close" type="button" aria-label="Закрыть"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 6 12 12M18 6 6 18"/></svg></button></div>
    <div class="panel-content">
    <div class="track"><div class="cover"><img alt="" hidden><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 18V5l11-2v13M9 7l11-2"/><ellipse cx="6" cy="18" rx="3" ry="2"/><ellipse cx="17" cy="16" rx="3" ry="2"/></svg></div><div class="meta"><div class="title"></div><div class="artists"></div><div class="duration"></div></div></div>
    <div class="choices"><button class="choice" type="button" aria-label="Скачать FLAC" data-format="flac"><strong>FLAC</strong><small>Без потери качества</small></button><button class="choice" type="button" aria-label="Скачать MP3" data-format="mp3"><strong>MP3</strong><small>Высокое качество</small></button></div>
    <div class="status" role="status" aria-live="polite"></div><div class="destination">Загрузки / Yandex Music</div>
    </div>
  </section>`;
  const icon = root.querySelector('.icon'), panel = root.querySelector('.panel');
  const portalHost=document.createElement('span');portalHost.id='ym-runtime-download-popup';
  portalHost.style.cssText='position:absolute;left:0;top:0;width:100%;height:0;z-index:1000;pointer-events:auto';
  const portalRoot=portalHost.attachShadow({mode:'open'});portalRoot.append(root.querySelector('style').cloneNode(true));
  const choices = root.querySelector('.choices'), status = root.querySelector('.status');
  const cover=root.querySelector('.cover img'), buttons=[...root.querySelectorAll('[data-format]')], unavailable=new Set();
  let current, selectedTrack, popupAnchor, popupSide, popupOffset, popupTrigger, requestedTrack, requestId, busy = false, disposed = false, hideTimer, renderedTrack, popupAnimation, desiredOpen=false;
  const rowEntries=new Map();
  const queue=createQueue(payload=>window.__ymDownloadTrack(JSON.stringify(payload)));
  const rowStyle=document.createElement('style');rowStyle.id='ym-runtime-download-row-style';
  rowStyle.textContent='[data-test-id="YM_ROW_DOWNLOAD_BUTTON"]{opacity:1!important;visibility:visible!important;transition:background-color .3s ease,color .3s ease!important}[data-test-id="YM_ROW_DOWNLOAD_BUTTON"][aria-expanded="true"]{background-color:rgba(255,255,255,.08)!important;color:rgba(255,255,255,.95)!important}[data-ym-row-download]{opacity:1!important;visibility:visible!important}@media(prefers-reduced-motion:reduce){[data-test-id="YM_ROW_DOWNLOAD_BUTTON"]{transition:none!important}}';
  document.head.append(rowStyle);
  function scrollParent(element){
    for(let parent=element?.parentElement;parent && parent!==document.body;parent=parent.parentElement){
      if(/auto|scroll/.test(getComputedStyle(parent).overflowY))return parent;
    }
  }
  function mountPanel(){
    const container=popupAnchor && scrollParent(popupAnchor);
    if(container && getComputedStyle(container).position!=='static'){
      panel.dataset.attachment='row';
      if(portalHost.parentElement!==container)container.append(portalHost);
      if(panel.parentNode!==portalRoot){
        if(panel.matches(':popover-open'))panel.hidePopover();
        panel.removeAttribute('popover');panel.style.position='absolute';portalRoot.append(panel);
      }
      return container;
    }
    panel.dataset.attachment='player';
    if(panel.parentNode!==root){panel.style.position='fixed';panel.setAttribute('popover','manual');root.append(panel);portalHost.remove();}
  }
  function placePanel(){
    if(panel.hidden)return;
    let anchor=popupAnchor || icon;
    const originalEntry=popupAnchor?[...rowEntries.entries()].find(([,entry])=>entry.button===anchor):null;
    if(popupAnchor && (!anchor.isConnected || !originalEntry || getRowTrack(originalEntry[0])?.id!==selectedTrack?.id)){
      // Virtualized lists may recreate a row; reconnect only to the same track.
      const entry=[...rowEntries.entries()].find(([original])=>getRowTrack(original)?.id===selectedTrack?.id);
      if(entry){anchor=entry[1].button;popupAnchor=anchor;popupTrigger=anchor;}
      else{return;}
    }
    if(!anchor.isConnected)return;
    const container=mountPanel();
    const rect=anchor.getBoundingClientRect();
    const bounds=container?container.getBoundingClientRect():{top:0,left:0,bottom:innerHeight};
    const viewportTop=Math.max(0,bounds.top),viewportBottom=Math.min(innerHeight,bounds.bottom);
    panel.style.maxHeight=Math.max(1,container?viewportBottom-viewportTop-16:innerHeight-24)+'px';
    const width=panel.offsetWidth,height=panel.offsetHeight;
    panel.style.visibility='visible';
    const center=rect.top+rect.height/2;
    const initialPlacement=popupSide==null;
    popupSide ||= popupAnchor?(center-30+height<=bounds.bottom-8?'below':'above'):(rect.top-height-10>=bounds.top+8?'above':'below');
    let top=popupAnchor?(popupSide==='above'?center-height+30:center-30):(popupSide==='above'?rect.top-height-10:rect.bottom+10);
    if(popupAnchor){
      if(initialPlacement){
        top=Math.max(viewportTop+8,Math.min(top,viewportBottom-height-8));
        // Retain the row-relative offset so scrolling carries the card away naturally.
        popupOffset=top-center;
      }else top=center+popupOffset;
    }
    panel.style.setProperty('--ym-tip-y',(Math.max(18,Math.min(center-top,height-18))-6)+'px');
    const left=popupAnchor?rect.left-width-12:rect.right-width;
    if(container){
      panel.style.left=Math.max(12,Math.min(left-bounds.left+container.scrollLeft,container.clientWidth-width-12))+'px';
      panel.style.top=(top-bounds.top+container.scrollTop)+'px';
    }else{
      panel.style.left=Math.max(12,Math.min(left,innerWidth-width-12))+'px';panel.style.top=top+'px';
    }
  }
  const show = (visible,replay=false) => {
    icon.setAttribute('aria-expanded',String(visible && popupTrigger===icon));
    for(const entry of rowEntries.values())entry.button.setAttribute('aria-expanded',String(visible && popupTrigger===entry.button));
    if(visible===desiredOpen && !replay){if(visible)placePanel();return;}
    desiredOpen=visible;
    if(visible){popupSide=null;popupOffset=null;}
    const opacity=panel.hidden || replay?'0':getComputedStyle(panel).opacity;
    popupAnimation?.cancel();
    if(visible){panel.hidden=false;mountPanel();if(panel.hasAttribute('popover') && !panel.matches(':popover-open'))panel.showPopover();placePanel();}
    const duration=matchMedia('(prefers-reduced-motion: reduce)').matches?0:250;
    const animation=panel.animate([{opacity},{opacity:visible?1:0}],{duration,easing:'ease',fill:'forwards'});popupAnimation=animation;
    animation.finished.then(()=>{
      if(popupAnimation!==animation)return;
      if(!desiredOpen){if(panel.matches(':popover-open'))panel.hidePopover();panel.hidden=true;}
      popupAnimation?.cancel();popupAnimation=null;
    }).catch(()=>{});
  };
  function renderTrack(){
    const track=selectedTrack || current;if(!track)return;
    const key=track.id+'|'+track.title+'|'+track.cover;
    if(key!==renderedTrack){
      panel.querySelector('.title').textContent=track.title+(track.version?' ('+track.version+')':'');
      panel.querySelector('.artists').textContent=(track.artists || []).join(', ');
      panel.querySelector('.artists').title=(track.artists || []).join(', ');
      const seconds=Math.max(0,Math.floor(track.duration || 0));
      panel.querySelector('.duration').textContent=Math.floor(seconds/60)+':'+String(seconds%60).padStart(2,'0');
      const url=track.cover && /^https:\/\//.test(track.cover)?track.cover:null;
      cover.hidden=!url;panel.querySelector('.cover svg').style.display=url?'none':'';
      if(url)cover.src=url;else cover.removeAttribute('src');renderedTrack=key;
    }
    for(const button of buttons){const job=queue.getJob(track.id,button.dataset.format);button.disabled=!!job && queue.active(job);}
    placePanel();
  }
  cover.onerror=()=>{cover.hidden=true;panel.querySelector('.cover svg').style.display='';};
  icon.onclick = event => {
    event.stopPropagation();clearTimeout(hideTimer);
    const sameTrigger=popupTrigger===icon,visible=!desiredOpen || !sameTrigger,replay=desiredOpen && !sameTrigger;
    selectedTrack=null;popupAnchor=null;popupSide=null;popupOffset=null;popupTrigger=icon;
    if(!sameTrigger){status.textContent='';status.dataset.kind='';}
    renderTrack();show(visible,replay);
  };
  root.querySelector('.close').onclick=()=>{show(false);icon.focus();};
  root.addEventListener('keydown', event => {if(event.key === 'Escape'){show(false);icon.focus();}});
  portalRoot.addEventListener('keydown',event=>{if(event.key==='Escape'){show(false);popupTrigger?.focus();}});
  const outside = event => {const path=event.composedPath();if(!path.includes(host) && !path.includes(portalHost) && !path.some(node=>node?.dataset?.testId==='YM_ROW_DOWNLOAD_BUTTON'))show(false);};
  document.addEventListener('pointerdown', outside);
  addEventListener('resize',placePanel);document.addEventListener('scroll',placePanel,true);
  function notify(message,kind='') {status.textContent = message;status.dataset.kind=kind;if(desiredOpen)placePanel();}
  for(const button of root.querySelectorAll('[data-format]')) button.onclick = event => {
    event.stopPropagation();
    const track = selectedTrack || current;
    if(!track || !/^\d+$/.test(track.id)){notify('Сначала выберите трек в приложении.');return;}
    requestedTrack=track;
    requestId = crypto.randomUUID();
    queue.prepareTransfer(requestId,panel.querySelector('.cover'),track);
    status.textContent='';status.dataset.kind='';
    try {window.__ymDownloadTrack(JSON.stringify({action:'download',id:requestId,track:track.id,format:button.dataset.format,display:{title:track.title,artists:track.artists,cover:track.cover}}));}
    catch {busy=false;icon.classList.remove('busy');renderTrack();notify('Помощник отключён. Запустите «Музыка с кнопкой скачивания».','error');}
  };
  function getRowTrack(element){
    let fiber=element[Object.keys(element).find(key=>key.startsWith('__reactFiber'))];
    for(let depth=0;fiber && depth<90;depth++,fiber=fiber.return){
      const track=fiber.memoizedProps?.track;
      if(track?.id && track.title && /^\d+$/.test(String(track.id)))return {
        id:String(track.id),title:track.title,version:track.version,
        artists:(track.artists || []).map(artist=>artist.name),duration:track.durationMs/1000,
        cover:track.coverUri?'https://'+track.coverUri.replace(/^https?:\/\//,'').replace('%%','400x400'):null
      };
    }
  }
  function attachRows(){
    for(const [original,entry] of rowEntries)if(!original.isConnected){entry.wrapper.remove();rowEntries.delete(original);}
    for(const original of document.querySelectorAll('[data-test-id="TRACK_CONTEXT_MENU_BUTTON"]')){
      const track=getRowTrack(original);if(!track)continue;
      let entry=rowEntries.get(original);
      if(!entry){
        const wrapper=document.createElement('span');wrapper.dataset.ymRowDownload='';wrapper.style.cssText='display:inline-flex;flex:0 0 40px;width:40px;height:40px;align-items:center';
        const button=original.cloneNode(true);
        for(const attr of ['id','aria-haspopup','aria-expanded','aria-controls','aria-describedby','data-disabled'])button.removeAttribute(attr);
        button.dataset.testId='YM_ROW_DOWNLOAD_BUTTON';button.setAttribute('aria-label','Скачать на устройство');button.disabled=false;
        button.setAttribute('aria-haspopup','dialog');button.setAttribute('aria-expanded','false');
        const svg=button.querySelector('svg');
        if(svg){const use=svg.querySelector('use');if(use){use.setAttribute('href','/icons/sprite.svg#download_xxs');use.setAttributeNS('http://www.w3.org/1999/xlink','href','/icons/sprite.svg#download_xxs');}}
        button.style.transition='background-color .3s ease,color .3s ease,opacity .3s ease';
        button.onclick=event=>{
          event.preventDefault();event.stopPropagation();
          if(desiredOpen && popupTrigger===button){show(false);return;}
          const target=getRowTrack(original);if(!target)return;
          const replay=desiredOpen;
          selectedTrack=target;popupAnchor=button;popupSide=null;popupTrigger=button;status.textContent='';status.dataset.kind='';clearTimeout(hideTimer);
          renderTrack();show(true,replay);
        };
        wrapper.append(button);entry={wrapper,button};rowEntries.set(original,entry);
      }
      entry.button.title='Скачать на устройство: '+track.title;
      const parent=original.closest('[class*="CommonControlsBar_contextMenuWrapper"]') || original.parentElement;
      if(parent?.parentElement && entry.wrapper.nextSibling!==parent)parent.before(entry.wrapper);
    }
  }
  const attach = () => {
    if(disposed)return;
    const bars = [...document.querySelectorAll('[data-test-id="PLAYERBAR_DESKTOP"], [data-test-id="VIBE_PLAYERBAR"], [data-test-id="PLAYERBAR"]')];
    const bar = bars.find(el => el.getBoundingClientRect().height > 0);
    if(bar){
      const anchor = bar.querySelector('[data-test-id="VIBE_CONTEXT_MENU_BUTTON"]') || bar.querySelector('[data-test-id="LIKE_BUTTON"]') || bar.querySelector('[data-test-id="PLAYERBAR_DESKTOP_CONTEXT_MENU_BUTTON"], [data-test-id="CONTEXT_MENU_BUTTON"]');
      let parent=anchor?.parentElement || bar;
      for(let depth=0;parent!==bar && depth<5 && getComputedStyle(parent).display!=='flex';depth++)parent=parent.parentElement;
      if(host.parentElement !== parent)parent.append(host);
      if(anchor){
        const style=getComputedStyle(anchor);
        host.style.setProperty('--ym-size',style.height);host.style.setProperty('--ym-pad',style.padding);
        host.style.setProperty('--ym-btn-bg',style.backgroundColor);host.style.setProperty('--ym-btn-color',style.color);
        host.style.setProperty('--ym-radius',style.borderRadius);host.style.setProperty('--ym-font',getComputedStyle(document.body).fontFamily);
      }
    }
    const next=activeTrack()?.track;
    if(!busy && !selectedTrack && next?.id!==current?.id){status.textContent='';status.dataset.kind='';}
    current=next;
    icon.disabled = !current;
    icon.title = current ? 'Скачать: ' + current.title : 'Сначала выберите трек';
    renderTrack();
    attachRows();
  };
  const timer = setInterval(attach, 700);
  window.__ymRuntimeDownload = {
    receiveState(snapshot){
      queue.render(snapshot);busy=queue.jobs().some(job=>queue.active(job) && job.status!=='queued');
      icon.classList.toggle('busy',busy);renderTrack();
    },
    update(message){
      if(message.id !== requestId)return;
      if(message.stage === 'done' || message.stage === 'error'){
        busy=false;icon.classList.remove('busy');
        if(message.code==='flac_unavailable')unavailable.add(requestedTrack.id);
        renderTrack();
        notify(message.stage === 'done' ? 'Скачано\n' + message.file?.split(/[\\/]/).pop() : message.message,message.stage);
        clearTimeout(hideTimer); hideTimer=setTimeout(()=>show(false),message.stage==='done'?12000:20000);
      }else notify(message.message || 'Скачиваю…');
    },
    dispose(){disposed=true;clearInterval(timer);clearTimeout(hideTimer);popupAnimation?.cancel();if(panel.matches(':popover-open'))panel.hidePopover();document.removeEventListener('pointerdown',outside);removeEventListener('resize',placePanel);document.removeEventListener('scroll',placePanel,true);for(const entry of rowEntries.values())entry.wrapper.remove();rowEntries.clear();queue.destroy();rowStyle.remove();portalHost.remove();host.remove();delete window.__ymRuntimeDownload;},
    state(){return {installed:host.isConnected,track:current?.id,selectedTrack:selectedTrack?.id,busy,requestId,status:status.textContent,popup:desiredOpen,rows:rowEntries.size,downloads:queue.state()};}
  };
  attach();try{window.__ymDownloadTrack(JSON.stringify({action:'snapshot'}));}catch{}return {installed:true};
})()

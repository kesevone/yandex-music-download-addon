import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source=fs.readFileSync(new URL('../src/ym-download-button.js',import.meta.url),'utf8');
function snippet(first,last){
  const start=source.indexOf(first),end=source.indexOf(last,start);
  assert.ok(start>=0 && end>start,'UI fixture could not locate the actual source handler');
  return source.slice(start,end);
}
const playerHandler=snippet('  icon.onclick = ',"\n  root.querySelector('.close')");
const formatHandlers=snippet("  for(const button of root.querySelectorAll('[data-format]')) button.onclick",'  function getRowTrack');
const showHandler=snippet('  const show = ','  function renderTrack');
const placementHandler=snippet('  function placePanel(){','  const show = ');
const event={preventDefault(){},stopPropagation(){}};

function control(){
  return {attributes:{},setAttribute(name,value){this.attributes[name]=value;},classList:{remove(){}}};
}
function popupContext(){
  const icon=control(),rowButton=control();
  const context={icon,rowEntries:new Map([[{}, {button:rowButton}]]),rowButton,
    current:{id:'2',title:'Player B',artists:[]},selectedTrack:{id:'1',title:'Row A',artists:[]},
    popupAnchor:rowButton,popupTrigger:rowButton,popupSide:'below',popupOffset:0,
    desiredOpen:true,popupAnimation:null,hideTimer:null,status:{textContent:'',dataset:{}},
    clearTimeout(){},getComputedStyle(){return {opacity:'1'};},matchMedia(){return {matches:true};},
    mountPanel(){},placePanel(){},renderTrack(){context.rendered=context.selectedTrack || context.current;},
    panel:{hidden:false,hasAttribute(){return false;},matches(){return false;},
      animate(frames){context.animationFrames=frames;return {cancel(){},finished:Promise.resolve()};}}
  };
  vm.createContext(context);
  vm.runInContext(showHandler+playerHandler+'\nthis.showPopup=show;',context);
  return context;
}

test('format selection submits the displayed player snapshot when playback changes between polls',()=>{
  const buttons=['flac','mp3'].map(format=>({dataset:{format}})),sent=[];
  const context={root:{querySelectorAll(){return buttons;}},current:{id:'1',title:'Displayed A',artists:['Artist A']},
    selectedTrack:null,activeTrack(){return {track:{id:'2',title:'Playing B',artists:['Artist B']}};},
    crypto:{randomUUID(){return 'fixture';}},queue:{prepareTransfer(){}},panel:{querySelector(){return {};}},
    status:{textContent:'',dataset:{}},window:{__ymDownloadTrack(data){sent.push(JSON.parse(data));}},
    notify(message){assert.fail(message);},icon:control(),renderTrack(){}};
  vm.createContext(context);vm.runInContext(formatHandlers,context);
  for(const button of buttons)button.onclick(event);
  assert.deepEqual(sent.map(job=>[job.track,job.format,job.display.title]),[
    ['1','flac','Displayed A'],['1','mp3','Displayed A']
  ]);
  context.selectedTrack={id:'3',title:'Selected row C',artists:[]};buttons[0].onclick(event);
  assert.equal(sent.at(-1).track,'3');
});

test('row to player switches the open popup, and repeated player clicks toggle it',()=>{
  const context=popupContext();context.icon.onclick(event);
  assert.equal(context.desiredOpen,true);
  assert.equal(context.rendered.id,'2');
  assert.equal(context.popupTrigger,context.icon);
  assert.equal(context.popupAnchor,null);
  assert.equal(context.icon.attributes['aria-expanded'],'true');
  assert.equal(context.rowButton.attributes['aria-expanded'],'false');
  context.icon.onclick(event);
  assert.equal(context.desiredOpen,false);
  assert.equal(context.icon.attributes['aria-expanded'],'false');
  context.icon.onclick(event);
  assert.equal(context.desiredOpen,true);
});

test('only the active row trigger is expanded while its popup is open',()=>{
  const context=popupContext();context.showPopup(true);
  assert.equal(context.rowButton.attributes['aria-expanded'],'true');
  assert.equal(context.icon.attributes['aria-expanded'],'false');
  context.showPopup(false);
  assert.equal(context.rowButton.attributes['aria-expanded'],'false');
});

function placementContext(naturalHeight=290){
  const original={},container={clientWidth:600,clientHeight:360,scrollLeft:0,scrollTop:0,
    getBoundingClientRect(){return {top:80,left:0,bottom:440};}};
  const anchor={isConnected:true,getBoundingClientRect(){return {top:230-container.scrollTop,left:560,right:600,height:40,bottom:270-container.scrollTop};}};
  const style={setProperty(name,value){this[name]=value;},removeProperty(name){delete this[name];}};
  const panel={hidden:false,style,offsetWidth:320,
    get offsetHeight(){return Math.min(naturalHeight,parseFloat(style.maxHeight) || Infinity);}};
  const context={panel,popupAnchor:anchor,popupTrigger:anchor,popupSide:null,popupOffset:null,
    rowEntries:new Map([[original,{button:anchor}]]),selectedTrack:{id:'1'},icon:control(),innerHeight:600,innerWidth:800,
    mountPanel(){return container;},getRowTrack(){return {id:'1'};},container};
  vm.createContext(context);vm.runInContext(placementHandler,context);
  context.viewportTop=()=>80-container.scrollTop+parseFloat(panel.style.top);
  return context;
}

test('initial row popup placement fits within a short scrolling viewport',()=>{
  const context=placementContext();context.placePanel();
  assert.ok(context.viewportTop()>=88);
  assert.ok(context.viewportTop()+context.panel.offsetHeight<=432);
  const tip=parseFloat(context.panel.style['--ym-tip-y']);
  assert.ok(tip>=12 && tip<context.panel.offsetHeight);
});

test('scrolling retains the row-relative offset and lets the popup leave naturally',()=>{
  const context=placementContext();context.placePanel();
  const initialTop=context.viewportTop(),initialContentTop=context.panel.style.top;
  context.container.scrollTop=200;context.placePanel();
  assert.equal(context.panel.style.top,initialContentTop);
  assert.equal(context.viewportTop(),initialTop-200);
  assert.ok(context.viewportTop()<80,'The popup must leave the viewport with its row');
  context.container.scrollTop=0;context.placePanel();
  assert.equal(context.viewportTop(),initialTop);
});

test('oversized cards constrain their height and keep the close header outside the scrollable body',()=>{
  const context=placementContext(600);context.placePanel();
  assert.equal(context.panel.offsetHeight,344);
  assert.ok(context.viewportTop()>=88);
  assert.ok(context.viewportTop()+context.panel.offsetHeight<=432);
  assert.match(source,/\.panel-content\{[^}]*min-height:0[^}]*overflow(?:-y)?:auto/);
  assert.match(source,/<div class="header">[\s\S]*?<\/button><\/div>\s*<div class="panel-content">/);
});

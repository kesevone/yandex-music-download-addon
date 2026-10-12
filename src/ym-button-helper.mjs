// Runtime-only button bridge. It opens no HTTP listener and never alters app.asar.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';

const root = path.dirname(fileURLToPath(import.meta.url));
const scratch = process.env.YM_WORK_DIR ? path.resolve(process.env.YM_WORK_DIR) : path.join(process.env.LOCALAPPDATA || root,'YandexMusicDownloadAddon','state');
fs.mkdirSync(scratch, {recursive:true});
const lockFile = path.join(scratch, 'button-helper.json');
const stopFile = path.join(scratch, 'button-helper-stop.json');
const port = Number(process.env.YM_APP_PORT || 9229);
if(!Number.isInteger(port) || port < 1 || port > 65535)throw new Error('Invalid app port');
const python = process.env.YM_PYTHON || 'python';
const activeExpression = fs.readFileSync(path.join(root, 'ym-active-track.js'), 'utf8').trim();
const queueExpression = fs.readFileSync(path.join(root, 'ym-download-queue.js'), 'utf8').trim();
const injection = fs.readFileSync(path.join(root, 'ym-download-button.js'), 'utf8')
  .replace('__YM_ACTIVE_TRACK__', '() => (' + activeExpression + ')')
  .replace('__YM_DOWNLOAD_QUEUE__',queueExpression);
const instance = randomUUID();
const binding = '__ymDownloadTrack';
let connection, scriptId, worker, stopped = false, connectedOnce = false;
let workerDone = Promise.resolve();
const queueFile=path.join(scratch,'downloads.json');
const terminalStatuses=new Set(['done','error','cancelled']);
let jobs=[];
try{
  const saved=JSON.parse(fs.readFileSync(queueFile,'utf8').replace(/^\uFEFF/,''));
  const valid=(saved.jobs || []).filter(job=>typeof job.id==='string' && /^\d{1,20}$/.test(job.track) && ['flac','mp3'].includes(job.format));
  jobs=valid.filter(job=>!terminalStatuses.has(job.status)).concat(valid.filter(job=>terminalStatuses.has(job.status)).slice(-100)).sort((a,b)=>a.createdAt-b.createdAt);
  for(const job of jobs)if(!terminalStatuses.has(job.status)){job.status='queued';job.percent=null;job.received=0;job.total=null;}
}catch{}
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const log = message => process.stdout.write(new Date().toISOString() + ' ' + message + '\n');
const readJson = file => JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));

function claimLock(){
  if(fs.existsSync(lockFile)){
    let previous;
    try{previous=readJson(lockFile);}catch{}
    if(previous?.pid){
      try{process.kill(previous.pid,0);throw new Error('The runtime button helper is already running');}
      catch(error){if(error.code !== 'ESRCH')throw error;}
    }
    fs.unlinkSync(lockFile);
  }
  fs.writeFileSync(lockFile, JSON.stringify({pid:process.pid,instance,script:fileURLToPath(import.meta.url)}), {flag:'wx'});
}

async function connect(){
  const targets=await (await fetch(`http://127.0.0.1:${port}/json/list`,{signal:AbortSignal.timeout(2000)})).json();
  const target=targets.find(item=>item.type==='page' && /^music-application:\/\/desktop(?:\/|$)/.test(item.url));
  if(!target)throw new Error('Music page unavailable');
  const debuggerUrl=new URL(target.webSocketDebuggerUrl);
  if(debuggerUrl.protocol!=='ws:' || !['127.0.0.1','localhost','[::1]'].includes(debuggerUrl.hostname))throw new Error('Non-local debugging URL');
  const socket=new WebSocket(debuggerUrl);
  try{
    await new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{socket.close();reject(new Error('Connection timed out'));},3000);
      socket.addEventListener('open',()=>{clearTimeout(timer);resolve();},{once:true});
      socket.addEventListener('error',()=>{clearTimeout(timer);reject(new Error('Connection failed'));},{once:true});
    });
  }catch(error){socket.close();throw error;}
  let nextId=0, mainFrameId;
  const pending=new Map(), mainContexts=new Set();
  const call=(method,params={})=>new Promise((resolve,reject)=>{
    if(socket.readyState!==WebSocket.OPEN)return reject(new Error('Disconnected'));
    const id=++nextId;
    const timer=setTimeout(()=>{pending.delete(id);reject(new Error('CDP request timed out'));},8000);
    pending.set(id,{resolve,reject,timer});socket.send(JSON.stringify({id,method,params}));
  });
  const evaluate=async expression=>{
    const result=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});
    if(result.exceptionDetails)throw new Error('Runtime expression failed');
    return result.result?.value;
  };
  const channel={socket,call,evaluate,targetId:target.id};
  socket.addEventListener('message',event=>{
    let message;try{message=JSON.parse(event.data);}catch{return;}
    const request=pending.get(message.id);
    if(request){pending.delete(message.id);clearTimeout(request.timer);message.error?request.reject(new Error('CDP request failed')):request.resolve(message.result);return;}
    if(message.method==='Runtime.executionContextCreated'){
      const context=message.params.context;
      if(context.auxData?.isDefault && context.auxData.frameId===mainFrameId && context.origin==='music-application://desktop')mainContexts.add(context.id);
    }else if(message.method==='Runtime.executionContextDestroyed')mainContexts.delete(message.params.executionContextId);
    else if(message.method==='Runtime.executionContextsCleared')mainContexts.clear();
    else if(message.method==='Runtime.bindingCalled' && message.params.name===binding && mainContexts.has(message.params.executionContextId)){
      handleRequest(message.params.payload,channel).catch(()=>log('Download request could not be handled'));
    }
  });
  socket.addEventListener('close',()=>{for(const request of pending.values()){clearTimeout(request.timer);request.reject(new Error('Disconnected'));}pending.clear();});
  let addedBinding=false, addedScript;
  try{
    await call('Page.enable');
    mainFrameId=(await call('Page.getFrameTree')).frameTree.frame.id;
    await call('Runtime.enable');
    await call('Runtime.addBinding',{name:binding});addedBinding=true;
    addedScript=(await call('Page.addScriptToEvaluateOnNewDocument',{source:injection})).identifier;
    await evaluate(injection);
    scriptId=addedScript;
    return channel;
  }catch(error){
    try{
      if(socket.readyState===WebSocket.OPEN){
        if(addedScript)try{await call('Page.removeScriptToEvaluateOnNewDocument',{identifier:addedScript});}catch{}
        if(addedBinding){
          try{await evaluate('window.__ymRuntimeDownload?.dispose()');}catch{}
          try{await call('Runtime.removeBinding',{name:binding});}catch{}
          try{await evaluate('delete window.__ymDownloadTrack');}catch{}
        }
      }
    }finally{socket.close();}
    throw error;
  }
}

function persistQueue(){
  const terminals=jobs.filter(job=>terminalStatuses.has(job.status)).slice(-100);
  jobs=jobs.filter(job=>!terminalStatuses.has(job.status)).concat(terminals).sort((a,b)=>a.createdAt-b.createdAt);
  const partial=queueFile+'.tmp';
  fs.writeFileSync(partial,JSON.stringify({version:1,jobs}));fs.renameSync(partial,queueFile);
}

async function publish(reason='update',jobId=null,channel=connection,notice=null){
  try{persistQueue();}catch{log('Queue history could not be saved');}
  if(!channel || channel.socket.readyState!==WebSocket.OPEN)return;
  const snapshot={jobs,reason,jobId,notice};
  try{await channel.evaluate('window.__ymRuntimeDownload?.receiveState('+JSON.stringify(snapshot)+')');}catch{}
}

function updateJob(job,update){
  if(update.stage==='metadata'){
    const meta=update.metadata || {};
    if(typeof meta.title==='string')job.title=meta.title;
    if(Array.isArray(meta.artists))job.artists=meta.artists.filter(a=>typeof a==='string');
    if(typeof meta.cover==='string' && /^https:\/\//.test(meta.cover))job.cover=meta.cover;
    if(meta.duration_ms)job.duration=meta.duration_ms/1000;
  }else if(update.stage==='source'){job.status='source';job.message=update.message;}
  else if(update.stage==='download'){job.status='downloading';job.message=update.message;}
  else if(update.stage==='progress'){
    job.status=update.phase==='extract'?'extracting':'downloading';job.phase=update.phase;
    job.received=Number.isFinite(update.received)?Math.max(0,update.received):0;
    job.total=Number.isFinite(update.total) && update.total>0?update.total:null;
    job.percent=Number.isFinite(update.percent)?Math.max(0,Math.min(100,update.percent)):null;
  }else if(update.stage==='done'){
    job.status='done';job.percent=100;job.file=update.file;job.bytes=update.bytes;job.finishedAt=Date.now();
  }else if(update.stage==='error'){
    job.status='error';job.message=update.message || 'Не удалось скачать трек.';job.code=update.code;job.finishedAt=Date.now();
  }
  publish(update.stage==='done'?'done':update.stage==='error'?'error':'update',job.id).catch(()=>{});
}

function pump(){
  if(stopped || worker || !connection || connection.socket.readyState!==WebSocket.OPEN)return;
  const job=jobs.find(item=>item.status==='queued');if(!job)return;
  job.status='source';job.startedAt=Date.now();publish('start',job.id).catch(()=>{});
  worker=spawn(python,[path.join(root,'yandex_music_button.py'),job.track,'--format',job.format],
    {cwd:root,windowsHide:true,stdio:['ignore','pipe','pipe'],env:{...process.env,PYTHONIOENCODING:'utf-8'}});
  let buffer='', terminal=false;
  const child=worker;
  child.stdout.setEncoding('utf8');
  child.stdout.on('data',data=>{
    buffer+=data;
    if(buffer.length>65536){child.kill();return;}
    let lineEnd;
    while((lineEnd=buffer.indexOf('\n'))>=0){
      const line=buffer.slice(0,lineEnd);buffer=buffer.slice(lineEnd+1);
      try{
        const update=JSON.parse(line);
        if(['done','error'].includes(update.stage))terminal=true;
        updateJob(job,update);
      }catch{}
    }
  });
  // Worker credentials and URLs are never logged or inserted into the renderer.
  child.stderr.on('data',()=>{});
  workerDone=new Promise(resolve=>{
    const finish=()=>{if(worker===child)worker=null;resolve();pump();};
    child.once('error',()=>{terminal=true;updateJob(job,{stage:'error',message:'Не удалось запустить помощник скачивания.'});finish();});
    child.once('close',()=>{if(!terminal)updateJob(job,{stage:'error',message:'Помощник завершился без сохранённого файла.'});finish();});
  });
}

async function handleRequest(payload,channel){
  if(stopped || payload.length>8192)return;
  let request;try{request=JSON.parse(payload);}catch{return;}
  if(request.action==='snapshot'){await publish('snapshot',null,channel);return;}
  if(request.action==='clear-history'){jobs=jobs.filter(job=>!terminalStatuses.has(job.status));await publish('history-cleared',null,channel);return;}
  if(request.action==='cancel'){
    const job=jobs.find(item=>item.id===request.id && item.status==='queued');
    if(job){job.status='cancelled';job.finishedAt=Date.now();await publish('cancelled',job.id,channel);}return;
  }
  if(request.action==='reveal'){
    const job=jobs.find(item=>item.id===request.id && item.status==='done');
    if(!job)return;
    if(!job.file || !path.isAbsolute(job.file) || !fs.existsSync(job.file)){
      await publish('reveal-error',job.id,channel,'Файл перемещён или удалён. Проверьте папку Загрузки / Yandex Music.');return;
    }
    // This is the visible folder requested by the user, not a background helper.
    spawn(path.join(process.env.SystemRoot || 'C:\\Windows','explorer.exe'),['/select,',job.file],{windowsHide:false,stdio:'ignore'})
      .on('error',()=>publish('reveal-error',job.id,channel,'Не удалось открыть Проводник.').catch(()=>{}));
    return;
  }
  if(!/^[\da-f-]{36}$/i.test(request.id || '') || !/^\d{1,20}$/.test(request.track || '') || !['flac','mp3'].includes(request.format))return;
  const duplicate=jobs.find(job=>job.track===request.track && job.format===request.format && !terminalStatuses.has(job.status));
  if(duplicate){await publish('duplicate',duplicate.id,channel);return;}
  if(jobs.filter(job=>!terminalStatuses.has(job.status)).length>=100){await publish('queue-full',null,channel,'В очереди уже 100 треков. Дождитесь завершения загрузок.');return;}
  const display=request.display || {};
  const job={id:request.id,track:request.track,format:request.format,status:'queued',createdAt:Date.now(),received:0,total:null,percent:null,
    title:typeof display.title==='string'?display.title.slice(0,300):'Трек '+request.track,
    artists:Array.isArray(display.artists)?display.artists.filter(a=>typeof a==='string').slice(0,12):[],
    cover:typeof display.cover==='string' && /^https:\/\//.test(display.cover)?display.cover:null};
  jobs.push(job);await publish('enqueue',job.id,channel);pump();
}

async function cleanup(){
  stopped=true;
  if(connection?.socket.readyState===WebSocket.OPEN){
    try{await connection.evaluate('window.__ymRuntimeDownload?.dispose()');}catch{}
    if(scriptId)try{await connection.call('Page.removeScriptToEvaluateOnNewDocument',{identifier:scriptId});}catch{}
    try{await connection.call('Runtime.removeBinding',{name:binding});}catch{}
    try{await connection.evaluate('delete window.__ymDownloadTrack');}catch{}
    connection.socket.close();
  }
  await workerDone;
  try{const state=readJson(lockFile);if(state.instance===instance)fs.unlinkSync(lockFile);}catch{}
  try{const state=readJson(stopFile);if(state.instance===instance)fs.unlinkSync(stopFile);}catch{}
}

claimLock();
process.once('SIGINT',()=>{stopped=true;});process.once('SIGTERM',()=>{stopped=true;});
let failures=0;
try{
  while(!stopped){
    try{
      if(fs.existsSync(stopFile) && readJson(stopFile).instance===instance){stopped=true;break;}
      if(!connection || connection.socket.readyState!==WebSocket.OPEN){connection=await connect();connectedOnce=true;failures=0;log('Runtime download button installed');await publish('snapshot');pump();}
      // Restore the button if navigation/React replaces its controls.
      const present=await connection.evaluate('Boolean(window.__ymRuntimeDownload)');
      if(!present){await connection.evaluate(injection);await publish('snapshot');}
      await delay(1000);
    }catch{
      connection?.socket.close();connection=null;scriptId=null;
      if(++failures>(connectedOnce?10:60)){
        if(!connectedOnce){
          log('Cannot connect to Music. Close the app and reopen it using the addon shortcut.');
          process.exitCode=1;
        }
        break;
      }
      await delay(1000);
    }
  }
}finally{await cleanup();}
log('Runtime download button stopped');

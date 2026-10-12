// Internal child process. Its stdout is consumed privately by yandex_music.py.
// No credential is written to disk, a renderer binding, or a diagnostic log.
let socket;
try {
  const port = Number(process.argv[2] || 9229);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid local port');
  const response = await fetch(`http://127.0.0.1:${port}/json/list`, {signal:AbortSignal.timeout(2000)});
  if (!response.ok) throw new Error('App discovery failed');
  const targets = await response.json();
  const target = targets.find(t => t.type === 'page' && /^music-application:\/\/desktop(?:\/|$)/.test(t.url));
  if (!target) throw new Error('App page unavailable');
  const endpoint = new URL(target.webSocketDebuggerUrl);
  if (endpoint.protocol !== 'ws:' || !['127.0.0.1','localhost','[::1]'].includes(endpoint.hostname)) {
    throw new Error('Non-local debugger URL');
  }
  socket = new WebSocket(endpoint);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Connection timed out')), 3000);
    socket.addEventListener('open', () => {clearTimeout(timer);resolve();}, {once:true});
    socket.addEventListener('error', () => {clearTimeout(timer);reject(new Error('Connection failed'));}, {once:true});
  });
  const token = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Session read timed out')), 10000);
    socket.addEventListener('close', () => {clearTimeout(timer);reject(new Error('Disconnected'));}, {once:true});
    socket.addEventListener('message', event => {
      let message;try {message = JSON.parse(event.data);} catch {return;}
      if (message.id !== 1) return;
      clearTimeout(timer);
      if (message.error || message.result?.exceptionDetails) reject(new Error('Session read failed'));
      else resolve(message.result?.result?.value);
    });
    socket.send(JSON.stringify({id:1,method:'Runtime.evaluate',params:{
      expression:"(() => { if(location.origin!=='music-application://desktop') return null; const s=localStorage.getItem('oauth'); if(!s) return null; try { const v=JSON.parse(s); return typeof v==='string'?v:v.value; } catch { return s; } })()",
      returnByValue:true
    }}));
  });
  if (typeof token !== 'string' || !token) throw new Error('No signed-in session');
  process.stdout.write(JSON.stringify({token}));
} catch {
  process.stderr.write('Cannot read the current signed-in Music session.\n');
  process.exitCode = 1;
} finally {
  socket?.close();
}

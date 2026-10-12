// Exercise actual connect() code without reaching a real app, filesystem state, or network.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';

const helper = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../src/ym-button-helper.mjs');
let source = fs.readFileSync(helper, 'utf8').replace(/^import .*;\r?\n/gm, '')
  .replaceAll('fileURLToPath(import.meta.url)', JSON.stringify(helper));
source = source.slice(0, source.indexOf('\nclaimLock();'));

for (const failure of ['open', 'Page.enable', 'Page.addScriptToEvaluateOnNewDocument', 'injection', null]) {
  const calls = [], scripts = new Set(), bindings = new Set(), sockets = [];
  class FixtureSocket {
    static OPEN = 1;
    constructor() {
      this.readyState = 1; this.listeners = new Map(); sockets.push(this);
      queueMicrotask(() => this.dispatch(failure === 'open' ? 'error' : 'open', {}));
    }
    addEventListener(name, listener, options = {}) {
      const listeners = this.listeners.get(name) || [];
      listeners.push({listener, once: options.once}); this.listeners.set(name, listeners);
    }
    dispatch(name, event) {
      const listeners = this.listeners.get(name) || [];
      this.listeners.set(name, listeners.filter(item => !item.once));
      for (const item of listeners) item.listener(event);
    }
    close() { this.readyState = 3; this.dispatch('close', {}); }
    send(payload) {
      const message = JSON.parse(payload); calls.push(message);
      let result = {}, error;
      if (message.method === failure) error = {message: 'Synthetic setup failure'};
      else if (message.method === 'Page.getFrameTree') result = {frameTree: {frame: {id: 'fixture-frame'}}};
      else if (message.method === 'Runtime.addBinding') bindings.add(message.params.name);
      else if (message.method === 'Runtime.removeBinding') bindings.delete(message.params.name);
      else if (message.method === 'Page.addScriptToEvaluateOnNewDocument') {
        scripts.add('fixture-script'); result = {identifier: 'fixture-script'};
      } else if (message.method === 'Page.removeScriptToEvaluateOnNewDocument') scripts.delete(message.params.identifier);
      else if (message.method === 'Runtime.evaluate') {
        if (failure === 'injection' && message.params.expression.startsWith('(() =>')) {
          result = {exceptionDetails: {text: 'Synthetic injection failure'}};
        } else result = {result: {value: {installed: true}}};
      }
      queueMicrotask(() => this.dispatch('message', {data: JSON.stringify({id: message.id, result, error})}));
    }
  }
  const context = {
    fs: {mkdirSync() {}, readFileSync(file, encoding) {
      return file.endsWith('downloads.json') ? '{"jobs":[]}' : fs.readFileSync(file, encoding);
    }}, path, randomUUID: () => 'synthetic-instance',
    process: {env: {LOCALAPPDATA: path.dirname(helper)}, pid: 123, stdout: {write() {}}},
    spawn() { throw new Error('No child process is permitted in this fixture'); },
    fetch: async () => ({json: async () => [{id: 'fixture-target', type: 'page', url: 'music-application://desktop/',
      webSocketDebuggerUrl: 'ws://127.0.0.1:1/synthetic-cdp'}]}),
    WebSocket: FixtureSocket, URL, AbortSignal, setTimeout, clearTimeout, queueMicrotask
  };
  let channel, setupError;
  try { channel = await vm.runInNewContext(source + '\nconnect()', context); }
  catch (error) { setupError = error; }
  assert.equal(sockets.length, 1);
  if (failure) {
    assert.ok(setupError, `Expected ${failure} failure`);
    assert.equal(sockets[0].readyState, 3, `Leaked socket after ${failure}`);
    assert.equal(scripts.size, 0, `Leaked document script after ${failure}`);
    assert.equal(bindings.size, 0, `Leaked renderer binding after ${failure}`);
    if (failure === 'Page.enable') assert.equal(calls.some(call => call.method.startsWith('Runtime.remove')), false);
  } else {
    assert.equal(setupError, undefined);
    assert.equal(channel.socket.readyState, 1);
    assert.equal(scripts.size, 1); assert.equal(bindings.size, 1);
    channel.socket.close();
  }
}
process.stdout.write(JSON.stringify({scenarios: 5, liveNetworkRequests: 0}));

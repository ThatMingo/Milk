import { test } from 'node:test';
import assert from 'node:assert/strict';
import companion from '../Sources/MilkCore/Resources/milk-companion.mjs';
function setup(mode = 'approval', choices = []) {
  process.env.MILK_AGENT_MODE = mode;
  const hooks = new Map(), commands = new Map();
  companion({on: (name, handler) => hooks.set(name, handler), registerCommand: (name, value) => commands.set(name, value)});
  let asked = 0;
  const ctx = {mode:'rpc', hasUI:true, ui:{select:async () => { asked++; return choices.shift(); }, setStatus:()=>{}}};
  return {hooks, commands, ctx, count:() => asked};
}
test('write is blocked before execution; read passes', async () => {
  const s = setup('approval', ['Deny']);
  assert.equal((await s.hooks.get('tool_call')({toolName:'write',input:{path:'a'}},s.ctx)).block,true);
  assert.equal(await s.hooks.get('tool_call')({toolName:'read',input:{}},s.ctx),undefined);
  assert.equal(s.count(),1);
});
test('once and session grants have distinct lifetimes', async () => {
  const s = setup('approval', ['Allow once','Allow for session','Deny']);
  const call = {toolName:'bash',input:{command:'echo hello'}};
  await s.hooks.get('tool_call')(call,s.ctx); await s.hooks.get('tool_call')(call,s.ctx); await s.hooks.get('tool_call')(call,s.ctx);
  assert.equal(s.count(),2);
  s.hooks.get('session_shutdown')();
  assert.equal((await s.hooks.get('tool_call')(call,s.ctx)).block,true);
});
test('autonomous passes; absent UI and direct bash fail closed', async () => {
  const a = setup('autonomous'); assert.equal(await a.hooks.get('tool_call')({toolName:'write',input:{}},a.ctx),undefined); assert.equal(a.count(),0);
  const b = setup(); b.ctx.hasUI = false;
  assert.equal((await b.hooks.get('tool_call')({toolName:'write',input:{}},b.ctx)).block,true);
  await assert.rejects(b.hooks.get('user_bash')({command:'echo hello'},b.ctx));
});

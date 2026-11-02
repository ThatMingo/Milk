/** Phase 1 only: trusted test integration, not staged into Milk.app. */
import { createReadTool, createWriteTool, createEditTool, createBashTool } from "@earendil-works/pi-coding-agent";
import { Type } from "@earendil-works/pi-ai";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
export default function(pi: any) {
  const cwd=process.cwd(); let counter=0;
  if(process.env.PHASE1_MCP_MARKER)pi.registerMcpServer("phase1",{
    command:"/usr/bin/python3",args:[process.env.PHASE1_MCP_SCRIPT!,process.env.PHASE1_MCP_MARKER],exposure:"direct",timeout:3
  });
  async function request(ctx: any, op: string, args: any, signal?: AbortSignal, invocation?: string) {
    const operation=String(++counter);
    const cancel=()=>ctx.ui.setStatus("phase1-cancel",operation);
    signal?.addEventListener("abort",cancel,{once:true});
    try {
      if(signal?.aborted) throw Error("aborted");
      const raw=await ctx.ui.input(JSON.stringify({phase1:1,operation,invocation,op,args}));
      const result=JSON.parse(raw || '{"error":"bridge unavailable"}');
      if(result.error)throw Error(result.error);
      return result.value;
    } finally {signal?.removeEventListener("abort",cancel);}
  }
  function bashOps(ctx: any) {return {exec:async(command: string, dir: string, opts: any)=>{
    const result=await request(ctx,"bash",{command,cwd:dir},opts.signal);
    opts.onData(Buffer.from(result.output));return {exitCode:result.exitCode};
  }};}
  // Factory implementations preserve Pi's read/write/edit/bash result contracts.
  for(const name of ["read","write","edit","bash"]) {
    const factory:any={read:createReadTool,write:createWriteTool,edit:createEditTool,bash:createBashTool}[name];
    const original=factory(cwd);
    pi.registerTool({...original,execute:async(id:any,args:any,signal:any,onUpdate:any,ctx:any)=>{
      let operations:any;
      const readFile=async(path:string)=>Buffer.from(await request(ctx,"read",{path},signal,id));
      const access=async(path:string)=>{await request(ctx,"access",{path},signal,id);};
      const writeFile=async(path:string,content:any)=>{await request(ctx,"write",{path,content:String(content)},signal);};
      if(name==="read")operations={readFile,access,detectImageMimeType:async()=>null};
      if(name==="write")operations={writeFile,mkdir:async(path:string)=>{await request(ctx,"mkdir",{path},signal);}};
      if(name==="edit")operations={readFile,access,writeFile};
      if(name==="bash")operations=bashOps(ctx);
      return factory(cwd,{operations}).execute(id,args,signal,onUpdate);
    }});
  }
  // Discovery-tool prototypes prove routing; not full stock grep/find/ls parity.
  for(const name of ["grep","find","ls"])pi.registerTool({
    name,description:"Phase1 routed "+name,
    parameters:Type.Object({path:Type.String(),pattern:Type.Optional(Type.String())}),
    execute:async(_id:any,args:any,signal:any,_update:any,ctx:any)=>({content:[{type:"text",text:await request(ctx,name,args,signal)}],details:undefined})
  });
  pi.registerTool({name:"phase1_nested",description:"Nested executor proof",parameters:Type.Object({}),
    execute:async(_id:any,_args:any,signal:any,onUpdate:any,ctx:any)=>
      ctx.executeTool("read",{path:"input.txt"},{signal,onUpdate})});
  pi.registerTool({name:"unsafe_custom",description:"Must never execute",parameters:Type.Object({}),
    execute:async()=>({content:[{type:"text",text:readFileSync(process.env.PHASE1_PROFILE_FILE!,"utf8")}],details:undefined})});
  pi.on("tool_call",(event:any)=>{
    if(!["read","write","edit","bash","grep","find","ls","phase1_nested","mcp__phase1__probe"].includes(event.toolName))
      return {block:true,reason:"Phase1 unsupported execution path; no host fallback"};
  });
  pi.on("user_bash",(_event:any,ctx:any)=>({operations:bashOps(ctx)}));
  pi.registerCommand("phase1-spawn-probe",{description:"Synthetic runtime spawn evidence",handler:async(_args:any,ctx:any)=>{
    let execBlocked=false, execInherited=false;
    try {const r=await pi.exec("/bin/sh",["-c",'test -n "$MILK_PI_LOCAL_KEY" && printf present']);execInherited=r.stdout.trim()==="present";execBlocked=r.code!==0;}
    catch {execBlocked=true;}
    const r=spawnSync("/bin/sh",["-c",'test -n "$MILK_PI_LOCAL_KEY" && printf present'],{encoding:"utf8"});
    ctx.ui.setStatus("phase1-spawn",JSON.stringify({runtimePid:process.pid,runtimeHasKey:!!process.env.MILK_PI_LOCAL_KEY,execBlocked,execInherited,customBlocked:!!r.error||r.status!==0,customInherited:r.stdout?.trim()==="present",profileReadable:readFileSync(process.env.PHASE1_PROFILE_FILE!,"utf8")==="profile-synthetic"}));
  }});
  pi.on("session_start",(_e:any,ctx:any)=>ctx.ui.setStatus("phase1-ready","1"));
}

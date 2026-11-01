/** Requests are data only; Milk owns live identities, policy, grants and launches. */
import { createReadTool, createWriteTool, createEditTool, createBashTool, createGrepTool, createFindTool, createLsTool } from "@earendil-works/pi-coding-agent";
import { Type } from "@earendil-works/pi-ai";
export function installSandboxBridge(pi:any) {
  const enabled=process.env.MILK_SANDBOX_ON==="1";
  if(!enabled)return;
  const factories:any={read:createReadTool,write:createWriteTool,edit:createEditTool,bash:createBashTool,grep:createGrepTool,find:createFindTool,ls:createLsTool};
  async function request(ctx:any,payload:any) {
    const raw=await ctx.ui.input(JSON.stringify({milkSandbox:1,...payload}));
    const response=JSON.parse(raw||'{"error":"Sandbox bridge unavailable"}');
    if(response.error)throw Error(response.error);return response;
  }
  async function execute(ctx:any,tool:string,args:any,signal:any,onUpdate:any) {
    if(signal?.aborted)throw Error("Operation aborted");
    const opened=await request(ctx,{kind:"begin",tool,args});
    const ownership={operation:opened.operation,capability:opened.capability};
    const cancel=()=>ctx.ui.setStatus("milk-sandbox-cancel",JSON.stringify(ownership));
    signal?.addEventListener("abort",cancel,{once:true});
    try {
      if(signal?.aborted){cancel();throw Error("Operation aborted");}
      while(true){
        const result=await request(ctx,{kind:"next",...ownership});
        if(signal?.aborted)throw Error("Operation aborted");
        if(result.update)onUpdate?.(result.update);
        if(result.bytes)onUpdate?.(Buffer.from(result.bytes,"base64"));
        if(result.done)return result.result;
      }
    } finally {signal?.removeEventListener("abort",cancel);ctx.ui.setStatus("milk-sandbox-finish",JSON.stringify(ownership));}
  }
  for(const [name,factory] of Object.entries(factories)) {
    const original=(factory as any)(process.cwd());
    const parameters=name==="bash"?Type.Object({...original.parameters.properties,sandboxFolders:Type.Optional(Type.Array(Type.Object({path:Type.String(),access:Type.Union([Type.Literal("readOnly"),Type.Literal("readWrite")])})))}):original.parameters;
    pi.registerTool({...original,parameters,
      description:original.description+(name==="bash"?" Outside-folder permissions must be requested explicitly in sandboxFolders; a denied command is never rerun automatically.":""),
      execute:async(_id:any,args:any,signal:any,onUpdate:any,ctx:any)=>execute(ctx,name,args,signal,onUpdate)});
  }
  pi.on("user_bash",(_event:any,ctx:any)=>({operations:{exec:async(command:string,_cwd:string,options:any)=>
    execute(ctx,"user_bash",{command},options.signal,options.onData)}}));
  pi.on("tool_call",(event:any)=>{
    if(!Object.hasOwn(factories,event.toolName))return{block:true,reason:"Unsupported execution route while Milk Sandbox is ON. No host fallback is available."};
  });
}

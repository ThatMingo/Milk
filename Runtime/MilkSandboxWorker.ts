/** Milk-owned per-operation entry point; loaded only by the sibling executor. */
import { createReadTool, createWriteTool, createEditTool, createBashTool, createGrepTool, createFindTool, createLsTool } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
export default function(pi: any) {
  const factories: any = {read:createReadTool,write:createWriteTool,edit:createEditTool,bash:createBashTool,grep:createGrepTool,find:createFindTool,ls:createLsTool};
  let used = false;
  pi.registerCommand("milk-operation", {description:"Milk private worker protocol",handler:async(raw:string,ctx:any)=>{
    if(used)throw Error("Worker cannot execute another operation"); used=true;
    const request=JSON.parse(raw);
    try {
      if(request.tool==="user_bash") {
        const result=await new Promise<any>((resolve,reject)=>{
          const child=spawn("/bin/bash",["-c",request.args.command],{cwd:process.cwd(),env:process.env,stdio:["ignore","pipe","pipe"]});
          child.stdout.on("data",(data:Buffer)=>ctx.ui.setStatus("milk-worker-update",JSON.stringify({bytes:data.toString("base64")})));
          child.stderr.on("data",(data:Buffer)=>ctx.ui.setStatus("milk-worker-update",JSON.stringify({bytes:data.toString("base64")})));
          child.on("error",reject);child.on("close",(exitCode:number)=>resolve({exitCode}));
        });
        ctx.ui.setStatus("milk-worker-result",JSON.stringify({result}));return;
      }
      const factory=factories[request.tool];if(!factory)throw Error("Unsupported worker tool");
      const result=await factory(process.cwd()).execute("milk-owned-operation",request.args,undefined,
        (update:any)=>ctx.ui.setStatus("milk-worker-update",JSON.stringify({update})));
      ctx.ui.setStatus("milk-worker-result",JSON.stringify({result}));
    } catch(error:any) {ctx.ui.setStatus("milk-worker-result",JSON.stringify({error:String(error?.message??error)}));}
  }});
  pi.on("session_start",(_e:any,ctx:any)=>ctx.ui.setStatus("milk-worker-ready","1"));
}

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
      // Stock Pi's local Bash backend uses detached:true. Use its public operations
      // hook here so ordinary shells/background children remain in Milk's owned group.
      const operations={exec:(command:string,cwd:string,options:any)=>new Promise<any>((resolve,reject)=>{
        const child=spawn("/bin/bash",["-c",command],{cwd,env:options.env??process.env,detached:false,stdio:["ignore","pipe","pipe"]});
        let settled=false;
        const finish=(error:any,exitCode?:number)=>{
          if(settled)return;settled=true;if(timer)clearTimeout(timer);
          child.stdout.destroy();child.stderr.destroy();
          error?reject(error):resolve({exitCode});
        };
        const timer=options.timeout?setTimeout(()=>finish(Error(`timeout:${options.timeout}`)),options.timeout*1000):undefined;
        child.stdout.on("data",options.onData);child.stderr.on("data",options.onData);
        child.on("error",(error:any)=>finish(error));
        child.on("exit",(code:number,signal:string)=>setTimeout(()=>finish(undefined,code??128),25));
      })};
      let result:any;
      if(request.tool==="user_bash") {
        result=await operations.exec(request.args.command,process.cwd(),{
          timeout:request.args.timeout,
          onData:(data:Buffer)=>ctx.ui.setStatus("milk-worker-update",JSON.stringify({bytes:data.toString("base64")}))
        });
      } else {
        const factory=factories[request.tool];if(!factory)throw Error("Unsupported worker tool");
        const tool=request.tool==="bash"?factory(process.cwd(),{operations}):factory(process.cwd());
        result=await tool.execute("milk-owned-operation",request.args,undefined,
          (update:any)=>ctx.ui.setStatus("milk-worker-update",JSON.stringify({update})));
      }
      ctx.ui.setStatus("milk-worker-result",JSON.stringify({result}));
    } catch(error:any) {ctx.ui.setStatus("milk-worker-result",JSON.stringify({error:String(error?.message??error)}));}
  }});
  pi.on("session_start",(_e:any,ctx:any)=>ctx.ui.setStatus("milk-worker-ready","1"));
}

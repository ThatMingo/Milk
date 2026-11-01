#!/usr/bin/env python3
"""Local deterministic OpenAI-compatible fixture. No model downloads or provider credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json,time,sys,os
class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def authorized(self):
        mode=os.environ.get('MILK_FIXTURE_AUTH')
        control=os.environ.get('MILK_FIXTURE_AUTH_FILE')
        if control:
            with open(control) as stream: mode=stream.read().strip()
        auth=self.headers.get('Authorization','')
        if mode=='none': return 'Authorization' not in self.headers
        if mode=='key': return auth=='Bearer fixture-local-secret'
        if mode=='external-key': return auth=='Bearer external-fixture-secret'
        return True
    def record(self, model=None):
        log=os.environ.get('MILK_FIXTURE_REQUEST_LOG')
        if log:
            with open(log,'a') as stream:
                stream.write(json.dumps({'method':self.command,'path':self.path,'model':model,'has_auth':'Authorization' in self.headers,'placeholder':self.headers.get('Authorization')=='Bearer local-no-auth'})+'\n')
    def do_GET(self):
        self.record()
        if not self.authorized(): self.send_error(401); return
        if self.path.startswith('/unauthorized/'):
            self.send_error(401); return
        if self.path=='/health': value={'status':'healthy'}
        elif self.path=='/v1/models': value={'data':[
            {'id':'milk-fixture','object':'model','context_window':64000,'max_tokens':4000,'reasoning':False,'input':['text']},
            {'id':'org/Qwen:Q4_K_M','object':'model','context_window':262144,'effective_context_window':64000,'max_tokens':4000,'reasoning':False,'input':['text']},
            {'id':'reasoning-fixture','object':'model','context_window':90000,'max_tokens':4000,'reasoning':True,'input':['text']}]}
        # These optional brand-specific routes serve the separately installed status example only.
        elif self.path=='/v1/models/status': value={'models':[{'id':'milk-fixture','state':'loaded','loaded':True}]}
        elif self.path=='/api/status': value={'status':'ok','model_memory_used':1048576}
        else: self.send_error(404); return
        data=json.dumps(value).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.record(body.get('model'))
        if not self.authorized(): self.send_error(401); return
        messages=body['messages']; last=messages[-1]; content=last.get('content') or ''
        if isinstance(content,list): content=' '.join(x.get('text','') for x in content)
        is_tool=last.get('role')=='tool'
        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
        def chunk(delta,finish=None):
            value={'id':'fixture','object':'chat.completion.chunk','created':1,'model':'milk-fixture','choices':[{'index':0,'delta':delta,'finish_reason':finish}]}
            self.wfile.write(('data: '+json.dumps(value)+'\n\n').encode());self.wfile.flush()
        try:
            chunk({'role':'assistant'})
            user_index=max((i for i,m in enumerate(messages) if m.get('role')=='user'),default=0)
            original=messages[user_index].get('content') or ''
            if isinstance(original,list): original=' '.join(x.get('text','') for x in original)
            grouped='grouped-fixture' in original
            tool_count=sum(m.get('role')=='tool' for m in messages[user_index+1:])
            preview_inspection='Inspect this project to determine its foreground local web development server' in original
            native_probe='native-tool-fixture' in original
            native_tools=[x.get('function',{}).get('name','') for x in body.get('tools',[]) if x.get('function',{}).get('name','').startswith('milk_')]
            if native_probe and not is_tool:
                selected=next((name for name in native_tools if name.endswith('_check')),None)
                if selected:
                    chunk({'tool_calls':[{'index':0,'id':'native-call-'+str(time.time_ns()),'type':'function','function':{'name':selected,'arguments':'{}'}}]},'tool_calls')
                else: chunk({'content':'Native tool unavailable'},'stop')
            elif native_probe and is_tool:
                chunk({'content':'Native tool output: '+str(content)},'stop')
            elif preview_inspection and tool_count < 2:
                name='read' if tool_count==0 else 'bash'
                args={'path':'web/package.json'} if tool_count==0 else {'command':"printf forbidden > preview-discovery-must-not-write.txt"}
                chunk({'tool_calls':[{'index':0,'id':'preview-call-'+str(tool_count),'type':'function','function':{'name':name,'arguments':json.dumps(args)}}]},'tool_calls')
            elif preview_inspection:
                chunk({'content':json.dumps({'command':'npm run preview:local','directory':'web'})},'stop')
            elif grouped and tool_count<2:
                chunk({'reasoning_content':'Inspecting the provided fixture.' if tool_count==0 else 'Checking the command result next.'})
                chunk({'content':'I will read the project file first.' if tool_count==0 else 'The file is available; I will run the check.'})
                if tool_count==1: time.sleep(float(os.environ.get('MILK_FIXTURE_APPROVAL_DELAY','0')))
                name='read' if tool_count==0 else 'bash'
                args={'path':'group-input.txt'} if tool_count==0 else {'command':'/usr/bin/printf "grouped command output"'}
                chunk({'tool_calls':[{'index':0,'id':'grouped-call-'+str(tool_count),'type':'function','function':{'name':name,'arguments':json.dumps(args)}}]},'tool_calls')
            elif grouped:
                chunk({'content':'The grouped fixture check is complete.'},'stop')
            elif not is_tool and ('write-fixture' in content or 'pause-fixture' in content):
                if 'pause-fixture' in content: name='bash';args={'command':'/bin/sleep 2; /usr/bin/printf "fixture command output"'}
                else: name='write';args={'path':'agent-created.txt','content':'from fixture\n'}
                chunk({'tool_calls':[{'index':0,'id':'call-fixture-'+str(time.time_ns()),'type':'function','function':{'name':name,'arguments':json.dumps(args)}}]},'tool_calls')
            elif not is_tool and 'quality-markdown' in content:
                for index in range(160):
                    section=(f'## Step {index+1}: request lifecycle\n\n'
                             'The coordinator keeps **one stable response** while `request` grows. This paragraph describes the implementation tradeoff and includes enough ordinary text to wrap across multiple lines.\n\n'
                             '- Keep the completed prefix intact.\n- Update only the active response tail.\n\n'
                             '```swift\nfunc handle(_ input: String) async throws -> String {\n    let value = try await service.respond(to: input)\n    return value\n}\n```\n\n')
                    for start in range(0,len(section),32):
                        chunk({'content':section[start:start+32]});time.sleep(.012)
                chunk({},'stop')
            elif not is_tool and 'quality-thinking' in content:
                for index in range(140):
                    chunk({'reasoning_content':f'Checking request boundary {index+1}. '});time.sleep(.08)
                for text in ['I checked the request lifecycle.\n\n','The completed response stays in the same logical turn.']:
                    chunk({'content':text});time.sleep(.3)
                chunk({},'stop')
            elif not is_tool and 'chat-scroll-fixture' in content:
                for index in range(120):
                    chunk({'content':f'### Stream section {index + 1}\n\nA growing **Markdown** paragraph with `code` and enough text to wrap naturally in the native chat window.\n\n- Inspect the streamed content\n- Keep the reading position stable\n\n'})
                    time.sleep(.08)
                chunk({},'stop')
            elif not is_tool and 'slow-fixture' in content:
                for _ in range(100): chunk({'content':'streaming fixture '});time.sleep(.1)
                chunk({},'stop')
            else:
                for text in ['Fixture **response** with `code`.\n','```swift\nlet milk = true\n```\n','[Pi](https://pi.dev)']:
                    chunk({'content':text});time.sleep(.025)
                chunk({},'stop')
            self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError): pass
        self.close_connection=True
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_address[1],flush=True)
server.serve_forever()

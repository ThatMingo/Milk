"""Synthetic stdio MCP server: reports inheritance as a Boolean, never a value."""
import json, os, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'inherited':bool(os.environ.get('MILK_PI_LOCAL_KEY'))}))
for line in sys.stdin:
    r=json.loads(line)
    if 'id' not in r:continue
    method=r.get('method')
    if method=='initialize':value={'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'phase1','version':'1'}}
    elif method=='tools/list':value={'tools':[{'name':'probe','description':'synthetic probe','inputSchema':{'type':'object','properties':{}}}]}
    elif method=='tools/call':value={'content':[{'type':'text','text':'synthetic-mcp'}]}
    else:value={}
    print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':value}),flush=True)

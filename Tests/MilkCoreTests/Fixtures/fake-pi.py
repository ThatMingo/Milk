import json, sys, threading, time
session = sys.argv[1] if len(sys.argv) > 1 else 'synthetic'
lock = threading.Lock()
def emit(value):
    with lock:
        sys.stdout.write(json.dumps(value, ensure_ascii=False) + '\n')
        sys.stdout.flush()
def handle(record):
    kind = record['type']
    if kind == 'hang': return
    if kind == 'exit': sys.exit(17)
    if kind == 'malformed':
        sys.stdout.write('{invalid\n'); sys.stdout.flush(); return
    def response():
        if kind == 'slow': time.sleep(.15)
        emit({'type':'response', 'id':record.get('id'), 'command':kind, 'success':True,
              'data':{'sessionId':session, 'echo':record.get('value', ''), 'isStreaming':False}})
    if kind == 'slow': threading.Thread(target=response, daemon=True).start()
    else: response()
for line in sys.stdin:
    handle(json.loads(line))

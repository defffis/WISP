"""Standalone UI in an actual browser; the router is never contacted."""
import http.server,json,os,shutil,socket,subprocess,tempfile,threading,time
from pathlib import Path
from browser import Browser
ROOT=Path(__file__).resolve().parents[1]
INJECT='''<script>
window.fixture={ok:true,version:'0.5.0',phase:'OFF',remaining:0,transaction:'a'.repeat(32),can_confirm:false,persistent:false};
window.prompt=()=>window.promptAnswer ?? null;window.fixture.clients={phase:'IDLE',requested:0,failed:0};window.calls=[];window.delay=0;window.confirm=()=>true;
window.fetch=async(url,options={})=>{
 if(window.networkDown)throw new TypeError('Нет связи с роутером. Проверьте подключение.');
 const op=options.body?options.body.split(' ')[0]:'status';window.calls.push(op);
 if(window.delay)await new Promise(r=>setTimeout(r,window.delay));
 if(window.signedOut)return new Response('{}',{status:401});
 if(op==='status')return new Response(JSON.stringify(window.fixture),{headers:{'X-WISP-CSRF':'b'.repeat(32)}});
 if(window.nextError){let msg=window.nextError;window.nextError=null;return new Response(JSON.stringify({ok:false,msg}));}
 if(op==='start'){Object.assign(window.fixture,{phase:'PENDING',remaining:180});if(window.dropStartResponse){window.networkDown=true;throw new TypeError('offline');}}
 if(op==='reconnect')Object.assign(window.fixture,{clients:{phase:'DONE',requested:3,failed:0}});
 if(op==='uninstall')Object.assign(window.fixture,{phase:'REMOVING'});
 if(op==='confirm')Object.assign(window.fixture,{phase:'ACTIVE',persistent:true,remaining:0});
 if(op==='rollback')Object.assign(window.fixture,{phase:'ROLLED_BACK',persistent:false,remaining:0});
 return new Response(JSON.stringify({ok:true}));
};</script>'''
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  path=self.path.split('?')[0];p=ROOT/'src/web'/({'/':'index.html','/en':'index.html'}.get(path,path.lstrip('/')))
  if path=='/locale-en.js':p=ROOT/'src/locales/en/locale.js'
  if not p.is_file(): self.send_error(404); return
  data=p.read_bytes()
  if path=='/en':data=data.replace(b'/locale.js',b'/locale-en.js')
  if path in ['/','/en']:data=data.replace(b'<script src="/app.js"',INJECT.encode()+b'<script src="/app.js"')
  self.send_response(200);self.send_header('Content-Type', 'application/javascript; charset=utf-8' if path.endswith('.js') else 'text/css' if path.endswith('.css') else 'text/html; charset=utf-8');self.end_headers();self.wfile.write(data)
 def log_message(self,*args):pass

def main():
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
 with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
 binary=next((p for p in [os.environ.get('WISP_TEST_BROWSER'),shutil.which('google-chrome'),shutil.which('chromium'),r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'] if p and Path(p).is_file()),None)
 assert binary,'Chromium required'
 results=[]
 with tempfile.TemporaryDirectory(dir=ROOT/'work') as profile:
  proc=subprocess.Popen([binary,'--headless=new','--disable-gpu','--no-first-run','--no-sandbox',f'--remote-debugging-port={port}',f'--remote-allow-origins=http://localhost:{port}','--user-data-dir='+profile,'about:blank'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
  try:
   b=Browser(port);b.call('Page.navigate',url=f'http://127.0.0.1:{server.server_port}/');b.wait("document.querySelector('#state')?.textContent==='WISP выключен'")
   assert b.js("document.querySelector('#start').hidden && !document.querySelector('#check').hidden")
   results.append('OFF starts with read-only check; enable is unavailable until successful review')
   assert b.js("!document.querySelector('#reconnect').hidden && !document.querySelector('#reconnect').disabled")
   b.click('#reconnect');b.wait("document.querySelector('#notice').textContent.includes('Wi-Fi-клиентам: 3')")
   results.append('Repeater mode exposes working Wi-Fi reconnect without enabling WISP')
   b.screenshot('standalone-off-desktop.png');b.screenshot('standalone-off-mobile.png',390,844)
   assert b.js('document.documentElement.scrollWidth<=innerWidth');results.append('Desktop/mobile layout has no horizontal overflow')
   b.js("window.nextError='<img src=x onerror=alert(1)>'");b.click('#check');b.wait("document.querySelector('#notice').textContent.includes('<img')")
   assert b.js("document.querySelector('#start').hidden && !document.querySelector('#notice img')");results.append('Failed check cannot enable WISP; messages render as text')
   b.js('window.delay=200');b.click('#check');b.click('#check');b.wait("!document.querySelector('#start').hidden")
   assert b.js("window.calls.filter(x=>x==='check').length===2");b.js('window.delay=0');results.append('Read-only check/review and duplicate click suppression')
   b.js('window.dropStartResponse=true');b.click('#start');b.wait("!document.querySelector('#newlink').hidden")
   assert b.js("document.querySelector('#notice').textContent.includes('Без подтверждения')");results.append('Lost activation response provides new HTTPS address and rollback guidance')
   b.js('window.networkDown=false;window.dropStartResponse=false');b.click('#retry');b.wait("document.querySelector('#state').textContent==='Проверьте подключение'")
   assert b.js("document.querySelector('#confirm').hidden && !document.querySelector('#newlink').hidden");results.append('Old LAN session cannot display confirmation action')
   b.js('window.fixture.can_confirm=true');b.click('#retry');b.wait("!document.querySelector('#confirm').hidden")
   b.screenshot('standalone-pending-mobile.png',390,844);b.click('#confirm');b.wait("document.querySelector('#state').textContent==='Интернет через Wi-Fi'")
   assert b.js("document.querySelector('#boot').textContent.includes('автоматически')");results.append('New LAN confirmation persists only after ACTIVE status')
   assert b.js("!document.querySelector('#reconnect').hidden")
   b.click('#reconnect');b.wait("document.querySelector('#notice').textContent.includes('Wi-Fi-клиентам: 3')")
   results.append('ACTIVE reconnect button requests only Wi-Fi and reports accepted clients')
   b.screenshot('standalone-active-mobile.png',390,844);b.click('#rollback');b.wait("document.querySelector('#state').textContent==='WISP выключен'")
   assert b.js("document.querySelector('#start').hidden");results.append('Disable returns to OFF and requires a fresh check')
   b.js('window.signedOut=true');b.click('#retry');b.wait("document.querySelector('#notice').textContent.includes('Войдите заново')")
   assert b.js("document.querySelector('#start').hidden && document.querySelector('#rollback').hidden");results.append('Expired authentication hides controls with login guidance')
   b.js('window.signedOut=false');b.click('#retry');b.wait("!document.querySelector('#check').hidden")
   for phase in ['OFF','SNAPSHOT','STARTING','PENDING','ACTIVE','TEST','APPLYING','ROLLING_BACK','ROLLED_BACK','ABORTED','RECOVERY_FAILED','UNKNOWN']:
    b.js("window.fixture.phase="+json.dumps(phase));b.click('#retry')
    b.wait("!document.querySelector('#uninstall').disabled")
    assert b.js("!document.querySelector('#uninstall').hidden")
   results.append('Full removal control remains available in every operational/error state')
   b.js('window.promptAnswer=null');before=b.js("window.calls.length");b.click('#uninstall')
   assert b.js('window.calls.length')==before
   b.js("window.promptAnswer='DELETE'");b.click('#uninstall');assert b.js('window.calls.length')==before
   results.append('Removal cancelled or mistyped confirmation never reaches API')
   b.js("window.promptAnswer='УДАЛИТЬ'");b.click('#uninstall');b.wait("document.querySelector('#state').textContent==='Удаление WISP запущено'")
   assert b.js("document.querySelector('#uninstall').disabled && window.calls.filter(x=>x==='uninstall').length===1")
   results.append('Explicit full removal shows queued progress without falsely declaring completion')
   b.screenshot('standalone-removing-mobile.png',390,844)
   b.js("window.fixture.phase='ROLLED_BACK';window.fixture.remove_error='Удаление остановлено, данные сохранены'")
   b.wait("!document.querySelector('#uninstall').disabled && document.querySelector('#notice').textContent.includes('данные сохранены')")
   b.js("window.fixture.phase='REMOVING';window.fixture.remove_error=''");b.click('#retry')
   b.wait("document.querySelector('#state').textContent==='Удаление WISP запущено'")
   b.js("window.fixture.phase='ROLLED_BACK';window.fixture.remove_error='Данные сохранены после ошибки'")
   b.wait("!document.querySelector('#uninstall').disabled && document.querySelector('#notice').textContent.includes('Данные сохранены')")
   results.append('Queued removal errors remain visible and retryable, including reopening during removal')
   b.call('Page.navigate',url=f'http://127.0.0.1:{server.server_port}/en')
   b.wait("document.documentElement.lang==='en' && document.querySelector('#state').textContent==='WISP is off'")
   assert b.js("document.querySelector('#reconnect').textContent==='Reconnect all Wi-Fi clients' && !document.querySelector('#reconnect').hidden")
   assert b.js("Array.from(document.querySelectorAll('button')).every(x=>!/[А-Яа-я]/.test(x.textContent))")
   assert b.js("document.querySelector('footer a').href==='https://github.com/defffis/WISP'")
   b.click('#reconnect');b.wait("document.querySelector('#notice').textContent.includes('Wi-Fi clients: 3')")
   b.screenshot('standalone-en-off-mobile.png',390,844)
   assert b.js('document.documentElement.scrollWidth<=innerWidth')
   b.js("window.promptAnswer='УДАЛИТЬ'");before=b.js('window.calls.length');b.click('#uninstall');assert b.js('window.calls.length')==before
   b.js("window.promptAnswer='DELETE'");b.click('#uninstall');b.wait("document.querySelector('#state').textContent==='WISP removal started'")
   results.append('English panel, repeater reconnect, repository link and localized deletion confirmation')
   b.ws.close()
  finally:
   proc.terminate();proc.wait(timeout=10);server.shutdown();time.sleep(.5)
 (ROOT/'work/ui-results.json').write_text(json.dumps([dict(test=s,result='PASS') for s in results],ensure_ascii=False,indent=2),encoding='utf-8')
 print(f'{len(results)} isolated actual-browser UI checks passed.')
if __name__=='__main__':main()

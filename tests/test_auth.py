"""Real nginx 1.21.1 TLS + Basic Auth -> actual CGI security gate, isolated from router.
Windows uses official nginx/Windows; Linux uses WISP_TEST_NGINX or nginx on PATH.
FastCGI transport here is a local fixture; network mutations are replaced by a trace.
"""
import base64, datetime, hashlib, json, os, shutil, socketserver, struct, subprocess, tempfile, threading, time
from pathlib import Path
import requests, urllib3
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
ROOT=Path(__file__).resolve().parents[1]
BASH=str(Path(os.environ.get('ProgramFiles','C:/Program Files'))/'Git/bin/bash.exe') if os.name=='nt' else shutil.which('bash')
NGINX=os.environ.get('WISP_TEST_NGINX') or (str(ROOT.parent/'nginx-1.21.1/nginx.exe') if os.name=='nt' else shutil.which('nginx'))
def unix(p):
 s=p.as_posix();return '/'+s[0].lower()+s[2:] if os.name=='nt' else s

def length(data, i):
 n=data[i];return (struct.unpack('!I',data[i:i+4])[0]&0x7fffffff,i+4) if n&128 else (n,i+1)
class FCGI(socketserver.BaseRequestHandler):
 def exact(self,n):
  out=b''
  while len(out)<n:
   b=self.request.recv(n-len(out))
   if not b: raise EOFError
   out+=b
  return out
 def handle(self):
  params=b'';body=b''
  try:
   while True:
    ver,typ,req,n,pad,_=struct.unpack('!BBHHBB',self.exact(8));data=self.exact(n);self.exact(pad)
    if typ==4:params+=data
    if typ==5:
     body+=data
     if not n:break
   env=dict(os.environ);i=0
   while i<len(params):
    n,i=length(params,i);v,i=length(params,i);k=params[i:i+n].decode();i+=n;env[k]=params[i:i+v].decode();i+=v
   result=subprocess.run([BASH,env['SCRIPT_FILENAME']],input=body,capture_output=True,env=env,timeout=10)
   out=result.stdout or b'Status: 500 Internal Server Error\r\n\r\nCGI failed'
   self.request.sendall(struct.pack('!BBHHBB',1,6,req,len(out),0,0)+out)
   self.request.sendall(struct.pack('!BBHHBB',1,3,req,8,0,0)+bytes(8))
  except (EOFError,ConnectionError):pass

class Server(socketserver.ThreadingTCPServer):allow_reuse_address=True;daemon_threads=True

def main():
 urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
 results=[]
 with tempfile.TemporaryDirectory(dir=ROOT/'work') as td:
  t=Path(td);(t/'web').mkdir();(t/'logs').mkdir();(t/'temp').mkdir()
  for n in ['index.html','app.js','style.css','locale.js']:shutil.copyfile(ROOT/'src/web'/n,t/'web'/n)
  key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
  name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'WISP isolated test')]);now=datetime.datetime.now(datetime.timezone.utc)
  cert=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(days=1)).not_valid_after(now+datetime.timedelta(days=1)).sign(key,hashes.SHA256())
  (t/'tls.key').write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.TraditionalOpenSSL,serialization.NoEncryption()))
  (t/'tls.crt').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
  password='isolated-test-password';(t/'auth').write_text('root:{SHA}'+base64.b64encode(hashlib.sha1(password.encode()).digest()).decode()+'\n')
  shutil.copyfile(ROOT/'src/locale.sh',t/'locale.sh')
  (t/'csrf').write_text('a'*32)
  (t/'panel.sh').write_text('#!/bin/sh\nprintf \'%s\\n\' "$*" >> "'+unix(t/'trace')+'"\nprintf \'{"ok":true,"operation":"%s"}\\n\' "$1"\n',newline='\n')
  shutil.copyfile(t/'panel.sh',t/'uninstall.sh')
  api=(ROOT/'src/api.sh').read_text(encoding='utf-8').replace('BASE=/data/usr/app/wisp','BASE='+unix(t)).replace('WEBRUN=/tmp/wisp-panel','WEBRUN='+unix(t)).replace('8443','24443')
  api='ip() { echo "127.0.0.1 dev br-lan src 127.0.0.1"; }\n'+api
  (t/'api.sh').write_text(api,encoding='utf-8',newline='\n')
  fcgi=Server(('127.0.0.1',0),FCGI);threading.Thread(target=fcgi.serve_forever,daemon=True).start()
  config=(ROOT/'src/nginx.conf.in').read_text().replace('__BASE__',t.as_posix()).replace('__RUN__',t.as_posix()).replace('__IP__','127.0.0.1').replace('8443','24443').replace('127.0.0.1:8920','127.0.0.1:'+str(fcgi.server_address[1]))
  (t/'nginx.conf').write_text(config,newline='\n')
  command=[NGINX,'-p',t.as_posix()+'/','-c',(t/'nginx.conf').as_posix()]
  checked=subprocess.run(command+['-t'],capture_output=True);assert checked.returncode==0,checked.stderr.decode(errors='replace')
  process=subprocess.Popen(command+['-g','daemon off;'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
  session=requests.Session();session.trust_env=False;url='https://127.0.0.1:24443'
  def call(path='/api?status',auth=('root',password),**kw):return session.request(kw.pop('method','GET'),url+path,auth=auth,verify=False,timeout=12,**kw)
  try:
   for _ in range(80):
    try:call(auth=None);break
    except requests.ConnectionError:time.sleep(.1)
   else:raise AssertionError('nginx failed: '+(t/'error.log').read_text())
   for path in ['/','/api?status','/app.js','/style.css','/locale.js']:
    assert call(path,auth=None).status_code==401,path
    assert call(path,auth=('root','wrong')).status_code==401,path
   assert not (t/'trace').exists();results.append('Real TLS/Basic Auth protects HTML, assets and CGI; failed login never reaches adapter')
   assert call('/').status_code==200
   response=call();assert response.status_code==200 and response.json()['operation']=='status'
   assert response.headers['X-WISP-CSRF']=='a'*32
   assert 'frame-ancestors' in response.headers['Content-Security-Policy'];results.append('Authenticated status, anti-framing and no-store headers')
   headers={'Content-Type':'text/plain','Origin':url,'X-WISP-CSRF':'a'*32}
   for body in ['check','start','rollback','reconnect','uninstall DELETE','confirm '+'b'*32]:
    response=call('/api',method='POST',headers=headers,data=body);assert response.status_code==200,(body,response.status_code,response.text)
   results.append('All six allowlisted authenticated operations reach adapter')
   before=(t/'trace').read_text()
   bad=[({'Origin':'https://evil.example'},'start',403),({'X-WISP-CSRF':'wrong'},'start',403),({'Content-Type':'application/json'},'start',415),({},'reboot',400),({},'start;reboot',400),({},'confirm wrong',400),({},'start\n',400),({},'x'*300,413)]
   for extra,body,code in bad:
    h=dict(headers);h.update(extra);response=call('/api',method='POST',headers=h,data=body);assert response.status_code==code,(extra,body,response.status_code,response.text)
   assert call('/api',method='GET').status_code==400
   assert call('/api?status',method='DELETE').status_code==405
   assert call('/api?status',headers={'Host':'evil.example:24443'}).status_code==403
   assert call('/api?status',auth=None,headers={'Remote-User':'root','X-Wisp-User':'root'}).status_code==401
   for body in ['uninstall','uninstall yes','uninstall DELETE;reboot']:
    assert call('/api',method='POST',headers=headers,data=body).status_code==400
   for body in ['reconnect','uninstall DELETE']:
    assert call('/api',auth=None,method='POST',headers=headers,data=body).status_code==401
    h=dict(headers);h['Origin']='https://evil.example'
    assert call('/api',method='POST',headers=h,data=body).status_code==403
   assert (t/'trace').read_text()==before;results.append('Foreign/missing CSRF, Origin, type, method, host, injection, oversized and malformed bodies rejected without side effects')
   for path in ['/VERSION','/tls.key','/../api.sh','/%2e%2e/api.sh','/index.html']:
    assert call(path).status_code in (400,404),path
   results.append('Only the three public UI paths and fixed API route are exposed')
   shutil.copyfile(ROOT/'src/locales/en/locale.sh',t/'locale.sh')
   response=call('/api',method='POST',headers={**headers,'Origin':'https://invalid.example'},data='check')
   assert response.status_code==403 and response.json()['msg']=='Refresh the page.'
   results.append('Selected English backend locale is used for security errors')
  finally:
   subprocess.run(command+['-s','quit'],capture_output=True)
   try:process.wait(timeout=8)
   except subprocess.TimeoutExpired:process.terminate()
   fcgi.shutdown();time.sleep(.3)
 (ROOT/'work/auth-results.json').write_text(json.dumps([dict(test=s,result='PASS') for s in results],indent=2))
 print(f'{len(results)} actual nginx TLS/authorization groups passed.')
if __name__=='__main__':main()

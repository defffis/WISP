import json,time,base64
from pathlib import Path
import requests,websocket
OUT=Path(__file__).resolve().parents[1]/"work/ui"
OUT.mkdir(parents=True,exist_ok=True)
class Browser:
    def __init__(self, port):
        session = requests.Session(); session.trust_env = False
        for _ in range(80):
            try:
                targets = session.get(f'http://127.0.0.1:{port}/json', timeout=1).json()
                target = next(t for t in targets if t['type'] == 'page')
                break
            except (requests.RequestException, StopIteration): time.sleep(.1)
        else: raise RuntimeError('Browser did not start')
        self.ws = websocket.create_connection(target['webSocketDebuggerUrl'], origin=f'http://localhost:{port}')
        self.id = 0
    def call(self, method, **params):
        self.id += 1
        self.ws.send(json.dumps(dict(id=self.id, method=method, params=params)))
        while True:
            result = json.loads(self.ws.recv())
            if result.get('id') == self.id:
                if 'error' in result: raise RuntimeError(result['error'])
                return result.get('result', {})
    def js(self, expression):
        result = self.call('Runtime.evaluate', expression=expression, returnByValue=True, awaitPromise=True)
        if 'exceptionDetails' in result: raise RuntimeError(result['exceptionDetails'])
        return result.get('result', {}).get('value')
    def wait(self, expression):
        for _ in range(80):
            if self.js(expression): return
            time.sleep(.1)
        raise AssertionError('Timed out: ' + expression)
    def click(self, selector):
        # Fresh DOM observation before each interaction.
        assert self.js(f"document.querySelectorAll({json.dumps(selector)}).length===1"), selector
        self.js(f"document.querySelector({json.dumps(selector)}).click()")
    def screenshot(self, name, width=1280, height=900):
        self.call('Emulation.setDeviceMetricsOverride', width=width, height=height, deviceScaleFactor=1, mobile=width<600)
        time.sleep(.15)
        result = self.call('Page.captureScreenshot', format='png')
        (OUT / name).write_bytes(base64.b64decode(result['data']))

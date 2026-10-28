"""Isolated standard-library Hermes wire fixture. Never opens a real Hermes home."""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import socketserver
import struct
import sys
import threading

home = Path(sys.argv[1])
state_file = home / 'fixture-state.json'
control = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
control.bind(str(home / 'gateway.sock'))
os.chmod(home / 'gateway.sock', 0o600)
control.listen()


def state():
    return json.loads(state_file.read_text())


def event(seq, kind, payload, epoch):
    return dict(seq=seq, type=kind, payload=payload, replay_epoch=epoch, session_id='test-session')


class Gateway(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path != '/api/ws' or 'hermes-gateway-ticket.fixture-ticket' not in self.headers.get('Sec-WebSocket-Protocol', ''):
            self.send_error(403)
            return
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.send_header('Sec-WebSocket-Protocol', 'hermes-gateway-v1')
        self.end_headers()
        while True:
            header = self.rfile.read(2)
            if len(header) != 2 or header[0] & 15 == 8:
                return
            n = header[1] & 127
            if n == 126:
                n = struct.unpack('!H', self.rfile.read(2))[0]
            elif n == 127:
                n = struct.unpack('!Q', self.rfile.read(8))[0]
            mask = self.rfile.read(4) if header[1] & 128 else b''
            data = self.rfile.read(n)
            if mask:
                data = bytes(v ^ mask[i % 4] for i, v in enumerate(data))
            request = json.loads(data)
            result = self.rpc(request)
            reply = json.dumps(dict(jsonrpc='2.0', id=request['id'], result=result)).encode()
            prefix = bytes([0x81, len(reply)]) if len(reply) < 126 else bytes([0x81, 126]) + struct.pack('!H', len(reply))
            self.wfile.write(prefix + reply)
            self.wfile.flush()

    def rpc(self, request):
        method, params, current = request['method'], request['params'], state()
        with (home / 'calls.jsonl').open('a') as log:
            log.write(json.dumps(request) + '\n')
        epoch = current.get('epoch', 'epoch-one')
        if method == 'session.active_list':
            rows = [] if current['status'] == 'offline' else [dict(id='test-session', source=current.get('source', 'desktop'), title='Fixture task', status=current['status'])]
            if rows and 'message_count' in current:
                rows[0]['message_count'] = current['message_count']
            return dict(sessions=rows)
        if method == 'session.stats':
            return dict(context_tokens=32000, context_length=128000, total_tokens=9000000)
        if method == 'session.events.since':
            frames = [event(1, 'message.start', {}, epoch), event(2, 'tool.start', dict(name='terminal', args=dict(command='swift test')), epoch)]
            if current['status'] == 'idle':
                frames.append(event(3, 'message.complete', dict(text='All tests passed', status='complete', error=None), epoch))
            latest = frames[-1]['seq']
            missing = params.get('replay_epoch') != epoch
            return dict(replay_epoch=epoch, last_sequence=latest, snapshot_required=missing,
                        events=[] if missing else [e for e in frames if e['seq'] > params['last_sequence']])
        if method == 'session.resume':
            return dict(execution_generation=12)
        if method in ('prompt.submit', 'session.interrupt'):
            return dict(accepted=True)
        if method == 'session.close':
            assert params['session_id'] == 'test-session'
            current['status'] = 'offline'
            state_file.write_text(json.dumps(current))
            return dict(closed=True)
        raise AssertionError(method)


class LocalHTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer normally reverse-resolves the host here. The wire fixture
        # is loopback-only and must not depend on a runner's DNS configuration.
        socketserver.TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]


http = LocalHTTPServer(('127.0.0.1', 0), Gateway)
threading.Thread(target=http.serve_forever, daemon=True).start()


def control_loop():
    while True:
        conn, _ = control.accept()
        with conn:
            request = json.loads(conn.makefile('rb').readline())
            if request['verb'] == 'identify':
                result = dict(state='ready', instance_id='fixture', api_origin=f'http://127.0.0.1:{http.server_port}',
                              capabilities=['session-authority-v1'], served_profiles=[dict(profile_id=str(home))])
            else:
                assert request['verb'] == 'session-ticket'
                assert request['params']['instance_id'] == 'fixture'
                result = dict(ticket='fixture-ticket', profile_id=str(home), instance_id='fixture')
            conn.sendall(json.dumps(dict(protocol=1, id=request['id'], ok=True, result=result)).encode() + b'\n')


threading.Thread(target=control_loop, daemon=True).start()
(home / 'ready').touch()
threading.Event().wait()

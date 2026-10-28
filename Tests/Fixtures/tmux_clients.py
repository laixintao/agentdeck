"""Keep real PTY clients attached to the test's private tmux socket."""
import os
import pty
import select
import signal
import sys

running = True


def stop(*_):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
clients = []
try:
    for session in sys.argv[3:]:
        pid, master = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('TMUX', None)
            os.environ.pop('TMUX_PANE', None)
            os.execl(sys.argv[1], 'tmux', '-S', sys.argv[2], 'attach-session', '-t', session)
        clients.append((pid, master))
    while running:
        readable, _, _ = select.select([fd for _, fd in clients], [], [], .1)
        for fd in readable:
            try:
                if not os.read(fd, 65536):
                    running = False
            except OSError:
                running = False
finally:
    for pid, fd in clients:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.close(fd)
        os.waitpid(pid, 0)

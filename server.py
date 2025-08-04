import socket
import threading
import json
import os
import tkinter as tk
from tkinter import messagebox, scrolledtext
from datetime import datetime

HOST, PORT = '0.0.0.0', 12345
REGISTERED_FILE = 'registered.json'

class ChatServer:
    def __init__(self):
        # Active connections
        self.clients        = {}   # nick -> (conn, addr)
        self.banned         = set()
        self.sessions       = set()   # frozenset({nick1,nick2})
        self.data_transfers = {}   # frozenset -> bytes transferred
        self.sessions_msgs  = {}   # frozenset -> [ (timestamp, pkt_dict) ]
        self.lock           = threading.Lock()

        # Persisted registry of all users ever connected
        self.registered = set()
        self._load_registered()

        # Admin GUI
        self.root = tk.Tk()
        self.root.title("Admin Chat Panel")
        left = tk.Frame(self.root); left.pack(side=tk.LEFT, padx=5, pady=5)
        tk.Label(left, text="Онлайн:").pack()
        self.lb_users = tk.Listbox(left, width=20, height=20); self.lb_users.pack()
        mid = tk.Frame(self.root); mid.pack(side=tk.LEFT, padx=5, pady=5)
        tk.Label(mid, text="Сессии:").pack()
        self.lb_sess = tk.Listbox(mid, width=40, height=20); self.lb_sess.pack()
        right = tk.Frame(self.root); right.pack(side=tk.LEFT, fill=tk.Y, padx=5, pady=5)
        tk.Button(right, text="Ban user", command=self.ban_selected).pack(fill=tk.X, pady=2)
        tk.Button(right, text="Просмотреть чат", command=self.view_session).pack(fill=tk.X, pady=2)
        tk.Button(right, text="Обновить", command=self.refresh).pack(fill=tk.X, pady=2)
        tk.Label(right, text="Log:").pack(anchor='w')
        self.log = scrolledtext.ScrolledText(right, state='disabled', height=10); self.log.pack()
        self._last_pairs = []

        threading.Thread(target=self.run_server, daemon=True).start()
        self.root.after(200, self.refresh)
        self.root.mainloop()

    def _load_registered(self):
        if os.path.exists(REGISTERED_FILE):
            try:
                with open(REGISTERED_FILE, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    self.registered = set(data)
            except Exception:
                self.registered = set()

    def _save_registered(self):
        try:
            with open(REGISTERED_FILE, 'w', encoding='utf-8') as f:
                json.dump(list(self.registered), f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    def log_msg(self, txt):
        self.log.configure(state='normal')
        self.log.insert(tk.END, txt + "\n")
        self.log.configure(state='disabled')
        self.log.see(tk.END)

    def refresh(self):
        with self.lock:
            users = list(self.clients.keys())
            pairs = sorted(self.sessions, key=lambda s: tuple(sorted(s)))
            self._last_pairs = pairs
            sess_lines = []
            for s in pairs:
                a, b = sorted(s)
                bts = self.data_transfers.get(s, 0)
                sess_lines.append(f"{a} ↔ {b} : {bts} байт")
        self.lb_users.delete(0, tk.END)
        for u in users: self.lb_users.insert(tk.END, u)
        self.lb_sess.delete(0, tk.END)
        for line in sess_lines: self.lb_sess.insert(tk.END, line)

    def ban_selected(self):
        sel = self.lb_users.curselection()
        if not sel: return
        nick = self.lb_users.get(sel[0])
        if messagebox.askyesno("Ban", f"Забанить {nick}?"):
            threading.Thread(target=self.ban_user, args=(nick,), daemon=True).start()

    def ban_user(self, nick):
        with self.lock:
            if nick not in self.clients: return
            conn, _ = self.clients.pop(nick)
            self.banned.add(nick)
            # terminate sessions
            for s in list(self.sessions):
                if nick in s:
                    other = next(iter(s - {nick}))
                    try:
                        pkt = {"type":"end_encryption","from":nick,"to":other,"reason":"ban"}
                        self.clients[other][0].sendall((json.dumps(pkt)+"\n").encode())
                    except: pass
                    self.sessions.discard(s)
            try:
                conn.sendall((json.dumps({"type":"ban"})+"\n").encode())
            except: pass
            conn.close()
        self.broadcast_user_list()
        self.log_msg(f"[BAN] {nick}")
        self.root.after(100, self.refresh)

    def view_session(self):
        sel = self.lb_sess.curselection()
        if not sel: return
        pair = self._last_pairs[sel[0]]
        a, b = sorted(pair)
        win = tk.Toplevel(self.root)
        win.title(f"Chat {a} ↔ {b}")
        txt = scrolledtext.ScrolledText(win, state='normal', width=80, height=20); txt.pack(fill=tk.BOTH, expand=True)
        for ts, pkt in self.sessions_msgs.get(pair, []):
            line = f"[{ts.strftime('%Y-%m-%d %H:%M:%S')}] {pkt.get('from')}→{pkt.get('to')} | {pkt.get('type')}"
            if pkt.get("type") == "message":
                line += f" | {pkt.get('content')}"
            txt.insert(tk.END, line + "\n")
        txt.configure(state='disabled')

    def broadcast_user_list(self):
        users = [u for u in self.clients if u not in self.banned]
        pkt   = json.dumps({"type":"user_list","users":users}) + "\n"
        for conn, _ in self.clients.values():
            try: conn.sendall(pkt.encode())
            except: pass
        self.root.after(100, self.refresh)

    def run_server(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((HOST, PORT)); srv.listen()
        self.log_msg(f"[INFO] Listening on {HOST}:{PORT}")
        while True:
            conn, addr = srv.accept()
            threading.Thread(target=self.handle_client, args=(conn, addr), daemon=True).start()

    def handle_client(self, conn, addr):
        f = conn.makefile('r')
        nick = None
        try:
            # Initial presence
            line = f.readline()
            if not line: return
            pkt = json.loads(line)
            if pkt.get("type") == "presence" and pkt.get("nick"):
                nick = pkt["nick"]
                with self.lock:
                    if nick in self.banned:
                        conn.sendall((json.dumps({"type":"ban"})+"\n").encode())
                        conn.close()
                        return
                    self.clients[nick] = (conn, addr)
                    self.registered.add(nick)
                    self._save_registered()
                self.log_msg(f"[CONNECT] {nick}@{addr[0]}")
                self.broadcast_user_list()
            else:
                return

            # Main loop
            for line in f:
                pkt = json.loads(line)
                t   = pkt.get("type")

                # Handle user existence check
                if t == "check_users":
                    wanted = set(pkt.get('users', []))
                    found = list(self.registered & wanted)
                    resp = {"type":"registered_users","users":found}
                    conn.sendall((json.dumps(resp)+"\n").encode())
                    continue

                frm = pkt.get("from")
                to  = pkt.get("to")
                pair = frozenset({frm, to})

                # Enforce encryption
                if t == "message" and (pair not in self.sessions or not pkt.get("encrypted", False)):
                    continue

                # Session tracking
                if t == "encrypt_response":
                    if pkt.get("status") == "accept":
                        self.sessions.add(pair)
                    else:
                        self.sessions.discard(pair)
                if t == "end_encryption":
                    self.sessions.discard(pair)

                # Forward + logging
                if to in self.clients:
                    raw = json.dumps(pkt)+"\n"
                    bts = len(raw.encode())
                    with self.lock:
                        self.data_transfers[pair] = self.data_transfers.get(pair, 0) + bts
                        self.sessions_msgs.setdefault(pair, []).append((datetime.now(), pkt))
                    try:
                        self.clients[to][0].sendall(raw.encode())
                    except: pass
                self.root.after(100, self.refresh)

        finally:
            if nick:
                with self.lock:
                    self.clients.pop(nick, None)
                    for s in list(self.sessions):
                        if nick in s:
                            other = next(iter(s - {nick}))
                            try:
                                pkt = {"type":"end_encryption","from":nick,"to":other,"reason":"disconnect"}
                                self.clients[other][0].sendall((json.dumps(pkt)+"\n").encode())
                            except: pass
                            self.sessions.discard(s)
                self.broadcast_user_list()
                self.log_msg(f"[DISCONNECT] {nick}")
                self.root.after(100, self.refresh)
            conn.close()

if __name__ == "__main__":
    ChatServer()

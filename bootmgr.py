#!/usr/bin/env python3
# ============================================================
# bootmgr.py — RK3566 盒子双系统启动管理器 WebUI
#   控制 eMMC(恢复系统) ↔ SATA(日常系统) 启动切换
#   一键克隆 eMMC 系统到 SATA / 一键恢复 SATA 系统
# 依赖: 仅 Python3 标准库。端口 8080, systemd: bootmgr.service
# ============================================================
import json, os, re, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE = "/opt/bootmgr"
STATE = f"{BASE}/clone.progress"
LOG   = f"{BASE}/clone.log"
LOCK  = threading.Lock()
clone_proc = None  # 当前克隆子进程

EMMC_UUID = "5bc79f04-f7ff-4649-ab20-d87809a52e5f"   # eMMC rootfs
# SATA rootfs UUID 由 blkid 实时读取

def sh(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return (r.stdout + r.stderr).strip()
    except Exception as e:
        return f"ERR:{e}"

def bootdev():
    v = sh("fw_printenv bootdev 2>/dev/null | head -1").replace("bootdev=", "").strip()
    return v if v in ("sata", "emmc") else "sata"

def current_source():
    """当前 root 所在设备: emmc / sata / other"""
    root = sh("findmnt -n -o SOURCE /").strip()
    if root.startswith("/dev/mmcblk"): return "emmc", root
    if root.startswith("/dev/sd"):     return "sata", root
    return "other", root

def sata_info():
    """sda 状态: 无盘 / 全新(无分区) / 已有N分区"""
    if not os.path.exists("/dev/sda"):
        return {"present": False, "state": "absent", "model": "", "size": "", "parts": 0}
    model = sh("cat /sys/block/sda/device/model 2>/dev/null").strip()
    size  = sh("lsblk -dno SIZE /dev/sda 2>/dev/null").strip()
    parts = sh("sgdisk -p /dev/sda 2>/dev/null | grep -cE '^ +[0-9]+ +[0-9]+'").strip() or "0"
    n = int(parts)
    # 是否已有可启动系统 (p2 有 ext4 ROOTFS)
    has_sys = bool(sh("blkid /dev/sda2 2>/dev/null | grep -q ext4 && echo yes").strip())
    state = "fresh" if n == 0 else ("system" if has_sys else "unknown")
    return {"present": True, "state": state, "model": model, "size": size, "parts": n, "has_system": has_sys}

def status():
    src, dev = current_source()
    bd = bootdev()
    sata = sata_info()
    with LOCK:
        cloning = clone_proc is not None and clone_proc.poll() is None
    return {
        "current": src, "rootdev": dev,
        "bootdev": bd,
        "sata_preferred": bd == "sata",
        "emmc_size": sh("lsblk -dno SIZE /dev/mmcblk0 2>/dev/null"),
        "sata": sata,
        "cloning": cloning,
        "last_clone": os.path.exists(STATE) and sh(f"tail -1 {STATE} 2>/dev/null") or "",
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
    }

def do_switch(target, reboot=False):
    if target not in ("sata", "emmc"):
        return {"ok": False, "msg": "target 必须为 emmc 或 sata"}
    # 写入 bootdev 并同步 extlinux.conf 指向
    sh(f'fw_setenv bootdev {target}')
    new = bootdev()
    ok = new == target
    msg = f"已切换: bootdev={new} (下次重启从{'SATA' if new=='sata' else 'eMMC'}启动)"
    if ok and reboot:
        msg += " — 10 秒后重启…"
        threading.Timer(10, lambda: sh("systemctl reboot", timeout=5)).start()
    return {"ok": ok, "msg": msg, "bootdev": new}

def do_clone(force):
    global clone_proc
    with LOCK:
        if clone_proc is not None and clone_proc.poll() is None:
            return {"ok": False, "msg": "克隆正在进行中"}
        # 只有从 eMMC 系统允许克隆
        src, _ = current_source()
        if src != "emmc":
            return {"ok": False, "msg": "克隆必须从 eMMC 恢复系统执行"}
        os.makedirs(BASE, exist_ok=True)
        open(STATE, "w").write("STEP=start PROGRESS=0\n")
        open(LOG, "w").close()
        cmd = ["/bin/bash", f"{BASE}/clone.sh"] + (["--force"] if force else [])
        clone_proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return {"ok": True, "msg": "克隆已启动"}

def clone_progress():
    step, prog = "idle", "0"
    if os.path.exists(STATE):
        for line in open(STATE).read().strip().splitlines():
            m = re.match(r"STEP=(\S+) PROGRESS=(\d+)", line)
            if m: step, prog = m.group(1), m.group(2)
    tail = ""
    if os.path.exists(LOG):
        # 只读尾部 15 行, 避免读入超大旧日志导致界面卡顿
        tail = sh(f"tail -n 15 {LOG} 2>/dev/null").splitlines()
        tail = "\n".join(tail[-15:])
    with LOCK:
        running = clone_proc is not None and clone_proc.poll() is None
    return {"step": step, "progress": int(prog), "running": running, "log": tail}

PAGE = """<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BootMgr v2 — 双系统启动管理</title>
<style>
:root{--bg:#0f172a;--card:#1e293b;--fg:#e2e8f0;--acc:#38bdf8;--ok:#34d399;--warn:#fbbf24;--bad:#f87171}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--fg);font-family:ui-monospace,Consolas,monospace;padding:20px}
h1{font-size:22px;margin-bottom:6px;color:var(--acc)}
.sub{color:#94a3b8;font-size:12px;margin-bottom:20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:14px;margin-bottom:20px}
.card{background:var(--card);border-radius:10px;padding:16px;border:1px solid #334155}
.card h2{font-size:14px;color:var(--acc);margin-bottom:10px}
.row{display:flex;justify-content:space-between;padding:5px 0;font-size:13px;border-bottom:1px dashed #334155}
.row:last-child{border:none}
.badge{padding:2px 10px;border-radius:99px;font-size:12px;font-weight:bold}
.b-ok{background:#064e3b;color:var(--ok)}.b-warn{background:#78350f;color:var(--warn)}.b-bad{background:#7f1d1d;color:var(--bad)}
.btn{display:block;width:100%;padding:12px;margin:8px 0;border:none;border-radius:8px;font-size:14px;font-weight:bold;cursor:pointer;font-family:inherit}
.btn:disabled{opacity:.4;cursor:not-allowed}
.b-sata{background:#0ea5e9;color:#fff}.b-emmc{background:#64748b;color:#fff}
.b-restore{background:#10b981;color:#fff}
.b-reboot{background:#ef4444;color:#fff}
#progwrap{display:none;background:#0f172a;border-radius:8px;overflow:hidden;height:22px;margin-top:10px}
#prog{height:100%;background:linear-gradient(90deg,#10b981,#38bdf8);width:0%;transition:width .5s}
#logbox{background:#0f172a;border-radius:8px;padding:10px;font-size:11px;white-space:pre-wrap;max-height:220px;overflow-y:auto;margin-top:10px;color:#94a3b8}
#toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:#1e293b;border:1px solid var(--acc);padding:10px 18px;border-radius:8px;display:none;font-size:13px;z-index:9}
.note{font-size:11px;color:#64748b;margin-top:8px}
</style></head><body>
<h1>🔀 BootMgr 双系统启动管理</h1>
<div class="sub" id="clock">—</div>
<div class="grid">
  <div class="card"><h2>当前系统</h2>
    <div class="row"><span>启动介质</span><span id="cur" class="badge b-warn">读取中…</span></div>
    <div class="row"><span>Root 设备</span><span id="rootdev">—</span></div>
    <div class="row"><span>eMMC 容量</span><span id="emmc">—</span></div>
    <div class="row"><span>启动目标</span><span id="bd" style="font-size:11px">—</span></div>
  </div>
  <div class="card"><h2>SATA 硬盘</h2>
    <div class="row"><span>状态</span><span id="sata" class="badge b-warn">—</span></div>
    <div class="row"><span>型号</span><span id="smodel">—</span></div>
    <div class="row"><span>容量</span><span id="ssize">—</span></div>
    <div class="row"><span>分区数</span><span id="sparts">—</span></div>
  </div>
</div>

<div class="card"><h2>启动切换</h2>
  <button class="btn b-sata" id="b1" onclick="sw('sata')">🚀 切换到 SATA 启动</button>
  <button class="btn b-emmc" id="b2" onclick="sw('emmc')">🛡 切换到 eMMC 启动(恢复)</button>
  <div class="note">切换只修改 U-Boot 启动顺序，不重启。SATA 盘缺失时 U-Boot 自动回退 eMMC。</div>
</div>

<div class="card"><h2>系统克隆 / 恢复</h2>
  <button class="btn b-restore" id="b3" onclick="clone()">📦 一键克隆 / 恢复 SATA</button>
  <div id="progwrap"><div id="prog"></div></div>
  <div id="logbox"></div>
  <div class="note">⚠️ 将当前 eMMC 系统克隆到 SATA 盘（SATA 已有系统则先格式化）。eMMC 恢复系统不受影响，完成后自动切换到 SATA 启动。</div>
</div>

<div class="card"><h2>系统</h2>
  <button class="btn b-reboot" id="b5" onclick="reboot()">🔄 重启盒子</button>
</div>
<div id="toast"></div>
<script>
let cloning=false;
function toast(m,ok=true){const t=document.getElementById('toast');t.textContent=(ok?'✅ ':'⚠️ ')+m;t.style.display='block';setTimeout(()=>t.style.display='none',4000)}
async function api(url,opts){const r=await fetch(url,opts);return r.json()}
async function refresh(){
  try{
    const s=await api('/api/status');
    document.getElementById('clock').textContent='更新于 '+s.time;
    const cur=document.getElementById('cur');
    if(s.current==='emmc'){cur.textContent='eMMC(恢复系统)';cur.className='badge b-ok'}
    else if(s.current==='sata'){cur.textContent='SATA(日常系统)';cur.className='badge b-warn'}
    else{cur.textContent='未知';cur.className='badge b-bad'}
    document.getElementById('rootdev').textContent=s.rootdev;
    document.getElementById('emmc').textContent=s.emmc_size;
    const bd=document.getElementById('bd');
    bd.textContent=s.bootdev==='sata'?'SATA(日常)':'eMMC(恢复)';
    bd.className=s.bootdev==='sata'?'badge b-ok':'badge b-warn';
    const st=document.getElementById('sata');
    if(!s.sata.present){st.textContent='未检测到';st.className='badge b-bad'}
    else if(s.sata.state==='fresh'){st.textContent='全新(无分区)';st.className='badge b-ok'}
    else if(s.sata.state==='system'){st.textContent='已有系统';st.className='badge b-warn'}
    else{st.textContent='未知('+s.sata.parts+'分区)';st.className='badge b-warn'}
    document.getElementById('smodel').textContent=s.sata.model||'—';
    document.getElementById('ssize').textContent=s.sata.size||'—';
    document.getElementById('sparts').textContent=s.sata.parts;
    cloning=s.cloning;
    document.getElementById('b1').disabled=s.current==='sata'||s.cloning;
    document.getElementById('b2').disabled=s.current==='emmc'||s.cloning;
    document.getElementById('b3').disabled=s.current!=='emmc'||s.cloning||!s.sata.present;
    document.getElementById('b5').disabled=s.cloning;
  }catch(e){console.log(e);document.getElementById('clock').textContent='⚠️ 状态加载失败: '+e.message}
}
async function pollProgress(){
  const p=await api('/api/progress');
  const wrap=document.getElementById('progwrap');
  if(p.running||p.step!=='idle'){
    wrap.style.display='block';
    document.getElementById('prog').style.width=p.progress+'%';
    const lb=document.getElementById('logbox');
    lb.textContent=p.log;
    lb.scrollTop=lb.scrollHeight;   // 自动滚到底部
    if(!p.running&&p.step==='done'){toast('克隆完成! 可重启进入 SATA 系统');refresh()}
    setTimeout(pollProgress,1500);
  }else{wrap.style.display='none'}
}
async function sw(t){
  if(t==='sata'&&!confirm('确认切换到 SATA 启动? (重启后将从 SATA 盘启动; 若 SATA 盘异常会自动回退 eMMC)'))return;
  if(t==='emmc'&&!confirm('确认切换到 eMMC 启动(恢复模式)?'))return;
  const r=await api('/api/switch?target='+t,{method:'POST'});
  toast(r.msg,r.ok); if(r.ok)refresh();
}
async function clone(){
  // 根据 SATA 状态自适应确认文案与 force 参数
  const st=document.getElementById('sata').textContent;
  const hasSys=st==='已有系统';
  const msg=hasSys?'⚠️ SATA 盘已有系统，将格式化并清空后重新克隆。继续?':'将把当前 eMMC 系统完整克隆到 SATA 盘。继续?';
  if(!confirm(msg))return;
  const r=await api('/api/clone?force='+(hasSys?1:0),{method:'POST'});
  toast(r.msg,r.ok);
  if(r.ok){document.getElementById('progwrap').style.display='block';pollProgress()}
}
async function reboot(){
  if(!confirm('确认重启盒子?'))return;
  await api('/api/reboot',{method:'POST'});toast('正在重启…')
}
refresh();setInterval(refresh,3000);setInterval(pollProgress,1500);
</script></body></html>"""

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/" or u.path == "/index.html":
            b = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type","text/html; charset=utf-8")
            self.send_header("Cache-Control","no-store, no-cache, must-revalidate")
            self.send_header("Pragma","no-cache")
            self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
        elif u.path == "/api/status":  self._send(status())
        elif u.path == "/api/progress": self._send(clone_progress())
        else: self._send({"ok":False,"msg":"404"}, 404)
    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/api/switch":
            self._send(do_switch(q.get("target",[""])[0], q.get("reboot",["0"])[0]=="1"))
        elif u.path == "/api/clone":
            self._send(do_clone(q.get("force",["0"])[0]=="1"))
        elif u.path == "/api/reboot":
            threading.Timer(3, lambda: sh("systemctl reboot", timeout=5)).start()
            self._send({"ok":True,"msg":"3 秒后重启"})
        else: self._send({"ok":False,"msg":"404"}, 404)

if __name__ == "__main__":
    PORT = int(os.environ.get("BOOTMGR_PORT", "8080"))
    print(f"BootMgr listening on :{PORT}  (pid {os.getpid()})")
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()

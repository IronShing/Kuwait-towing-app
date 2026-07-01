'use strict';
// Fz3a backend — zero-dependency Node.js (built-ins only).
// Auth (scrypt password hashing + HMAC-signed tokens), JSON datastore,
// rider/driver/admin roles, and ride lifecycle APIs.

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 3001;
const DATA_DIR = process.env.FZ3A_DATA || path.join(__dirname, 'data');
const DB_FILE = path.join(DATA_DIR, 'db.json');
const SECRET_FILE = path.join(DATA_DIR, 'secret.key');

// ---------------------------------------------------------------------------
// Storage — tiny JSON datastore with atomic writes
// ---------------------------------------------------------------------------
fs.mkdirSync(DATA_DIR, { recursive: true });

let db = { users: [], rides: [], seq: { user: 0, ride: 0 } };
if (fs.existsSync(DB_FILE)) {
  try { db = JSON.parse(fs.readFileSync(DB_FILE, 'utf8')); } catch (_) {}
}
let saveTimer = null;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    const tmp = DB_FILE + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
    fs.renameSync(tmp, DB_FILE);
  }, 20);
}
function saveNow() {
  const tmp = DB_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
  fs.renameSync(tmp, DB_FILE);
}

// ---------------------------------------------------------------------------
// Secret + auth helpers
// ---------------------------------------------------------------------------
let SECRET;
if (fs.existsSync(SECRET_FILE)) {
  SECRET = fs.readFileSync(SECRET_FILE);
} else {
  SECRET = crypto.randomBytes(48);
  fs.writeFileSync(SECRET_FILE, SECRET, { mode: 0o600 });
}

function hashPassword(password) {
  const salt = crypto.randomBytes(16);
  const derived = crypto.scryptSync(password, salt, 32);
  return 'scrypt$' + salt.toString('hex') + '$' + derived.toString('hex');
}
function verifyPassword(password, stored) {
  try {
    const [, saltHex, hashHex] = stored.split('$');
    const salt = Buffer.from(saltHex, 'hex');
    const expected = Buffer.from(hashHex, 'hex');
    const derived = crypto.scryptSync(password, salt, expected.length);
    return crypto.timingSafeEqual(expected, derived);
  } catch (_) { return false; }
}
function b64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function signToken(payload) {
  const body = b64url(JSON.stringify({ ...payload, iat: Date.now() }));
  const sig = b64url(crypto.createHmac('sha256', SECRET).update(body).digest());
  return body + '.' + sig;
}
function verifyToken(token) {
  if (!token || token.indexOf('.') < 0) return null;
  const [body, sig] = token.split('.');
  const expected = b64url(crypto.createHmac('sha256', SECRET).update(body).digest());
  if (sig.length !== expected.length) return null;
  if (!crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) return null;
  try {
    const data = JSON.parse(Buffer.from(body.replace(/-/g, '+').replace(/_/g, '/'), 'base64'));
    // 30-day expiry
    if (Date.now() - data.iat > 30 * 864e5) return null;
    return data;
  } catch (_) { return null; }
}

// ---------------------------------------------------------------------------
// Seed admin (username Admin / password Admin, must change on first login)
// ---------------------------------------------------------------------------
function seedAdmin() {
  if (!db.users.find(u => u.role === 'admin')) {
    db.users.push({
      id: ++db.seq.user,
      name: 'Administrator',
      phone: '',
      username: 'Admin',
      passwordHash: hashPassword('Admin'),
      role: 'admin',
      mustChangePassword: true,
      createdAt: Date.now(),
    });
    saveNow();
    console.log('Seeded admin user: Admin / Admin (must change password)');
  }
}
seedAdmin();

// ---------------------------------------------------------------------------
// Pricing (mirror of the Flutter engine)
// ---------------------------------------------------------------------------
function computeFare(km) {
  let fare = 5.0;
  if (km > 5) fare += (km - 5) * 1.0;
  if (fare > 15) fare = 15;
  fare = +fare.toFixed(3);
  const commission = +(fare * 0.15).toFixed(3);
  const driver = +(fare - commission).toFixed(3);
  return { total: fare, commission, driver };
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, OPTIONS',
    'Cache-Control': 'no-store',
  });
  res.end(body);
}
function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => { data += c; if (data.length > 1e6) req.destroy(); });
    req.on('end', () => {
      if (!data) return resolve({});
      try { resolve(JSON.parse(data)); } catch (_) { resolve({}); }
    });
  });
}
function publicUser(u) {
  return {
    id: u.id, name: u.name, phone: u.phone, username: u.username,
    role: u.role, mustChangePassword: !!u.mustChangePassword,
    vehicleType: u.vehicleType, plate: u.plate, approved: u.approved, online: !!u.online,
  };
}
function auth(req) {
  const h = req.headers['authorization'] || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : '';
  const data = verifyToken(token);
  if (!data) return null;
  return db.users.find(u => u.id === data.uid) || null;
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  let p = url.pathname.replace(/^\/api/, '') || '/';
  const method = req.method;

  if (method === 'OPTIONS') return send(res, 204, {});

  try {
    // --- health ---
    if (p === '/health') return send(res, 200, { ok: true, users: db.users.length, rides: db.rides.length });

    // --- signup ---
    if (p === '/auth/signup' && method === 'POST') {
      const b = await readBody(req);
      const name = (b.name || '').trim();
      const username = (b.username || '').trim().toLowerCase();
      const password = b.password || '';
      const role = b.role === 'driver' ? 'driver' : 'rider';
      if (name.length < 2 || username.length < 3 || password.length < 4)
        return send(res, 400, { error: 'Name, username (3+), and password (4+) are required' });
      if (db.users.find(u => u.username.toLowerCase() === username))
        return send(res, 409, { error: 'Username already taken' });
      const user = {
        id: ++db.seq.user, name, phone: (b.phone || '').trim(),
        username, passwordHash: hashPassword(password), role,
        mustChangePassword: false, createdAt: Date.now(),
      };
      if (role === 'driver') {
        user.vehicleType = b.vehicleType || 'winch';
        user.plate = (b.plate || '').trim();
        user.approved = true; // auto-approve for demo
        user.online = false;
      }
      db.users.push(user);
      saveNow();
      return send(res, 201, { token: signToken({ uid: user.id }), user: publicUser(user) });
    }

    // --- login ---
    if (p === '/auth/login' && method === 'POST') {
      const b = await readBody(req);
      const username = (b.username || '').trim().toLowerCase();
      const user = db.users.find(u => u.username.toLowerCase() === username);
      if (!user || !verifyPassword(b.password || '', user.passwordHash))
        return send(res, 401, { error: 'Invalid username or password' });
      return send(res, 200, { token: signToken({ uid: user.id }), user: publicUser(user) });
    }

    // --- everything below requires auth ---
    const me = auth(req);

    if (p === '/auth/me' && method === 'GET') {
      if (!me) return send(res, 401, { error: 'Unauthorized' });
      return send(res, 200, { user: publicUser(me) });
    }

    if (p === '/auth/change-password' && method === 'POST') {
      if (!me) return send(res, 401, { error: 'Unauthorized' });
      const b = await readBody(req);
      // if not forced, require the old password
      if (!me.mustChangePassword && !verifyPassword(b.oldPassword || '', me.passwordHash))
        return send(res, 401, { error: 'Current password is incorrect' });
      if ((b.newPassword || '').length < 4)
        return send(res, 400, { error: 'New password must be at least 4 characters' });
      me.passwordHash = hashPassword(b.newPassword);
      me.mustChangePassword = false;
      saveNow();
      return send(res, 200, { ok: true, user: publicUser(me) });
    }

    // --- rides ---
    if (p === '/rides' && method === 'POST') {
      if (!me) return send(res, 401, { error: 'Unauthorized' });
      const b = await readBody(req);
      const km = Number(b.distanceKm) || 0;
      const fare = computeFare(km);
      const ride = {
        id: ++db.seq.ride,
        riderId: me.id, riderName: me.name, riderPhone: me.phone,
        driverId: null, driverName: null,
        service: b.service || 'winch',
        pickup: b.pickup || null, dropoff: b.dropoff || null,
        distanceKm: +km.toFixed(2),
        fareKwd: fare.total, commissionKwd: fare.commission, driverKwd: fare.driver,
        status: 'searching', createdAt: Date.now(),
      };
      db.rides.push(ride);
      saveNow();
      return send(res, 201, { ride });
    }

    if (p === '/rides/mine' && method === 'GET') {
      if (!me) return send(res, 401, { error: 'Unauthorized' });
      return send(res, 200, { rides: db.rides.filter(r => r.riderId === me.id).reverse() });
    }

    if (p === '/rides/available' && method === 'GET') {
      if (!me || me.role !== 'driver') return send(res, 403, { error: 'Drivers only' });
      return send(res, 200, { rides: db.rides.filter(r => r.status === 'searching').reverse() });
    }

    if (p === '/rides/active' && method === 'GET') {
      if (!me || me.role !== 'driver') return send(res, 403, { error: 'Drivers only' });
      return send(res, 200, {
        rides: db.rides.filter(r => r.driverId === me.id &&
          ['accepted', 'enroute', 'arrived'].includes(r.status)).reverse(),
      });
    }

    let m;
    if ((m = p.match(/^\/rides\/(\d+)\/accept$/)) && method === 'POST') {
      if (!me || me.role !== 'driver') return send(res, 403, { error: 'Drivers only' });
      const ride = db.rides.find(r => r.id === Number(m[1]));
      if (!ride) return send(res, 404, { error: 'Ride not found' });
      if (ride.status !== 'searching') return send(res, 409, { error: 'Ride already taken' });
      ride.status = 'accepted';
      ride.driverId = me.id; ride.driverName = me.name; ride.driverPhone = me.phone;
      ride.vehicleType = me.vehicleType; ride.plate = me.plate;
      saveNow();
      return send(res, 200, { ride });
    }

    if ((m = p.match(/^\/rides\/(\d+)\/status$/)) && method === 'POST') {
      if (!me) return send(res, 401, { error: 'Unauthorized' });
      const ride = db.rides.find(r => r.id === Number(m[1]));
      if (!ride) return send(res, 404, { error: 'Ride not found' });
      const b = await readBody(req);
      const allowed = ['enroute', 'arrived', 'completed', 'cancelled'];
      if (!allowed.includes(b.status)) return send(res, 400, { error: 'Bad status' });
      const isOwnerDriver = me.role === 'driver' && ride.driverId === me.id;
      const isRider = ride.riderId === me.id;
      if (!isOwnerDriver && !isRider && me.role !== 'admin')
        return send(res, 403, { error: 'Not allowed' });
      ride.status = b.status;
      saveNow();
      return send(res, 200, { ride });
    }

    if ((m = p.match(/^\/rides\/(\d+)$/)) && method === 'GET') {
      if (!me) return send(res, 401, { error: 'Unauthorized' });
      const ride = db.rides.find(r => r.id === Number(m[1]));
      if (!ride) return send(res, 404, { error: 'Ride not found' });
      return send(res, 200, { ride });
    }

    // --- driver online toggle ---
    if (p === '/driver/online' && method === 'POST') {
      if (!me || me.role !== 'driver') return send(res, 403, { error: 'Drivers only' });
      const b = await readBody(req);
      me.online = !!b.online;
      saveNow();
      return send(res, 200, { online: me.online });
    }

    // --- admin ---
    if (p.startsWith('/admin/')) {
      if (!me || me.role !== 'admin') return send(res, 403, { error: 'Admins only' });
      if (p === '/admin/stats') {
        return send(res, 200, {
          users: db.users.filter(u => u.role === 'rider').length,
          drivers: db.users.filter(u => u.role === 'driver').length,
          onlineDrivers: db.users.filter(u => u.role === 'driver' && u.online).length,
          rides: db.rides.length,
          activeRides: db.rides.filter(r => !['completed', 'cancelled'].includes(r.status)).length,
          revenue: +db.rides.filter(r => r.status === 'completed')
            .reduce((s, r) => s + (r.commissionKwd || 0), 0).toFixed(3),
        });
      }
      if (p === '/admin/users') return send(res, 200, { users: db.users.map(publicUser) });
      if (p === '/admin/rides') return send(res, 200, { rides: [...db.rides].reverse() });
    }

    return send(res, 404, { error: 'Not found' });
  } catch (err) {
    console.error(err);
    return send(res, 500, { error: 'Server error' });
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log('Fz3a API listening on :' + PORT + '  (data: ' + DB_FILE + ')');
});

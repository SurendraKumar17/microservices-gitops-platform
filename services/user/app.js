const express = require('express');
const { Pool } = require('pg');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const client = require('prom-client');  // ← add this

const app = express();
const PORT = process.env.PORT || 3002;
const JWT_SECRET = process.env.JWT_SECRET || 'skybook-secret-change-in-prod';

app.use(express.json());

// ─────────────────────────────────────────
// Prometheus metrics
// ─────────────────────────────────────────
client.collectDefaultMetrics({ prefix: 'nodejs_' });

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status']
});

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.01, 0.05, 0.1, 0.3, 0.5, 1, 2, 5]
});

app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    httpRequestsTotal.inc({
      method: req.method,
      route: req.route?.path || req.path,
      status: res.statusCode
    });
    end({
      method: req.method,
      route: req.route?.path || req.path,
      status: res.statusCode
    });
  });
  next();
});

// ─────────────────────────────────────────
// DB connection
// ─────────────────────────────────────────
const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'bookingdb',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'postgres',
  ssl: { rejectUnauthorized: false }
});

async function initDB() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      email VARCHAR(255) UNIQUE NOT NULL,
      password_hash VARCHAR(255) NOT NULL,
      name VARCHAR(255) NOT NULL,
      created_at TIMESTAMP DEFAULT NOW()
    );
  `);
  console.log('Users DB initialized');
}

// ─────────────────────────────────────────
// Routes
// ─────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'user' }));
app.get('/ready', (req, res) => res.json({ status: 'ready', service: 'user' }));

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

app.post('/api/users/register', async (req, res) => { /* ... existing code ... */ });
app.post('/api/users/login', async (req, res) => { /* ... existing code ... */ });
app.get('/api/users/profile', authenticate, async (req, res) => { /* ... existing code ... */ });
app.get('/api/users', async (req, res) => { /* ... existing code ... */ });

function authenticate(req, res, next) { /* ... existing code ... */ }

// ─────────────────────────────────────────
// Start
// ─────────────────────────────────────────
initDB()
  .then(() => app.listen(PORT, () => console.log(`User service running on port ${PORT}`)))
  .catch(err => { console.error('DB init failed:', err); process.exit(1); });
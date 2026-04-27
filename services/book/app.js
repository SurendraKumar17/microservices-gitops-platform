const express = require('express');
const { Pool } = require('pg');
const client = require('prom-client');

const app = express();
const PORT = process.env.PORT || 3001;

app.use(express.json());

// ─────────────────────────────────────────
// Prometheus metrics setup
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

// middleware — track all requests
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
// DB setup
// ─────────────────────────────────────────
const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'bookingdb',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'postgres',
  ssl: {
    rejectUnauthorized: false
  }
});

async function initDB() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS reservations (
      id SERIAL PRIMARY KEY,
      user_id INT,
      type VARCHAR(20) NOT NULL CHECK (type IN ('flight','hotel','package')),
      item_name VARCHAR(255) NOT NULL,
      price DECIMAL(10,2) NOT NULL,
      status VARCHAR(20) DEFAULT 'confirmed' CHECK (status IN ('pending','confirmed','cancelled')),
      booking_ref VARCHAR(20) UNIQUE NOT NULL,
      travel_date DATE,
      created_at TIMESTAMP DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS cart (
      id SERIAL PRIMARY KEY,
      session_id VARCHAR(100),
      type VARCHAR(20) NOT NULL,
      name VARCHAR(255) NOT NULL,
      price DECIMAL(10,2) NOT NULL,
      added_at TIMESTAMP DEFAULT NOW()
    );
  `);
  console.log('Booking DB initialized');
}

function genRef() {
  return 'SKY' + Math.random().toString(36).substring(2, 9).toUpperCase();
}

// ─────────────────────────────────────────
// Routes
// ─────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'booking' }));
app.get('/ready',  (req, res) => res.json({ status: 'ready', service: 'book' }));

// metrics endpoint — must be before other middleware
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

app.post('/api/bookings/cart', async (req, res) => {
  const { type, name, price, session_id } = req.body;
  if (!type || !name || !price)
    return res.status(400).json({ error: 'type, name, price required' });

  try {
    const result = await pool.query(
      'INSERT INTO cart (session_id, type, name, price) VALUES ($1, $2, $3, $4) RETURNING *',
      [session_id || 'anonymous', type, name, price]
    );
    res.status(201).json({ item: result.rows[0] });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to add to cart' });
  }
});

app.get('/api/bookings/cart', async (req, res) => {
  const { session_id } = req.query;
  try {
    const result = await pool.query(
      'SELECT * FROM cart WHERE session_id = $1 ORDER BY added_at DESC',
      [session_id || 'anonymous']
    );
    const total = result.rows.reduce((sum, item) => sum + parseFloat(item.price), 0);
    res.json({ items: result.rows, total });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to get cart' });
  }
});

app.post('/api/bookings/checkout', async (req, res) => {
  const { user_id, items, travel_date } = req.body;
  if (!items || !items.length)
    return res.status(400).json({ error: 'No items to book' });

  const dbClient = await pool.connect();
  try {
    await dbClient.query('BEGIN');
    const bookings = [];
    for (const item of items) {
      const ref = genRef();
      const result = await dbClient.query(
        `INSERT INTO reservations (user_id, type, item_name, price, booking_ref, travel_date)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
        [user_id || null, item.type, item.name, item.price, ref, travel_date || null]
      );
      bookings.push(result.rows[0]);
    }
    await dbClient.query('COMMIT');
    res.status(201).json({ bookings, message: 'Booking confirmed!' });
  } catch (err) {
    await dbClient.query('ROLLBACK');
    console.error(err);
    res.status(500).json({ error: 'Checkout failed' });
  } finally {
    dbClient.release();
  }
});

app.get('/api/bookings', async (req, res) => {
  const { user_id } = req.query;
  try {
    let query = 'SELECT * FROM reservations';
    const params = [];
    if (user_id) {
      params.push(user_id);
      query += ' WHERE user_id = $1';
    }
    query += ' ORDER BY created_at DESC';
    const result = await pool.query(query, params);
    res.json({ bookings: result.rows });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to fetch bookings' });
  }
});

app.patch('/api/bookings/:id/cancel', async (req, res) => {
  try {
    const result = await pool.query(
      "UPDATE reservations SET status = 'cancelled' WHERE id = $1 RETURNING *",
      [req.params.id]
    );
    if (!result.rows.length)
      return res.status(404).json({ error: 'Booking not found' });
    res.json({ booking: result.rows[0] });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to cancel' });
  }
});

// ─────────────────────────────────────────
// Start
// ─────────────────────────────────────────
initDB()
  .then(() => app.listen(PORT, () =>
    console.log(`Booking service running on port ${PORT}`)))
  .catch(err => { console.error('DB init failed:', err); process.exit(1); });
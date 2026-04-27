const express = require('express');
const { Pool } = require('pg');
const client = require('prom-client');

const app = express();
const PORT = process.env.PORT || 3003;

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
  database: process.env.DB_NAME || 'flights',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'postgres',
  ssl: {
    rejectUnauthorized: false
  }
});

async function initDB() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS flights (
      id SERIAL PRIMARY KEY,
      origin VARCHAR(10) NOT NULL,
      destination VARCHAR(10) NOT NULL,
      departure TIMESTAMP NOT NULL,
      arrival TIMESTAMP NOT NULL,
      airline VARCHAR(100),
      price DECIMAL(10,2) NOT NULL,
      seats_available INT DEFAULT 100,
      created_at TIMESTAMP DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS hotels (
      id SERIAL PRIMARY KEY,
      name VARCHAR(255) NOT NULL,
      city VARCHAR(100) NOT NULL,
      rating DECIMAL(2,1),
      price_per_night DECIMAL(10,2) NOT NULL,
      rooms_available INT DEFAULT 50,
      created_at TIMESTAMP DEFAULT NOW()
    );
  `);
  console.log('Search DB initialized');
}

// ─────────────────────────────────────────
// Routes
// ─────────────────────────────────────────
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'search' }));
app.get('/ready',  (req, res) => res.json({ status: 'ready', service: 'search' }));

// Search flights
app.get('/api/search/flights', async (req, res) => {
  const { origin, destination, date } = req.query;
  try {
    let query = 'SELECT * FROM flights WHERE seats_available > 0';
    const params = [];

    if (origin) {
      params.push(origin.toUpperCase());
      query += ` AND origin = $${params.length}`;
    }
    if (destination) {
      params.push(destination.toUpperCase());
      query += ` AND destination = $${params.length}`;
    }
    if (date) {
      params.push(date);
      query += ` AND DATE(departure) = $${params.length}`;
    }

    query += ' ORDER BY price ASC';
    const result = await pool.query(query, params);
    res.json({ flights: result.rows });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to search flights' });
  }
});

// Search hotels
app.get('/api/search/hotels', async (req, res) => {
  const { city } = req.query;
  try {
    let query = 'SELECT * FROM hotels WHERE rooms_available > 0';
    const params = [];

    if (city) {
      params.push(city);
      query += ` AND LOWER(city) = LOWER($${params.length})`;
    }

    query += ' ORDER BY price_per_night ASC';
    const result = await pool.query(query, params);
    res.json({ hotels: result.rows });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to search hotels' });
  }
});

// Seed sample data
app.post('/api/search/seed', async (req, res) => {
  try {
    await pool.query(`
      INSERT INTO flights (origin, destination, departure, arrival, airline, price)
      VALUES
        ('JFK', 'LAX', NOW() + interval '1 day', NOW() + interval '1 day 6 hours', 'SkyAir', 299.99),
        ('LAX', 'JFK', NOW() + interval '2 days', NOW() + interval '2 days 6 hours', 'SkyAir', 319.99),
        ('JFK', 'LHR', NOW() + interval '3 days', NOW() + interval '3 days 7 hours', 'GlobalJet', 599.99),
        ('LHR', 'DXB', NOW() + interval '4 days', NOW() + interval '4 days 7 hours', 'GlobalJet', 449.99)
      ON CONFLICT DO NOTHING;

      INSERT INTO hotels (name, city, rating, price_per_night)
      VALUES
        ('Sky Hotel NYC', 'New York', 4.5, 199.99),
        ('Pacific View', 'Los Angeles', 4.2, 179.99),
        ('London Grand', 'London', 4.7, 299.99),
        ('Desert Palace', 'Dubai', 4.8, 399.99)
      ON CONFLICT DO NOTHING;
    `);
    res.json({ message: 'Sample data seeded' });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Seed failed' });
  }
});

// ─────────────────────────────────────────
// Start
// ─────────────────────────────────────────
initDB()
  .then(() => app.listen(PORT, () =>
    console.log(`Search service running on port ${PORT}`)))
  .catch(err => { console.error('DB init failed:', err); process.exit(1); });
const express = require('express');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 3001;

app.use(express.json());

const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'bookingdb',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'postgres',
  ssl: {
    rejectUnauthorized: false  // RDS SSL without CA cert verification
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

// Generate booking reference
function genRef() {
  return 'SKY' + Math.random().toString(36).substring(2, 9).toUpperCase();
}

// Health check
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'booking' }));

// Add to cart
app.post('/api/bookings/cart', async (req, res) => {
  const { type, name, price, session_id } = req.body;
  if (!type || !name || !price) return res.status(400).json({ error: 'type, name, price required' });

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

// Get cart
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

// Checkout - create booking
app.post('/api/bookings/checkout', async (req, res) => {
  const { user_id, items, travel_date } = req.body;
  if (!items || !items.length) return res.status(400).json({ error: 'No items to book' });

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const bookings = [];
    for (const item of items) {
      const ref = genRef();
      const result = await client.query(
        `INSERT INTO reservations (user_id, type, item_name, price, booking_ref, travel_date)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
        [user_id || null, item.type, item.name, item.price, ref, travel_date || null]
      );
      bookings.push(result.rows[0]);
    }
    await client.query('COMMIT');
    res.status(201).json({ bookings, message: 'Booking confirmed!' });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(err);
    res.status(500).json({ error: 'Checkout failed' });
  } finally {
    client.release();
  }
});

// Get all bookings
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

// Cancel booking
app.patch('/api/bookings/:id/cancel', async (req, res) => {
  try {
    const result = await pool.query(
      "UPDATE reservations SET status = 'cancelled' WHERE id = $1 RETURNING *",
      [req.params.id]
    );
    if (!result.rows.length) return res.status(404).json({ error: 'Booking not found' });
    res.json({ booking: result.rows[0] });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to cancel' });
  }
});

initDB()
  .then(() => app.listen(PORT, () => console.log(`Booking service running on port ${PORT}`)))
  .catch(err => { console.error('DB init failed:', err); process.exit(1); });


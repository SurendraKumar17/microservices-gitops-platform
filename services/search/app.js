const express = require('express');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 3003;

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
    CREATE TABLE IF NOT EXISTS flights (
      id SERIAL PRIMARY KEY,
      airline VARCHAR(100) NOT NULL,
      icon VARCHAR(10) DEFAULT '✈️',
      origin VARCHAR(10) NOT NULL,
      destination VARCHAR(10) NOT NULL,
      departure TIME NOT NULL,
      arrival TIME NOT NULL,
      duration VARCHAR(20) NOT NULL,
      stops VARCHAR(50) DEFAULT 'Direct',
      price DECIMAL(10,2) NOT NULL,
      class VARCHAR(20) DEFAULT 'Economy',
      available_seats INT DEFAULT 50,
      created_at TIMESTAMP DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS hotels (
      id SERIAL PRIMARY KEY,
      name VARCHAR(255) NOT NULL,
      city VARCHAR(100) NOT NULL,
      country VARCHAR(100) NOT NULL,
      icon VARCHAR(10) DEFAULT '🏨',
      stars INT DEFAULT 4,
      stars_display VARCHAR(10) DEFAULT '★★★★',
      price_per_night DECIMAL(10,2) NOT NULL,
      bg_color VARCHAR(20) DEFAULT '#1c2538',
      available_rooms INT DEFAULT 10,
      created_at TIMESTAMP DEFAULT NOW()
    );
  `);

  // Seed sample data if empty
  const flightCount = await pool.query('SELECT COUNT(*) FROM flights');
  if (flightCount.rows[0].count === '0') {
    await pool.query(`
      INSERT INTO flights (airline, icon, origin, destination, departure, arrival, duration, stops, price, class) VALUES
      ('British Airways', '✈️', 'JFK', 'LHR', '08:00', '20:00', '12h 00m', 'Direct', 499, 'Economy'),
      ('Emirates', '🛫', 'JFK', 'LHR', '11:30', '23:45', '12h 15m', '1 stop via DXB', 389, 'Economy'),
      ('Lufthansa', '🛩️', 'JFK', 'LHR', '14:00', '06:30', '16h 30m', '1 stop via FRA', 320, 'Economy'),
      ('Singapore Airlines', '✈️', 'JFK', 'NRT', '22:00', '06:00', '14h 00m', 'Direct', 699, 'Economy'),
      ('ANA', '🛫', 'JFK', 'NRT', '13:00', '18:00', '14h 30m', '1 stop', 620, 'Economy'),
      ('Air France', '✈️', 'JFK', 'CDG', '09:00', '22:30', '7h 30m', 'Direct', 389, 'Economy'),
      ('Garuda Indonesia', '🛩️', 'JFK', 'DPS', '10:00', '22:00', '24h 00m', '1 stop via SIN', 549, 'Economy'),
      ('British Airways', '✈️', 'JFK', 'LHR', '18:00', '06:00', '12h 00m', 'Direct', 780, 'Business'),
      ('Emirates', '🛫', 'JFK', 'NRT', '23:59', '10:00', '14h 01m', 'Direct', 1200, 'Business');
    `);
  }

  const hotelCount = await pool.query('SELECT COUNT(*) FROM hotels');
  if (hotelCount.rows[0].count === '0') {
    await pool.query(`
      INSERT INTO hotels (name, city, country, icon, stars, stars_display, price_per_night, bg_color) VALUES
      ('The Savoy', 'London', 'United Kingdom', '🏨', 5, '★★★★★', 320, '#dbeafe'),
      ('Claridges', 'London', 'United Kingdom', '🏰', 5, '★★★★★', 450, '#dbeafe'),
      ('Hotel de Crillon', 'Paris', 'France', '🏩', 5, '★★★★★', 480, '#fce7f3'),
      ('Le Meurice', 'Paris', 'France', '🗼', 5, '★★★★★', 390, '#fce7f3'),
      ('Park Hyatt Tokyo', 'Tokyo', 'Japan', '🌸', 5, '★★★★★', 550, '#dcfce7'),
      ('The Peninsula Tokyo', 'Tokyo', 'Japan', '⛩️', 5, '★★★★★', 620, '#dcfce7'),
      ('Four Seasons Bali', 'Bali', 'Indonesia', '🌺', 5, '★★★★★', 290, '#fef3c7'),
      ('Bulgari Bali', 'Bali', 'Indonesia', '🌴', 5, '★★★★★', 380, '#fef3c7'),
      ('Burj Al Arab', 'Dubai', 'UAE', '⛵', 5, '★★★★★', 1200, '#ede9fe'),
      ('Marina Bay Sands', 'Singapore', 'Singapore', '🌃', 5, '★★★★★', 380, '#ecfeff');
    `);
  }

  console.log('Search DB initialized');
}

// Health check
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'search' }));

// Readiness check
app.get('/ready', (req, res) => res.json({ status: 'ready', service: 'search' }));

// Search flights
app.get('/api/search/flights', async (req, res) => {
  const { from, to, date } = req.query;
  
  try {
    let query = 'SELECT * FROM flights WHERE 1=1';
    const params = [];

    if (from) {
      // Match by IATA code or city name (simple contains)
      params.push(`%${from.replace(/.*\((\w+)\).*/, '$1')}%`);
      query += ` AND (UPPER(origin) LIKE UPPER($${params.length}) OR UPPER(origin) LIKE UPPER($${params.length}))`;
    }
    if (to) {
      const toCode = to.replace(/.*\((\w+)\).*/, '$1');
      params.push(`%${toCode}%`);
      query += ` AND (UPPER(destination) LIKE UPPER($${params.length}))`;
    }

    query += ' ORDER BY price ASC';
    const result = await pool.query(query, params);
    
    // Format for frontend
    const flights = result.rows.map(f => ({
      id: f.id,
      airline: f.airline,
      icon: f.icon,
      departure: f.departure?.substring(0, 5),
      arrival: f.arrival?.substring(0, 5),
      duration: f.duration,
      stops: f.stops,
      price: parseFloat(f.price),
      class: f.class,
    }));

    res.json({ flights, total: flights.length });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Search failed' });
  }
});

// Search hotels
app.get('/api/search/hotels', async (req, res) => {
  const { city } = req.query;

  try {
    let query = 'SELECT * FROM hotels';
    const params = [];

    if (city && city !== 'featured') {
      params.push(`%${city}%`);
      query += ` WHERE LOWER(city) LIKE LOWER($1) OR LOWER(country) LIKE LOWER($1)`;
    }

    query += ' ORDER BY price_per_night ASC LIMIT 20';
    const result = await pool.query(query, params);

    const hotels = result.rows.map(h => ({
      id: h.id,
      name: h.name,
      location: `${h.city}, ${h.country}`,
      icon: h.icon,
      stars: h.stars_display,
      price: parseFloat(h.price_per_night),
      bg: h.bg_color,
    }));

    res.json({ hotels, total: hotels.length });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Hotel search failed' });
  }
});

initDB()
  .then(() => app.listen(PORT, () => console.log(`Search service running on port ${PORT}`)))
  .catch(err => { console.error('DB init failed:', err); process.exit(1); });
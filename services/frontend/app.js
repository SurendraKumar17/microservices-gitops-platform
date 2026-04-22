const express = require('express');
const axios = require('axios');

const app = express();
app.use(express.json());

/**
 * HOME
 */
app.get('/', (req, res) => {
  res.send("Welcome to Travel Booking ✈️");
});

/**
 * SEARCH
 */
app.get('/search', async (req, res) => {
  try {
    const city = req.query.city || "hyderabad";

    const response = await axios.get(
      `http://search:3000/search?city=${city}`
    );

    res.json(response.data);
  } catch (err) {
    res.status(500).send("Search service error");
  }
});

/**
 * BOOK
 */
app.post('/book', async (req, res) => {
  try {
    const response = await axios.post(
      'http://booking:3001/book',
      req.body
    );

    res.json(response.data);
  } catch (err) {
    res.status(500).send("Booking service error");
  }
});

/**
 * LOGIN
 */
app.post('/login', async (req, res) => {
  try {
    const response = await axios.post(
      'http://user:3002/login',
      req.body
    );

    res.json(response.data);
  } catch (err) {
    res.status(500).send("User service error");
  }
});

app.listen(3000, () => {
  console.log("Frontend running on port 3000");
});

#end
// trigger
// trigger pipeline
// trigger pipeline

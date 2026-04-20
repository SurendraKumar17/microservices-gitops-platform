const express = require('express');
const app = express();
app.use(express.json());

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.post('/book', (req, res) => {
  const { hotel, user } = req.body;
  res.json({
    status: "Booking Confirmed ✅",
    hotel,
    user
  });
});

app.listen(3001, () => {
  console.log("Booking service running on port 3001");
});
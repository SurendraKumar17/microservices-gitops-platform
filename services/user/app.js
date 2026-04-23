const express = require('express');
const app = express();

app.use(express.json());

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.post('/login', (req, res) => {
  const { username } = req.body;
  res.json({
    token: "fake-jwt-token",
    user: username
  });
});

app.listen(3002, () => {
  console.log("User service running on port 3002");
});// rebuild all

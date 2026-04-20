const express = require('express');
const app = express();

app.get('/search', (req, res) => {
  const city = req.query.city || "unknown";

  res.json([
    { hotel: "Taj", city, price: 5000 },
    { hotel: "Oyo", city, price: 1500 }
  ]);
});

app.listen(3000, () => {
  console.log("Search service running on port 3000");
});
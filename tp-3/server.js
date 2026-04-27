const express = require("express");
const path = require("path");

const app = express();
app.use(express.static(path.join(__dirname, "public")));

app.get("/healthz", (req, res) => res.status(200).send("ok"));

const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`Server listening on ${port}`));

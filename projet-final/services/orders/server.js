const express = require('express');
const { Pool } = require('pg');
const pino = require('pino');
const pinoHttp = require('pino-http');
const client = require('prom-client');

const log = pino({ level: process.env.LOG_LEVEL || 'info' });
const PORT = process.env.PORT || 3000;

// URL interne du service catalogue, resolue par le DNS du cluster (kube-dns).
const CATALOGUE_URL = process.env.CATALOGUE_URL || 'http://catalogue-svc';

const pool = new Pool({
  host: process.env.DB_HOST,
  port: process.env.DB_PORT || 5432,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  max: 5,
});

const registry = new client.Registry();
registry.setDefaultLabels({ service: 'orders' });
client.collectDefaultMetrics({ register: registry });
const httpRequests = new client.Counter({
  name: 'http_requests_total',
  help: 'Nombre total de requetes HTTP',
  labelNames: ['method', 'route', 'status'],
  registers: [registry],
});

const app = express();
app.use(express.json());
app.use(pinoHttp({ logger: log }));
app.use((req, res, next) => {
  res.on('finish', () => {
    httpRequests.inc({ method: req.method, route: req.path, status: res.statusCode });
  });
  next();
});

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'orders' }));

app.get('/ready', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ready' });
  } catch (err) {
    req.log.error({ err: err.message }, 'readiness DB check failed');
    res.status(503).json({ status: 'not-ready', error: err.message });
  }
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', registry.contentType);
  res.end(await registry.metrics());
});

app.get('/orders', async (req, res) => {
  try {
    const { rows } = await pool.query(
      'SELECT id, product_id, quantity, created_at FROM orders ORDER BY id DESC'
    );
    res.json({ orders: rows });
  } catch (err) {
    req.log.error({ err: err.message }, 'query orders failed');
    res.status(500).json({ error: err.message });
  }
});

// POST /orders : valide le produit en appelant catalogue en DNS interne,
// puis insere la commande. Demontre la communication inter-services.
app.post('/orders', async (req, res) => {
  const { product_id, quantity } = req.body || {};
  if (!product_id || !quantity || quantity < 1) {
    return res.status(400).json({ error: 'product_id et quantity (>=1) requis' });
  }
  try {
    const check = await fetch(`${CATALOGUE_URL}/products/${product_id}`);
    if (check.status === 404) {
      return res.status(422).json({ error: `produit ${product_id} inexistant` });
    }
    if (!check.ok) {
      return res.status(502).json({ error: 'catalogue indisponible' });
    }
    const { rows } = await pool.query(
      'INSERT INTO orders (product_id, quantity) VALUES ($1, $2) RETURNING id, product_id, quantity, created_at',
      [product_id, quantity]
    );
    req.log.info({ order: rows[0] }, 'commande creee');
    res.status(201).json({ order: rows[0] });
  } catch (err) {
    req.log.error({ err: err.message }, 'create order failed');
    res.status(500).json({ error: err.message });
  }
});

module.exports = app;

if (require.main === module) {
  app.listen(PORT, () => log.info(`orders en ecoute sur le port ${PORT}`));
}

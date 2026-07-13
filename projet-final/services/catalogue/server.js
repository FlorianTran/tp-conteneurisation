const express = require('express');
const { Pool } = require('pg');
const pino = require('pino');
const pinoHttp = require('pino-http');
const client = require('prom-client');

const log = pino({ level: process.env.LOG_LEVEL || 'info' });
const PORT = process.env.PORT || 3000;

// Pool Postgres : credentials injectes via Secret, host/port/db via ConfigMap.
const pool = new Pool({
  host: process.env.DB_HOST,
  port: process.env.DB_PORT || 5432,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  max: 5,
});

// Metriques Prometheus (scrape par le ServiceMonitor sur /metrics).
const registry = new client.Registry();
registry.setDefaultLabels({ service: 'catalogue' });
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

// Liveness : le process repond, independamment de la DB.
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'catalogue' }));

// Readiness : on ne prend du trafic que si la DB repond.
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

app.get('/products', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT id, name, price FROM products ORDER BY id');
    res.json({ products: rows });
  } catch (err) {
    req.log.error({ err: err.message }, 'query products failed');
    res.status(500).json({ error: err.message });
  }
});

app.get('/products/:id', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT id, name, price FROM products WHERE id = $1', [
      req.params.id,
    ]);
    if (rows.length === 0) return res.status(404).json({ error: 'produit introuvable' });
    res.json({ product: rows[0] });
  } catch (err) {
    req.log.error({ err: err.message }, 'query product failed');
    res.status(500).json({ error: err.message });
  }
});

module.exports = app;

if (require.main === module) {
  app.listen(PORT, () => log.info(`catalogue en ecoute sur le port ${PORT}`));
}

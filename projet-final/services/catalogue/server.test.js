const test = require('node:test');
const assert = require('node:assert');
const request = require('supertest');
const app = require('./server');

// Tests minimalistes : on verifie les endpoints qui ne dependent pas de la DB.
// /products, /ready dependent de Postgres et sont couverts par le smoke-test en cluster.

test('GET /health renvoie 200 et status ok', async () => {
  const res = await request(app).get('/health');
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.status, 'ok');
  assert.strictEqual(res.body.service, 'catalogue');
});

test('GET /metrics expose les metriques Prometheus', async () => {
  const res = await request(app).get('/metrics');
  assert.strictEqual(res.status, 200);
  assert.match(res.text, /http_requests_total|process_cpu/);
});

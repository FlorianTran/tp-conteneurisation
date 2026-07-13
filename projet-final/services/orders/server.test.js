const test = require('node:test');
const assert = require('node:assert');
const request = require('supertest');
const app = require('./server');

test('GET /health renvoie 200 et status ok', async () => {
  const res = await request(app).get('/health');
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.status, 'ok');
  assert.strictEqual(res.body.service, 'orders');
});

test('POST /orders sans corps valide renvoie 400', async () => {
  const res = await request(app).post('/orders').send({});
  assert.strictEqual(res.status, 400);
});

test('GET /metrics expose les metriques Prometheus', async () => {
  const res = await request(app).get('/metrics');
  assert.strictEqual(res.status, 200);
  assert.match(res.text, /http_requests_total|process_cpu/);
});

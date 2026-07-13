-- Schema + seed montes dans /docker-entrypoint-initdb.d via ConfigMap.
-- Postgres n'execute ces scripts QUE si le volume de donnees est vide (premier demarrage).

CREATE TABLE IF NOT EXISTS products (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  price NUMERIC(10, 2) NOT NULL
);

CREATE TABLE IF NOT EXISTS orders (
  id SERIAL PRIMARY KEY,
  product_id INTEGER NOT NULL REFERENCES products (id),
  quantity INTEGER NOT NULL CHECK (quantity >= 1),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO products (name, price) VALUES
  ('Clavier mecanique', 89.90),
  ('Souris ergonomique', 45.00),
  ('Ecran 27 pouces', 249.99),
  ('Casque audio', 129.50)
ON CONFLICT DO NOTHING;

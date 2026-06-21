-- =============================================================================
-- Indirect Tax Compliance & Analytics Database  -- 01_schema.sql
-- Engine: SQLite 3
--
-- Business context:
--   A US company sells taxable goods and services into multiple states.
--   Each sale may or may not be subject to sales/use tax depending on the
--   ship-to jurisdiction, product taxability, and whether the customer holds
--   a valid exemption (resale / nonprofit / government) certificate.
--   The company must (a) charge the correct tax, (b) track economic nexus
--   thresholds per state, and (c) reconcile tax collected vs. tax remitted on
--   filed returns. This schema models that end-to-end process.
-- =============================================================================

PRAGMA foreign_keys = ON;

-- Drop in dependency order so the script is re-runnable -------------------------
DROP VIEW  IF EXISTS v_transaction_detail;
DROP TABLE IF EXISTS return_line_items;
DROP TABLE IF EXISTS tax_returns;
DROP TABLE IF EXISTS transaction_lines;
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS exemption_certificates;
DROP TABLE IF EXISTS tax_rates;
DROP TABLE IF EXISTS jurisdictions;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS customers;

-- -----------------------------------------------------------------------------
-- Reference / dimension tables
-- -----------------------------------------------------------------------------

-- Tax jurisdictions: a state (and optionally a local jurisdiction within it).
CREATE TABLE jurisdictions (
    jurisdiction_id   INTEGER PRIMARY KEY,
    state_code        TEXT    NOT NULL,                 -- e.g. 'CA', 'TX'
    state_name        TEXT    NOT NULL,
    locality          TEXT,                             -- NULL = state-level rate
    -- Economic nexus thresholds (post-Wayfair). A seller must register and
    -- collect once it exceeds EITHER the sales-dollar OR transaction-count
    -- threshold in a state. NULL count means dollar-only threshold.
    nexus_sales_threshold  NUMERIC NOT NULL DEFAULT 100000,
    nexus_txn_threshold    INTEGER,
    CHECK (nexus_sales_threshold >= 0)
);

-- Products with a taxability category. Taxability varies by category and,
-- in real life, by state -- here we model a default category taxability and
-- let state rules override via tax_rates where needed.
CREATE TABLE products (
    product_id      INTEGER PRIMARY KEY,
    sku             TEXT    NOT NULL UNIQUE,
    product_name    TEXT    NOT NULL,
    -- category drives taxability: 'TPP' (tangible personal property, usually
    -- taxable), 'SAAS', 'SERVICE', 'GROCERY', 'DIGITAL'
    tax_category    TEXT    NOT NULL,
    unit_price      NUMERIC NOT NULL CHECK (unit_price >= 0)
);

-- Customers. exempt_status indicates the type of exemption they may claim;
-- the actual proof lives in exemption_certificates.
CREATE TABLE customers (
    customer_id     INTEGER PRIMARY KEY,
    customer_name   TEXT    NOT NULL,
    customer_type   TEXT    NOT NULL,    -- 'RETAIL', 'RESELLER', 'NONPROFIT', 'GOVERNMENT'
    state_code      TEXT    NOT NULL     -- ship-to / primary state
);

-- Statutory tax rates by jurisdiction, product category and effective period.
-- combined_rate = state + county + city + special-district, expressed as a
-- decimal fraction (0.0825 = 8.25%). is_taxable lets us model exempt
-- categories (e.g. groceries in many states) with a 0 / FALSE flag.
CREATE TABLE tax_rates (
    rate_id         INTEGER PRIMARY KEY,
    jurisdiction_id INTEGER NOT NULL REFERENCES jurisdictions(jurisdiction_id),
    tax_category    TEXT    NOT NULL,
    is_taxable      INTEGER NOT NULL DEFAULT 1,   -- 1 = taxable, 0 = exempt category
    combined_rate   NUMERIC NOT NULL CHECK (combined_rate >= 0),
    effective_from  TEXT    NOT NULL,             -- ISO date 'YYYY-MM-DD'
    effective_to    TEXT,                         -- NULL = currently in effect
    UNIQUE (jurisdiction_id, tax_category, effective_from)
);

-- Exemption certificates on file. A transaction is validly exempt only if a
-- non-expired certificate exists for that customer + jurisdiction.
CREATE TABLE exemption_certificates (
    certificate_id  INTEGER PRIMARY KEY,
    customer_id     INTEGER NOT NULL REFERENCES customers(customer_id),
    jurisdiction_id INTEGER NOT NULL REFERENCES jurisdictions(jurisdiction_id),
    exemption_type  TEXT    NOT NULL,    -- 'RESALE', 'NONPROFIT', 'GOVERNMENT'
    issued_date     TEXT    NOT NULL,
    expiry_date     TEXT,                -- NULL = does not expire
    certificate_no  TEXT    NOT NULL UNIQUE
);

-- -----------------------------------------------------------------------------
-- Fact tables
-- -----------------------------------------------------------------------------

-- A sales transaction (invoice) shipped to a jurisdiction.
CREATE TABLE transactions (
    transaction_id  INTEGER PRIMARY KEY,
    invoice_no      TEXT    NOT NULL UNIQUE,
    customer_id     INTEGER NOT NULL REFERENCES customers(customer_id),
    jurisdiction_id INTEGER NOT NULL REFERENCES jurisdictions(jurisdiction_id),
    txn_date        TEXT    NOT NULL,             -- ISO date
    -- exemption_applied: did the seller treat this sale as exempt at point of
    -- sale? We later validate this against a real certificate to find risk.
    exemption_applied INTEGER NOT NULL DEFAULT 0
);

-- Line items. tax_collected is what was ACTUALLY charged on the invoice;
-- we recompute the EXPECTED tax in queries to surface under/over-collection.
CREATE TABLE transaction_lines (
    line_id         INTEGER PRIMARY KEY,
    transaction_id  INTEGER NOT NULL REFERENCES transactions(transaction_id),
    product_id      INTEGER NOT NULL REFERENCES products(product_id),
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC NOT NULL CHECK (unit_price >= 0),  -- price at sale time
    tax_collected   NUMERIC NOT NULL DEFAULT 0 CHECK (tax_collected >= 0)
);

-- Returns filed with each state for a tax period, and the tax actually remitted.
CREATE TABLE tax_returns (
    return_id       INTEGER PRIMARY KEY,
    jurisdiction_id INTEGER NOT NULL REFERENCES jurisdictions(jurisdiction_id),
    period_year     INTEGER NOT NULL,
    period_month    INTEGER NOT NULL CHECK (period_month BETWEEN 1 AND 12),
    tax_remitted    NUMERIC NOT NULL DEFAULT 0,
    filed_date      TEXT,                         -- NULL = not yet filed
    UNIQUE (jurisdiction_id, period_year, period_month)
);

-- -----------------------------------------------------------------------------
-- Helpful indexes
-- -----------------------------------------------------------------------------
CREATE INDEX idx_lines_txn        ON transaction_lines(transaction_id);
CREATE INDEX idx_lines_product    ON transaction_lines(product_id);
CREATE INDEX idx_txn_cust         ON transactions(customer_id);
CREATE INDEX idx_txn_juris        ON transactions(jurisdiction_id);
CREATE INDEX idx_rates_lookup     ON tax_rates(jurisdiction_id, tax_category, effective_from);
CREATE INDEX idx_cert_cust_juris  ON exemption_certificates(customer_id, jurisdiction_id);

-- -----------------------------------------------------------------------------
-- Convenience view: fully exploded transaction detail with the statutory rate
-- that applied on the transaction date. Used by several analytical queries.
-- -----------------------------------------------------------------------------
CREATE VIEW v_transaction_detail AS
SELECT
    t.transaction_id,
    t.invoice_no,
    t.txn_date,
    t.exemption_applied,
    c.customer_id,
    c.customer_name,
    c.customer_type,
    j.jurisdiction_id,
    j.state_code,
    p.product_id,
    p.sku,
    p.tax_category,
    tl.line_id,
    tl.quantity,
    tl.unit_price,
    (tl.quantity * tl.unit_price)              AS line_amount,
    tl.tax_collected,
    r.is_taxable,
    r.combined_rate
FROM transactions t
JOIN customers          c  ON c.customer_id   = t.customer_id
JOIN jurisdictions      j  ON j.jurisdiction_id = t.jurisdiction_id
JOIN transaction_lines  tl ON tl.transaction_id = t.transaction_id
JOIN products           p  ON p.product_id    = tl.product_id
-- pick the rate row in effect on the transaction date
LEFT JOIN tax_rates     r  ON r.jurisdiction_id = j.jurisdiction_id
                          AND r.tax_category    = p.tax_category
                          AND t.txn_date       >= r.effective_from
                          AND (r.effective_to IS NULL OR t.txn_date <= r.effective_to);

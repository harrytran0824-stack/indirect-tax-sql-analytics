-- =============================================================================
-- Indirect Tax Compliance & Analytics Database  -- 02_seed_data.sql
-- Realistic sample data for FY2025 with intentional edge cases so the
-- analytical queries surface real findings (under-collection, missing
-- certificates, expired certificates, rate mismatches, nexus crossings).
-- =============================================================================

PRAGMA foreign_keys = ON;

-- -----------------------------------------------------------------------------
-- Jurisdictions  (5 states with different nexus rules)
-- -----------------------------------------------------------------------------
INSERT INTO jurisdictions
    (jurisdiction_id, state_code, state_name, locality, nexus_sales_threshold, nexus_txn_threshold) VALUES
    (1, 'CA', 'California',   NULL, 500000, NULL),   -- $500k, no txn count
    (2, 'TX', 'Texas',       NULL, 500000, NULL),    -- $500k, no txn count
    (3, 'NY', 'New York',    NULL, 500000, 100),     -- $500k AND 100 txns (NY uses AND)
    (4, 'FL', 'Florida',     NULL, 100000, NULL),    -- $100k
    (5, 'WA', 'Washington',  NULL, 100000, 200);     -- $100k OR 200 txns

-- -----------------------------------------------------------------------------
-- Products  (different taxability categories)
-- -----------------------------------------------------------------------------
INSERT INTO products (product_id, sku, product_name, tax_category, unit_price) VALUES
    (1, 'TPP-1001', 'Industrial Sensor Unit',     'TPP',     1200.00),
    (2, 'TPP-1002', 'Replacement Cable Kit',      'TPP',       85.00),
    (3, 'SAAS-2001','Analytics Platform License', 'SAAS',    5000.00),
    (4, 'SVC-3001', 'Onsite Installation Service', 'SERVICE', 2500.00),
    (5, 'GRO-4001', 'Packaged Snack Carton',      'GROCERY',   40.00),
    (6, 'DIG-5001', 'Downloadable Report Bundle', 'DIGITAL',  300.00);

-- -----------------------------------------------------------------------------
-- Customers
-- -----------------------------------------------------------------------------
INSERT INTO customers (customer_id, customer_name, customer_type, state_code) VALUES
    (1, 'Pacific Retail Group',     'RETAIL',     'CA'),
    (2, 'Lone Star Resellers LLC',  'RESELLER',   'TX'),
    (3, 'Empire Nonprofit Trust',   'NONPROFIT',  'NY'),
    (4, 'Sunshine City Schools',    'GOVERNMENT', 'FL'),
    (5, 'Cascade Distributors',     'RESELLER',   'WA'),
    (6, 'Golden Gate Foods Inc',    'RETAIL',     'CA'),
    (7, 'Hudson Valley Outfitters', 'RETAIL',     'NY');

-- -----------------------------------------------------------------------------
-- Tax rates  (combined rates by state + category; effective 2025-01-01)
--   GROCERY exempt in CA/NY; DIGITAL taxable in TX/WA; SAAS taxable in TX/NY/WA.
--   Note CA has a mid-year rate change for TPP to exercise effective-dating.
-- -----------------------------------------------------------------------------
-- California
INSERT INTO tax_rates (jurisdiction_id, tax_category, is_taxable, combined_rate, effective_from, effective_to) VALUES
    (1, 'TPP',     1, 0.0825, '2025-01-01', '2025-06-30'),
    (1, 'TPP',     1, 0.0875, '2025-07-01', NULL),          -- CA rate increase mid-year
    (1, 'SAAS',    0, 0.0000, '2025-01-01', NULL),          -- SaaS not taxable in CA
    (1, 'SERVICE', 0, 0.0000, '2025-01-01', NULL),
    (1, 'GROCERY', 0, 0.0000, '2025-01-01', NULL),          -- groceries exempt
    (1, 'DIGITAL', 0, 0.0000, '2025-01-01', NULL);
-- Texas
INSERT INTO tax_rates (jurisdiction_id, tax_category, is_taxable, combined_rate, effective_from, effective_to) VALUES
    (2, 'TPP',     1, 0.0825, '2025-01-01', NULL),
    (2, 'SAAS',    1, 0.0625, '2025-01-01', NULL),          -- TX taxes SaaS (data processing)
    (2, 'SERVICE', 1, 0.0825, '2025-01-01', NULL),
    (2, 'GROCERY', 0, 0.0000, '2025-01-01', NULL),
    (2, 'DIGITAL', 1, 0.0825, '2025-01-01', NULL);
-- New York
INSERT INTO tax_rates (jurisdiction_id, tax_category, is_taxable, combined_rate, effective_from, effective_to) VALUES
    (3, 'TPP',     1, 0.0888, '2025-01-01', NULL),
    (3, 'SAAS',    1, 0.0888, '2025-01-01', NULL),
    (3, 'SERVICE', 0, 0.0000, '2025-01-01', NULL),
    (3, 'GROCERY', 0, 0.0000, '2025-01-01', NULL),
    (3, 'DIGITAL', 1, 0.0888, '2025-01-01', NULL);
-- Florida
INSERT INTO tax_rates (jurisdiction_id, tax_category, is_taxable, combined_rate, effective_from, effective_to) VALUES
    (4, 'TPP',     1, 0.0700, '2025-01-01', NULL),
    (4, 'SAAS',    0, 0.0000, '2025-01-01', NULL),
    (4, 'SERVICE', 0, 0.0000, '2025-01-01', NULL),
    (4, 'GROCERY', 0, 0.0000, '2025-01-01', NULL),
    (4, 'DIGITAL', 0, 0.0000, '2025-01-01', NULL);
-- Washington
INSERT INTO tax_rates (jurisdiction_id, tax_category, is_taxable, combined_rate, effective_from, effective_to) VALUES
    (5, 'TPP',     1, 0.0950, '2025-01-01', NULL),
    (5, 'SAAS',    1, 0.0950, '2025-01-01', NULL),
    (5, 'SERVICE', 1, 0.0950, '2025-01-01', NULL),
    (5, 'GROCERY', 0, 0.0000, '2025-01-01', NULL),
    (5, 'DIGITAL', 1, 0.0950, '2025-01-01', NULL);

-- -----------------------------------------------------------------------------
-- Exemption certificates
--   Cust 2 (TX reseller): valid resale cert in TX.
--   Cust 4 (FL govt): valid govt cert in FL.
--   Cust 3 (NY nonprofit): EXPIRED cert -> exemptions claimed are now invalid.
--   Cust 5 (WA reseller): NO certificate on file -> any exemption is unsupported.
-- -----------------------------------------------------------------------------
INSERT INTO exemption_certificates
    (certificate_id, customer_id, jurisdiction_id, exemption_type, issued_date, expiry_date, certificate_no) VALUES
    (1, 2, 2, 'RESALE',     '2024-01-01', '2026-09-30', 'TX-RES-0001'),
    (2, 4, 4, 'GOVERNMENT', '2023-05-01', NULL,         'FL-GOV-0001'),
    (3, 3, 3, 'NONPROFIT',  '2022-01-01', '2024-12-31', 'NY-NPO-0001');  -- EXPIRED

-- -----------------------------------------------------------------------------
-- Transactions + line items
-- Design notes (edge cases the queries will catch):
--   * Inv 1001  CA TPP, taxed correctly (8.25% pre-July).
--   * Inv 1002  CA TPP in August -> should use 8.75% but only 8.25% collected
--               (UNDER-COLLECTION due to mid-year rate change).
--   * Inv 1003  TX reseller, exemption applied WITH valid cert -> OK.
--   * Inv 1004  WA reseller, exemption applied but NO cert -> RISK.
--   * Inv 1005  NY nonprofit, exemption applied but cert EXPIRED -> RISK.
--   * Inv 1006  TX SaaS taxed correctly.
--   * Inv 1007  CA SaaS -> not taxable, correctly $0.
--   * Inv 1008  FL govt with valid cert -> exempt OK.
--   * Inv 1009  NY TPP taxable, taxed correctly.
--   * Inv 1010  WA digital taxable, taxed correctly.
--   * Inv 1011  CA grocery exempt, $0 correct.
--   * Inv 1012  TX TPP, OVER-collection (charged 9% vs 8.25%).
--   * Inv 1013-1020 FL volume to push FL over its $100k nexus threshold.
-- -----------------------------------------------------------------------------
INSERT INTO transactions (transaction_id, invoice_no, customer_id, jurisdiction_id, txn_date, exemption_applied) VALUES
    (1001, 'INV-1001', 1, 1, '2025-03-15', 0),
    (1002, 'INV-1002', 6, 1, '2025-08-20', 0),
    (1003, 'INV-1003', 2, 2, '2025-04-10', 1),
    (1004, 'INV-1004', 5, 5, '2025-05-05', 1),
    (1005, 'INV-1005', 3, 3, '2025-06-01', 1),
    (1006, 'INV-1006', 2, 2, '2025-04-18', 0),
    (1007, 'INV-1007', 1, 1, '2025-02-11', 0),
    (1008, 'INV-1008', 4, 4, '2025-03-22', 1),
    (1009, 'INV-1009', 7, 3, '2025-07-09', 0),
    (1010, 'INV-1010', 5, 5, '2025-09-14', 0),
    (1011, 'INV-1011', 6, 1, '2025-05-30', 0),
    (1012, 'INV-1012', 2, 2, '2025-10-02', 0),
    (1013, 'INV-1013', 4, 4, '2025-01-20', 0),
    (1014, 'INV-1014', 4, 4, '2025-02-20', 0),
    (1015, 'INV-1015', 4, 4, '2025-03-20', 0),
    (1016, 'INV-1016', 4, 4, '2025-04-20', 0),
    (1017, 'INV-1017', 4, 4, '2025-05-20', 0),
    (1018, 'INV-1018', 4, 4, '2025-06-20', 0),
    (1019, 'INV-1019', 4, 4, '2025-07-20', 0),
    (1020, 'INV-1020', 4, 4, '2025-08-20', 0);

-- Line items.  tax_collected is the ACTUAL amount on the invoice.
-- Expected tax = line_amount * combined_rate (computed in queries).
INSERT INTO transaction_lines (line_id, transaction_id, product_id, quantity, unit_price, tax_collected) VALUES
    -- 1001: CA TPP, 10 sensors @1200 = 12000 * 8.25% = 990.00  (correct)
    (1, 1001, 1, 10, 1200.00, 990.00),
    -- 1002: CA TPP in Aug, 5 sensors @1200 = 6000.  Correct = 8.75% = 525.
    --        Only 8.25% (495) collected -> UNDER by 30.
    (2, 1002, 1, 5, 1200.00, 495.00),
    -- 1003: TX reseller resale, exempt with valid cert -> 0 correct
    (3, 1003, 1, 20, 1200.00, 0.00),
    -- 1004: WA reseller, exemption applied but NO cert. 8 sensors @1200 = 9600.
    --        Should have been 9.5% = 912.  Collected 0 -> exposure 912.
    (4, 1004, 1, 8, 1200.00, 0.00),
    -- 1005: NY nonprofit, expired cert. 4 SaaS @5000 = 20000 * 8.88% = 1776 exposure.
    (5, 1005, 3, 4, 5000.00, 0.00),
    -- 1006: TX SaaS, 2 @5000 = 10000 * 6.25% = 625 (correct)
    (6, 1006, 3, 2, 5000.00, 625.00),
    -- 1007: CA SaaS not taxable -> 0 correct. 1 @5000.
    (7, 1007, 3, 1, 5000.00, 0.00),
    -- 1008: FL govt valid cert, exempt. 3 sensors @1200 -> 0 correct.
    (8, 1008, 1, 3, 1200.00, 0.00),
    -- 1009: NY TPP taxable, 6 cables @85 = 510 * 8.88% = 45.29 (correct, rounded)
    (9, 1009, 2, 6, 85.00, 45.29),
    -- 1010: WA digital taxable, 10 @300 = 3000 * 9.5% = 285 (correct)
    (10, 1010, 6, 10, 300.00, 285.00),
    -- 1011: CA grocery exempt, 50 @40 = 2000 -> 0 correct
    (11, 1011, 5, 50, 40.00, 0.00),
    -- 1012: TX TPP OVER-collection. 4 sensors @1200 = 4800.  Correct 8.25% = 396.
    --        Collected 432 (9%) -> OVER by 36.
    (12, 1012, 1, 4, 1200.00, 432.00),
    -- 1013-1020: FL TPP volume.  Each 20 sensors @1200 = 24000 * 7% = 1680.
    (13, 1013, 1, 20, 1200.00, 1680.00),
    (14, 1014, 1, 20, 1200.00, 1680.00),
    (15, 1015, 1, 20, 1200.00, 1680.00),
    (16, 1016, 1, 20, 1200.00, 1680.00),
    (17, 1017, 1, 20, 1200.00, 1680.00),
    (18, 1018, 1, 20, 1200.00, 1680.00),
    (19, 1019, 1, 20, 1200.00, 1680.00),
    (20, 1020, 1, 20, 1200.00, 1680.00);

-- -----------------------------------------------------------------------------
-- Tax returns filed (with a deliberate reconciliation gap in CA and a
-- missing/unfiled WA return).
-- -----------------------------------------------------------------------------
INSERT INTO tax_returns (return_id, jurisdiction_id, period_year, period_month, tax_remitted, filed_date) VALUES
    -- CA March: collected 990 (inv1001), remitted 990 -> matches
    (1, 1, 2025, 3, 990.00, '2025-04-20'),
    -- CA August: collected 495 (inv1002), but remitted only 450 -> short remittance
    (2, 1, 2025, 8, 450.00, '2025-09-20'),
    -- TX April: collected 625 (inv1006) -> remitted 625 matches (inv1003 exempt)
    (3, 2, 2025, 4, 625.00, '2025-05-20'),
    -- TX October: collected 432 (inv1012) -> remitted 432
    (4, 2, 2025, 10, 432.00, '2025-11-20'),
    -- NY July: collected 45.29 (inv1009) -> remitted 45.29
    (5, 3, 2025, 7, 45.29, '2025-08-20'),
    -- FL Jan-Aug returns filed matching collected 1680 each
    (6, 4, 2025, 1, 1680.00, '2025-02-20'),
    (7, 4, 2025, 2, 1680.00, '2025-03-20'),
    (8, 4, 2025, 3, 1680.00, '2025-04-20'),
    (9, 4, 2025, 4, 1680.00, '2025-05-20'),
    (10, 4, 2025, 5, 1680.00, '2025-06-20'),
    (11, 4, 2025, 6, 1680.00, '2025-07-20'),
    (12, 4, 2025, 7, 1680.00, '2025-08-20'),
    (13, 4, 2025, 8, 1680.00, '2025-09-20');
    -- NOTE: WA September (inv1010, 285 collected) intentionally NOT filed.

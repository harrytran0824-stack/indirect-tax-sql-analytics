#!/usr/bin/env python3
"""
Export Power BI / Tableau-ready CSVs from the indirect-tax database.

Produces (in ./bi_exports/):
  fact_transaction_detail.csv  - one row per invoice line, denormalized with the
                                 statutory rate, expected tax, and variance.
                                 This is the main "fact" table for a BI model.
  state_scorecard.csv          - one row per state: sales, collected, remitted,
                                 reconciliation gap, exemption exposure.
  nexus_tracking.csv           - running sales/txn totals per state with a
                                 nexus-crossed flag (for a nexus dashboard).
  exposure_summary.csv         - headline quantified-risk numbers.

Usage:  python3 export_bi.py
"""
import sqlite3
import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "bi_exports")
os.makedirs(OUT, exist_ok=True)


def load(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()


def dump(con, filename, sql):
    cur = con.execute(sql)
    cols = [d[0] for d in cur.description]
    path = os.path.join(OUT, filename)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(cols)
        w.writerows(cur.fetchall())
    print(f"  wrote {filename}")


con = sqlite3.connect(":memory:")
con.executescript(load("01_schema.sql"))
con.executescript(load("02_seed_data.sql"))
print("Exporting BI CSVs to ./bi_exports/ ...")

# 1. Denormalized fact table (the BI workhorse)
dump(con, "fact_transaction_detail.csv", """
SELECT
    invoice_no, txn_date, state_code,
    customer_name, customer_type,
    sku, tax_category, quantity, unit_price,
    line_amount,
    exemption_applied,
    is_taxable,
    combined_rate,
    ROUND(CASE WHEN exemption_applied = 1 OR is_taxable = 0
               THEN 0 ELSE line_amount * combined_rate END, 2) AS expected_tax,
    tax_collected,
    ROUND(CASE WHEN exemption_applied = 1 OR is_taxable = 0
               THEN 0 ELSE line_amount * combined_rate END - tax_collected, 2) AS variance
FROM v_transaction_detail
ORDER BY txn_date, invoice_no
""")

# 2. State scorecard (executive dashboard)
dump(con, "state_scorecard.csv", """
WITH sales_by_state AS (
    SELECT state_code, ROUND(SUM(line_amount),2) gross_sales,
           ROUND(SUM(tax_collected),2) tax_collected
    FROM v_transaction_detail GROUP BY state_code),
remitted_by_state AS (
    SELECT j.state_code, ROUND(SUM(r.tax_remitted),2) tax_remitted
    FROM tax_returns r JOIN jurisdictions j ON j.jurisdiction_id=r.jurisdiction_id
    GROUP BY j.state_code),
exemption_risk AS (
    SELECT v.state_code, ROUND(SUM(v.line_amount*v.combined_rate),2) exempt_exposure
    FROM v_transaction_detail v
    WHERE v.exemption_applied=1 AND v.is_taxable=1
      AND NOT EXISTS (SELECT 1 FROM exemption_certificates ec
        WHERE ec.customer_id=v.customer_id AND ec.jurisdiction_id=v.jurisdiction_id
          AND ec.issued_date<=v.txn_date
          AND (ec.expiry_date IS NULL OR ec.expiry_date>=v.txn_date))
    GROUP BY v.state_code)
SELECT s.state_code, s.gross_sales, s.tax_collected,
       COALESCE(rm.tax_remitted,0) tax_remitted,
       ROUND(s.tax_collected-COALESCE(rm.tax_remitted,0),2) reconciliation_gap,
       COALESCE(er.exempt_exposure,0) invalid_exemption_exposure
FROM sales_by_state s
LEFT JOIN remitted_by_state rm ON rm.state_code=s.state_code
LEFT JOIN exemption_risk er ON er.state_code=s.state_code
ORDER BY s.gross_sales DESC
""")

# 3. Nexus tracking (running totals)
dump(con, "nexus_tracking.csv", """
WITH txn_totals AS (
    SELECT j.state_code, j.nexus_sales_threshold, t.txn_date, t.transaction_id,
           SUM(tl.quantity*tl.unit_price) invoice_amount
    FROM transactions t
    JOIN jurisdictions j ON j.jurisdiction_id=t.jurisdiction_id
    JOIN transaction_lines tl ON tl.transaction_id=t.transaction_id
    GROUP BY j.state_code, j.nexus_sales_threshold, t.txn_date, t.transaction_id)
SELECT state_code, txn_date, ROUND(invoice_amount,2) invoice_amount,
    ROUND(SUM(invoice_amount) OVER (PARTITION BY state_code ORDER BY txn_date,transaction_id
        ROWS UNBOUNDED PRECEDING),2) cumulative_sales,
    COUNT(*) OVER (PARTITION BY state_code ORDER BY txn_date,transaction_id
        ROWS UNBOUNDED PRECEDING) cumulative_txns,
    nexus_sales_threshold,
    CASE WHEN SUM(invoice_amount) OVER (PARTITION BY state_code ORDER BY txn_date,transaction_id
        ROWS UNBOUNDED PRECEDING) >= nexus_sales_threshold THEN 1 ELSE 0 END nexus_crossed
FROM txn_totals
ORDER BY state_code, txn_date, transaction_id
""")

# 4. Exposure summary (headline)
dump(con, "exposure_summary.csv", """
WITH variance AS (
    SELECT ROUND(SUM(MAX(CASE WHEN exemption_applied=0 AND is_taxable=1
        THEN line_amount*combined_rate - tax_collected ELSE 0 END,0)),2) amt
    FROM v_transaction_detail),
invalid_exempt AS (
    SELECT ROUND(SUM(v.line_amount*v.combined_rate),2) amt
    FROM v_transaction_detail v
    WHERE v.exemption_applied=1 AND v.is_taxable=1
      AND NOT EXISTS (SELECT 1 FROM exemption_certificates ec
        WHERE ec.customer_id=v.customer_id AND ec.jurisdiction_id=v.jurisdiction_id
          AND ec.issued_date<=v.txn_date
          AND (ec.expiry_date IS NULL OR ec.expiry_date>=v.txn_date))),
unfiled AS (
    SELECT ROUND(SUM(tl.tax_collected),2) amt
    FROM transactions t JOIN transaction_lines tl ON tl.transaction_id=t.transaction_id
    LEFT JOIN tax_returns r ON r.jurisdiction_id=t.jurisdiction_id
        AND r.period_year=CAST(strftime('%Y',t.txn_date) AS INTEGER)
        AND r.period_month=CAST(strftime('%m',t.txn_date) AS INTEGER)
    WHERE r.return_id IS NULL)
SELECT 'Under-collected tax (taxable sales)' exposure_type, COALESCE(amt,0) amount FROM variance
UNION ALL SELECT 'Tax on unsupported exempt sales', COALESCE(amt,0) FROM invalid_exempt
UNION ALL SELECT 'Tax collected but not yet remitted', COALESCE(amt,0) FROM unfiled
""")

con.close()
print("Done.")

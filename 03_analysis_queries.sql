-- =============================================================================
-- Indirect Tax Compliance & Analytics Database  -- 03_analysis_queries.sql
--
-- 20 analytical queries an Indirect Tax Technology team would actually run.
-- Each query is self-contained and commented with:
--   PURPOSE  - the business / tax question it answers
--   SKILL    - the SQL technique demonstrated
-- Run individually, or run the whole file to see every result set.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1. Taxable sales summary by state
-- PURPOSE: Top-line view of gross sales, taxable base, and tax collected per state.
-- SKILL:   JOIN, conditional aggregation (CASE inside SUM), GROUP BY.
-- -----------------------------------------------------------------------------
SELECT
    state_code,
    COUNT(DISTINCT transaction_id)                                   AS num_invoices,
    ROUND(SUM(line_amount), 2)                                       AS gross_sales,
    ROUND(SUM(CASE WHEN is_taxable = 1 THEN line_amount ELSE 0 END), 2) AS taxable_base,
    ROUND(SUM(tax_collected), 2)                                     AS tax_collected
FROM v_transaction_detail
GROUP BY state_code
ORDER BY gross_sales DESC;


-- -----------------------------------------------------------------------------
-- Q2. Expected vs. actual tax per line  (tax determination engine)
-- PURPOSE: Recompute the statutory tax for every line and compare to what was
--          charged. This is the heart of an indirect-tax review.
-- SKILL:   Derived calculation, exemption logic, rounding, CASE.
-- -----------------------------------------------------------------------------
SELECT
    invoice_no,
    state_code,
    sku,
    tax_category,
    line_amount,
    exemption_applied,
    ROUND(
        CASE
            WHEN exemption_applied = 1 THEN 0          -- treated as exempt at POS
            WHEN is_taxable = 0       THEN 0           -- category not taxable
            ELSE line_amount * combined_rate
        END, 2)                                        AS expected_tax,
    tax_collected,
    ROUND(
        CASE
            WHEN exemption_applied = 1 OR is_taxable = 0 THEN 0
            ELSE line_amount * combined_rate
        END - tax_collected, 2)                        AS variance
FROM v_transaction_detail
ORDER BY ABS(
    CASE
        WHEN exemption_applied = 1 OR is_taxable = 0 THEN 0
        ELSE line_amount * combined_rate
    END - tax_collected) DESC;


-- -----------------------------------------------------------------------------
-- Q3. Under- / over-collection exposure  (CTE)
-- PURPOSE: Roll the line-level variance up to a single exposure number and
--          classify each line. Under-collection is a liability; over-collection
--          is a customer-refund / overpayment risk.
-- SKILL:   CTE, CASE classification, HAVING-style filter via WHERE on CTE.
-- -----------------------------------------------------------------------------
WITH line_variance AS (
    SELECT
        invoice_no, state_code, sku, line_amount, tax_collected,
        ROUND(CASE WHEN exemption_applied = 1 OR is_taxable = 0
                   THEN 0 ELSE line_amount * combined_rate END, 2) AS expected_tax
    FROM v_transaction_detail
)
SELECT
    invoice_no, state_code, sku, line_amount, expected_tax, tax_collected,
    ROUND(expected_tax - tax_collected, 2) AS variance,
    CASE
        WHEN ROUND(expected_tax - tax_collected, 2) > 0  THEN 'UNDER-COLLECTED (liability)'
        WHEN ROUND(expected_tax - tax_collected, 2) < 0  THEN 'OVER-COLLECTED (refund risk)'
        ELSE 'OK'
    END AS finding
FROM line_variance
WHERE ROUND(expected_tax - tax_collected, 2) <> 0
ORDER BY variance DESC;


-- -----------------------------------------------------------------------------
-- Q4. Exemptions claimed without a valid certificate  (audit risk #1)
-- PURPOSE: Find transactions sold as exempt where there is NO certificate, or
--          the certificate was EXPIRED on the transaction date. These are the
--          most common findings in a state sales-tax audit.
-- SKILL:   LEFT JOIN with date-window predicate, NULL detection, correlated logic.
-- -----------------------------------------------------------------------------
SELECT
    t.invoice_no,
    c.customer_name,
    c.customer_type,
    j.state_code,
    t.txn_date,
    ec.certificate_no,
    ec.expiry_date,
    CASE
        WHEN ec.certificate_id IS NULL THEN 'NO CERTIFICATE ON FILE'
        WHEN ec.expiry_date IS NOT NULL AND ec.expiry_date < t.txn_date
             THEN 'CERTIFICATE EXPIRED'
    END AS risk_flag,
    ROUND(SUM(tl.quantity * tl.unit_price), 2) AS exempt_sales_at_risk
FROM transactions t
JOIN customers          c  ON c.customer_id = t.customer_id
JOIN jurisdictions      j  ON j.jurisdiction_id = t.jurisdiction_id
JOIN transaction_lines  tl ON tl.transaction_id = t.transaction_id
LEFT JOIN exemption_certificates ec
       ON ec.customer_id     = t.customer_id
      AND ec.jurisdiction_id = t.jurisdiction_id
      AND ec.issued_date    <= t.txn_date
WHERE t.exemption_applied = 1
  AND (ec.certificate_id IS NULL
       OR (ec.expiry_date IS NOT NULL AND ec.expiry_date < t.txn_date))
GROUP BY t.invoice_no, c.customer_name, c.customer_type, j.state_code,
         t.txn_date, ec.certificate_no, ec.expiry_date
ORDER BY exempt_sales_at_risk DESC;


-- -----------------------------------------------------------------------------
-- Q5. Estimated tax exposure from invalid exemptions
-- PURPOSE: Quantify the potential assessment: tax that WOULD have been due on
--          the unsupported exempt sales, at the statutory rate.
-- SKILL:   CTE chaining, joining back to rates via the view.
-- -----------------------------------------------------------------------------
WITH bad_exemptions AS (
    SELECT t.transaction_id
    FROM transactions t
    LEFT JOIN exemption_certificates ec
           ON ec.customer_id     = t.customer_id
          AND ec.jurisdiction_id = t.jurisdiction_id
          AND ec.issued_date    <= t.txn_date
          AND (ec.expiry_date IS NULL OR ec.expiry_date >= t.txn_date)
    WHERE t.exemption_applied = 1
      AND ec.certificate_id IS NULL          -- no valid (unexpired) cert matched
)
SELECT
    v.state_code,
    COUNT(DISTINCT v.transaction_id)          AS risky_invoices,
    ROUND(SUM(v.line_amount), 2)              AS unsupported_exempt_sales,
    ROUND(SUM(v.line_amount * v.combined_rate), 2) AS estimated_tax_exposure
FROM v_transaction_detail v
JOIN bad_exemptions b ON b.transaction_id = v.transaction_id
WHERE v.is_taxable = 1
GROUP BY v.state_code
ORDER BY estimated_tax_exposure DESC;


-- -----------------------------------------------------------------------------
-- Q6. Economic nexus tracking (post-Wayfair)  (window functions)
-- PURPOSE: Running total of sales and transaction counts per state through the
--          year, flagging the point where the company crosses a state's nexus
--          threshold and must register to collect.
-- SKILL:   Window functions (SUM/COUNT OVER ... ORDER BY), running totals.
-- -----------------------------------------------------------------------------
WITH txn_totals AS (
    SELECT
        j.state_code,
        j.nexus_sales_threshold,
        t.txn_date,
        t.transaction_id,
        SUM(tl.quantity * tl.unit_price) AS invoice_amount
    FROM transactions t
    JOIN jurisdictions     j  ON j.jurisdiction_id = t.jurisdiction_id
    JOIN transaction_lines tl ON tl.transaction_id = t.transaction_id
    GROUP BY j.state_code, j.nexus_sales_threshold, t.txn_date, t.transaction_id
)
SELECT
    state_code,
    txn_date,
    invoice_amount,
    SUM(invoice_amount) OVER (
        PARTITION BY state_code ORDER BY txn_date, transaction_id
        ROWS UNBOUNDED PRECEDING)                       AS cumulative_sales,
    COUNT(*) OVER (
        PARTITION BY state_code ORDER BY txn_date, transaction_id
        ROWS UNBOUNDED PRECEDING)                       AS cumulative_txns,
    nexus_sales_threshold,
    CASE
        WHEN SUM(invoice_amount) OVER (
                 PARTITION BY state_code ORDER BY txn_date, transaction_id
                 ROWS UNBOUNDED PRECEDING) >= nexus_sales_threshold
        THEN 'NEXUS THRESHOLD CROSSED'
        ELSE ''
    END AS nexus_status
FROM txn_totals
ORDER BY state_code, txn_date, transaction_id;


-- -----------------------------------------------------------------------------
-- Q7. First date each state crosses its economic-nexus threshold
-- PURPOSE: The single most useful nexus output: "register in FL as of <date>".
-- SKILL:   CTE + window running total, then filter to the first crossing row
--          using a second window (ROW_NUMBER).
-- -----------------------------------------------------------------------------
WITH running AS (
    SELECT
        j.state_code,
        j.nexus_sales_threshold,
        t.txn_date,
        SUM(SUM(tl.quantity * tl.unit_price)) OVER (
            PARTITION BY j.state_code ORDER BY t.txn_date
            ROWS UNBOUNDED PRECEDING) AS cum_sales
    FROM transactions t
    JOIN jurisdictions     j  ON j.jurisdiction_id = t.jurisdiction_id
    JOIN transaction_lines tl ON tl.transaction_id = t.transaction_id
    GROUP BY j.state_code, j.nexus_sales_threshold, t.txn_date
),
crossed AS (
    SELECT state_code, txn_date, cum_sales, nexus_sales_threshold,
           ROW_NUMBER() OVER (PARTITION BY state_code ORDER BY txn_date) AS rn
    FROM running
    WHERE cum_sales >= nexus_sales_threshold
)
SELECT state_code,
       txn_date              AS nexus_trigger_date,
       ROUND(cum_sales, 2)   AS sales_at_crossing,
       nexus_sales_threshold
FROM crossed
WHERE rn = 1
ORDER BY nexus_trigger_date;


-- -----------------------------------------------------------------------------
-- Q8. Collected vs. remitted reconciliation by state / period
-- PURPOSE: Tie tax collected on invoices to tax remitted on filed returns.
--          Surfaces short-remittances and unfiled periods.
-- SKILL:   Aggregating facts to period grain, FULL-OUTER emulation via LEFT
--          JOIN, COALESCE, date functions (strftime).
-- -----------------------------------------------------------------------------
WITH collected AS (
    SELECT
        t.jurisdiction_id,
        CAST(strftime('%Y', t.txn_date) AS INTEGER)  AS yr,
        CAST(strftime('%m', t.txn_date) AS INTEGER)  AS mo,
        SUM(tl.tax_collected)                        AS tax_collected
    FROM transactions t
    JOIN transaction_lines tl ON tl.transaction_id = t.transaction_id
    GROUP BY t.jurisdiction_id, yr, mo
)
SELECT
    j.state_code,
    c.yr, c.mo,
    ROUND(c.tax_collected, 2)                        AS tax_collected,
    ROUND(COALESCE(r.tax_remitted, 0), 2)            AS tax_remitted,
    ROUND(c.tax_collected - COALESCE(r.tax_remitted, 0), 2) AS difference,
    CASE
        WHEN r.return_id IS NULL                         THEN 'RETURN NOT FILED'
        WHEN c.tax_collected - r.tax_remitted >  0.01    THEN 'UNDER-REMITTED'
        WHEN c.tax_collected - r.tax_remitted < -0.01    THEN 'OVER-REMITTED'
        ELSE 'RECONCILED'
    END AS status
FROM collected c
JOIN jurisdictions j ON j.jurisdiction_id = c.jurisdiction_id
LEFT JOIN tax_returns r
       ON r.jurisdiction_id = c.jurisdiction_id
      AND r.period_year     = c.yr
      AND r.period_month    = c.mo
ORDER BY j.state_code, c.yr, c.mo;


-- -----------------------------------------------------------------------------
-- Q9. Effective tax rate by state vs. statutory rate (rate validation)
-- PURPOSE: Compute the blended effective rate actually charged on taxable sales
--          and compare to the expected statutory blended rate. Large gaps point
--          to systemic rate-table errors.
-- SKILL:   Ratio aggregation, NULLIF to avoid divide-by-zero.
-- -----------------------------------------------------------------------------
SELECT
    state_code,
    ROUND(SUM(CASE WHEN is_taxable = 1 AND exemption_applied = 0
                   THEN line_amount ELSE 0 END), 2)         AS taxable_sales,
    ROUND(SUM(tax_collected), 2)                            AS tax_collected,
    ROUND( SUM(tax_collected) * 1.0
           / NULLIF(SUM(CASE WHEN is_taxable = 1 AND exemption_applied = 0
                             THEN line_amount ELSE 0 END), 0), 4) AS effective_rate,
    ROUND( SUM(CASE WHEN is_taxable = 1 AND exemption_applied = 0
                    THEN line_amount * combined_rate ELSE 0 END) * 1.0
           / NULLIF(SUM(CASE WHEN is_taxable = 1 AND exemption_applied = 0
                             THEN line_amount ELSE 0 END), 0), 4) AS expected_rate
FROM v_transaction_detail
GROUP BY state_code
ORDER BY state_code;


-- -----------------------------------------------------------------------------
-- Q10. Taxability matrix: product category x state
-- PURPOSE: Quick reference of how each category is treated in each state -- the
--          kind of decision table a tax engine is configured from.
-- SKILL:   PIVOT via conditional aggregation (MAX + CASE).
-- -----------------------------------------------------------------------------
SELECT
    tax_category,
    MAX(CASE WHEN state_code = 'CA' THEN taxable END) AS CA,
    MAX(CASE WHEN state_code = 'TX' THEN taxable END) AS TX,
    MAX(CASE WHEN state_code = 'NY' THEN taxable END) AS NY,
    MAX(CASE WHEN state_code = 'FL' THEN taxable END) AS FL,
    MAX(CASE WHEN state_code = 'WA' THEN taxable END) AS WA
FROM (
    SELECT j.state_code, r.tax_category,
           CASE WHEN r.is_taxable = 1 THEN 'Taxable' ELSE 'Exempt' END AS taxable
    FROM tax_rates r
    JOIN jurisdictions j ON j.jurisdiction_id = r.jurisdiction_id
    WHERE r.effective_to IS NULL          -- current rates only
)
GROUP BY tax_category
ORDER BY tax_category;


-- -----------------------------------------------------------------------------
-- Q11. Top customers by tax exposure (risk ranking)
-- PURPOSE: Rank customers by total unsupported-exempt + under-collected exposure
--          so the team knows whose certificates / invoices to chase first.
-- SKILL:   CTE, window RANK(), aggregation.
-- -----------------------------------------------------------------------------
WITH exposure AS (
    SELECT
        c.customer_name,
        SUM(
            CASE
                WHEN v.exemption_applied = 1 AND v.is_taxable = 1
                     AND NOT EXISTS (
                         SELECT 1 FROM exemption_certificates ec
                         WHERE ec.customer_id = v.customer_id
                           AND ec.jurisdiction_id = v.jurisdiction_id
                           AND ec.issued_date <= v.txn_date
                           AND (ec.expiry_date IS NULL OR ec.expiry_date >= v.txn_date))
                     THEN v.line_amount * v.combined_rate
                WHEN v.exemption_applied = 0 AND v.is_taxable = 1
                     THEN MAX(v.line_amount * v.combined_rate - v.tax_collected, 0)
                ELSE 0
            END) AS exposure_amount
    FROM v_transaction_detail v
    JOIN customers c ON c.customer_id = v.customer_id
    GROUP BY c.customer_name
)
SELECT
    RANK() OVER (ORDER BY exposure_amount DESC) AS risk_rank,
    customer_name,
    ROUND(exposure_amount, 2) AS total_exposure
FROM exposure
WHERE exposure_amount > 0
ORDER BY risk_rank;


-- -----------------------------------------------------------------------------
-- Q12. Monthly sales & tax trend with month-over-month growth
-- PURPOSE: Trend analysis for management reporting.
-- SKILL:   strftime period grouping, LAG() window function, growth %.
-- -----------------------------------------------------------------------------
WITH monthly AS (
    SELECT
        strftime('%Y-%m', t.txn_date)        AS period,
        SUM(tl.quantity * tl.unit_price)     AS sales,
        SUM(tl.tax_collected)                AS tax
    FROM transactions t
    JOIN transaction_lines tl ON tl.transaction_id = t.transaction_id
    GROUP BY period
)
SELECT
    period,
    ROUND(sales, 2)                                              AS sales,
    ROUND(tax, 2)                                                AS tax_collected,
    ROUND(LAG(sales) OVER (ORDER BY period), 2)                  AS prior_month_sales,
    ROUND( (sales - LAG(sales) OVER (ORDER BY period)) * 100.0
           / NULLIF(LAG(sales) OVER (ORDER BY period), 0), 1)    AS mom_growth_pct
FROM monthly
ORDER BY period;


-- -----------------------------------------------------------------------------
-- Q13. Certificates expiring within 180 days (proactive compliance)
-- PURPOSE: Operational worklist -- chase renewals before they lapse.
-- SKILL:   Date arithmetic (julianday), filtering, ordering.
-- -----------------------------------------------------------------------------
SELECT
    c.customer_name,
    j.state_code,
    ec.exemption_type,
    ec.certificate_no,
    ec.expiry_date,
    CAST(julianday(ec.expiry_date) - julianday('2026-06-21') AS INTEGER) AS days_to_expiry
FROM exemption_certificates ec
JOIN customers     c ON c.customer_id = ec.customer_id
JOIN jurisdictions j ON j.jurisdiction_id = ec.jurisdiction_id
WHERE ec.expiry_date IS NOT NULL
  AND julianday(ec.expiry_date) - julianday('2026-06-21') BETWEEN 0 AND 180
ORDER BY days_to_expiry;


-- -----------------------------------------------------------------------------
-- Q14. Already-expired certificates still being relied on
-- PURPOSE: Hard compliance gap -- expired certs that have been used to exempt
--          sales (cross-reference to actual usage).
-- SKILL:   EXISTS subquery, date comparison.
-- -----------------------------------------------------------------------------
SELECT
    c.customer_name,
    j.state_code,
    ec.certificate_no,
    ec.expiry_date,
    EXISTS (
        SELECT 1 FROM transactions t
        WHERE t.customer_id = ec.customer_id
          AND t.jurisdiction_id = ec.jurisdiction_id
          AND t.exemption_applied = 1
          AND t.txn_date > ec.expiry_date
    ) AS used_after_expiry
FROM exemption_certificates ec
JOIN customers     c ON c.customer_id = ec.customer_id
JOIN jurisdictions j ON j.jurisdiction_id = ec.jurisdiction_id
WHERE ec.expiry_date IS NOT NULL
  AND ec.expiry_date < '2026-06-21'
ORDER BY ec.expiry_date;


-- -----------------------------------------------------------------------------
-- Q15. Rate-change impact: lines taxed at a superseded rate
-- PURPOSE: After CA's mid-year TPP rate change, find sales that may have used
--          the old rate. Demonstrates effective-dated rate handling.
-- SKILL:   Self-aware date-window join, comparison of collected vs both rates.
-- -----------------------------------------------------------------------------
SELECT
    v.invoice_no,
    v.state_code,
    v.txn_date,
    v.tax_category,
    v.line_amount,
    v.combined_rate                                  AS rate_in_effect,
    ROUND(v.line_amount * v.combined_rate, 2)        AS expected_tax,
    v.tax_collected,
    ROUND(v.line_amount * v.combined_rate - v.tax_collected, 2) AS shortfall
FROM v_transaction_detail v
WHERE v.tax_category = 'TPP'
  AND v.state_code = 'CA'
  AND v.exemption_applied = 0
ORDER BY v.txn_date;


-- -----------------------------------------------------------------------------
-- Q16. Revenue and tax contribution by product category (with % of total)
-- PURPOSE: Which categories drive the tax footprint.
-- SKILL:   Window function for percent-of-total (SUM OVER ()).
-- -----------------------------------------------------------------------------
SELECT
    tax_category,
    ROUND(SUM(line_amount), 2)                                   AS sales,
    ROUND(SUM(line_amount) * 100.0 / SUM(SUM(line_amount)) OVER (), 1) AS pct_of_sales,
    ROUND(SUM(tax_collected), 2)                                 AS tax_collected
FROM v_transaction_detail
GROUP BY tax_category
ORDER BY sales DESC;


-- -----------------------------------------------------------------------------
-- Q17. Data-quality audit: lines with no matching tax rate
-- PURPOSE: Integrity check -- any taxable sale where the rate lookup returned
--          NULL means a gap in the rate table (a config bug).
-- SKILL:   Anti-pattern detection via NULL from LEFT JOIN in the view.
-- -----------------------------------------------------------------------------
SELECT
    invoice_no, state_code, sku, tax_category, txn_date
FROM v_transaction_detail
WHERE combined_rate IS NULL
ORDER BY state_code, txn_date;


-- -----------------------------------------------------------------------------
-- Q18. Exemption utilization rate by customer type
-- PURPOSE: How much of each customer type's volume is sold exempt -- helps
--          target certificate-management effort.
-- SKILL:   Conditional aggregation, ratio, GROUP BY.
-- -----------------------------------------------------------------------------
SELECT
    customer_type,
    ROUND(SUM(line_amount), 2)                                   AS total_sales,
    ROUND(SUM(CASE WHEN exemption_applied = 1 THEN line_amount ELSE 0 END), 2) AS exempt_sales,
    ROUND(SUM(CASE WHEN exemption_applied = 1 THEN line_amount ELSE 0 END) * 100.0
          / NULLIF(SUM(line_amount), 0), 1)                      AS pct_exempt
FROM v_transaction_detail
GROUP BY customer_type
ORDER BY pct_exempt DESC;


-- -----------------------------------------------------------------------------
-- Q19. Consolidated compliance scorecard by state  (the executive view)
-- PURPOSE: One row per state combining sales, collected, remitted, reconciliation
--          gap, and exemption-risk exposure. This is the deliverable a tax
--          director would actually look at.
-- SKILL:   Multiple CTEs joined together, COALESCE, layered aggregation.
-- -----------------------------------------------------------------------------
WITH sales_by_state AS (
    SELECT state_code,
           ROUND(SUM(line_amount), 2)   AS gross_sales,
           ROUND(SUM(tax_collected), 2) AS tax_collected
    FROM v_transaction_detail
    GROUP BY state_code
),
remitted_by_state AS (
    SELECT j.state_code, ROUND(SUM(r.tax_remitted), 2) AS tax_remitted
    FROM tax_returns r
    JOIN jurisdictions j ON j.jurisdiction_id = r.jurisdiction_id
    GROUP BY j.state_code
),
exemption_risk AS (
    SELECT v.state_code,
           ROUND(SUM(v.line_amount * v.combined_rate), 2) AS exempt_exposure
    FROM v_transaction_detail v
    WHERE v.exemption_applied = 1 AND v.is_taxable = 1
      AND NOT EXISTS (
          SELECT 1 FROM exemption_certificates ec
          WHERE ec.customer_id = v.customer_id
            AND ec.jurisdiction_id = v.jurisdiction_id
            AND ec.issued_date <= v.txn_date
            AND (ec.expiry_date IS NULL OR ec.expiry_date >= v.txn_date))
    GROUP BY v.state_code
)
SELECT
    s.state_code,
    s.gross_sales,
    s.tax_collected,
    COALESCE(rm.tax_remitted, 0)                              AS tax_remitted,
    ROUND(s.tax_collected - COALESCE(rm.tax_remitted, 0), 2) AS reconciliation_gap,
    COALESCE(er.exempt_exposure, 0)                          AS invalid_exemption_exposure
FROM sales_by_state s
LEFT JOIN remitted_by_state rm ON rm.state_code = s.state_code
LEFT JOIN exemption_risk    er ON er.state_code = s.state_code
ORDER BY s.gross_sales DESC;


-- -----------------------------------------------------------------------------
-- Q20. Overall exposure summary (single-number headline)
-- PURPOSE: Total quantified risk across the whole dataset -- the number that
--          goes at the top of the engagement summary.
-- SKILL:   UNION ALL to stack heterogeneous metrics into one labeled report.
-- -----------------------------------------------------------------------------
WITH variance AS (
    SELECT ROUND(SUM(
        MAX(CASE WHEN exemption_applied = 0 AND is_taxable = 1
                 THEN line_amount * combined_rate - tax_collected ELSE 0 END, 0)
    ), 2) AS amt
    FROM v_transaction_detail
),
invalid_exempt AS (
    SELECT ROUND(SUM(v.line_amount * v.combined_rate), 2) AS amt
    FROM v_transaction_detail v
    WHERE v.exemption_applied = 1 AND v.is_taxable = 1
      AND NOT EXISTS (
          SELECT 1 FROM exemption_certificates ec
          WHERE ec.customer_id = v.customer_id
            AND ec.jurisdiction_id = v.jurisdiction_id
            AND ec.issued_date <= v.txn_date
            AND (ec.expiry_date IS NULL OR ec.expiry_date >= v.txn_date))
),
unfiled AS (
    SELECT ROUND(SUM(tl.tax_collected), 2) AS amt
    FROM transactions t
    JOIN transaction_lines tl ON tl.transaction_id = t.transaction_id
    LEFT JOIN tax_returns r
           ON r.jurisdiction_id = t.jurisdiction_id
          AND r.period_year  = CAST(strftime('%Y', t.txn_date) AS INTEGER)
          AND r.period_month = CAST(strftime('%m', t.txn_date) AS INTEGER)
    WHERE r.return_id IS NULL
)
SELECT 'Under-collected tax (taxable sales)' AS exposure_type, COALESCE(amt,0) AS amount FROM variance
UNION ALL
SELECT 'Tax on unsupported exempt sales',     COALESCE(amt,0) FROM invalid_exempt
UNION ALL
SELECT 'Tax collected but not yet remitted',  COALESCE(amt,0) FROM unfiled;

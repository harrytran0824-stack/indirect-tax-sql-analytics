#!/usr/bin/env python3
"""
Generate an Entity-Relationship Diagram (ERD) of the indirect-tax schema.
Outputs erd.png and erd.svg using Graphviz.

Usage:  python3 make_erd.py
"""
import graphviz

g = graphviz.Digraph("ERD", format="png")
g.attr(rankdir="LR", bgcolor="white", nodesep="0.5", ranksep="1.0",
       fontname="Helvetica")
g.attr("node", shape="plaintext", fontname="Helvetica")
g.attr("edge", color="#5b6b7a", arrowhead="crow", arrowtail="none", dir="both",
       arrowsize="0.9")

HEADER = "#1f3a5f"   # EY-ish dark blue
PK = "#fff6d6"
ROW = "#ffffff"


def table(name, cols):
    """cols: list of (col, kind) where kind in {'PK','FK','PKFK',''}."""
    rows = (
        f'<TR><TD BGCOLOR="{HEADER}"><FONT COLOR="white">'
        f'<B>{name}</B></FONT></TD></TR>'
    )
    for col, kind in cols:
        bg = PK if "PK" in kind else ROW
        tag = ""
        if "PK" in kind:
            tag = " 🔑"
        elif "FK" in kind:
            tag = " ↗"
        label = f"<B>{col}</B>" if "PK" in kind else col
        rows += (
            f'<TR><TD ALIGN="LEFT" BGCOLOR="{bg}" PORT="{col}">'
            f'{label}{tag}</TD></TR>'
        )
    g.node(name, f'<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0">{rows}</TABLE>>')


table("jurisdictions", [
    ("jurisdiction_id", "PK"), ("state_code", ""), ("state_name", ""),
    ("locality", ""), ("nexus_sales_threshold", ""), ("nexus_txn_threshold", "")])
table("tax_rates", [
    ("rate_id", "PK"), ("jurisdiction_id", "FK"), ("tax_category", ""),
    ("is_taxable", ""), ("combined_rate", ""), ("effective_from", ""),
    ("effective_to", "")])
table("products", [
    ("product_id", "PK"), ("sku", ""), ("product_name", ""),
    ("tax_category", ""), ("unit_price", "")])
table("customers", [
    ("customer_id", "PK"), ("customer_name", ""), ("customer_type", ""),
    ("state_code", "")])
table("exemption_certificates", [
    ("certificate_id", "PK"), ("customer_id", "FK"), ("jurisdiction_id", "FK"),
    ("exemption_type", ""), ("issued_date", ""), ("expiry_date", ""),
    ("certificate_no", "")])
table("transactions", [
    ("transaction_id", "PK"), ("invoice_no", ""), ("customer_id", "FK"),
    ("jurisdiction_id", "FK"), ("txn_date", ""), ("exemption_applied", "")])
table("transaction_lines", [
    ("line_id", "PK"), ("transaction_id", "FK"), ("product_id", "FK"),
    ("quantity", ""), ("unit_price", ""), ("tax_collected", "")])
table("tax_returns", [
    ("return_id", "PK"), ("jurisdiction_id", "FK"), ("period_year", ""),
    ("period_month", ""), ("tax_remitted", ""), ("filed_date", "")])

# Relationships (parent -> child)
g.edge("jurisdictions:jurisdiction_id", "tax_rates:jurisdiction_id")
g.edge("jurisdictions:jurisdiction_id", "exemption_certificates:jurisdiction_id")
g.edge("jurisdictions:jurisdiction_id", "transactions:jurisdiction_id")
g.edge("jurisdictions:jurisdiction_id", "tax_returns:jurisdiction_id")
g.edge("customers:customer_id", "exemption_certificates:customer_id")
g.edge("customers:customer_id", "transactions:customer_id")
g.edge("transactions:transaction_id", "transaction_lines:transaction_id")
g.edge("products:product_id", "transaction_lines:product_id")

g.render("erd", cleanup=True)          # erd.png
g.format = "svg"
g.render("erd", cleanup=True)          # erd.svg
print("Wrote erd.png and erd.svg")

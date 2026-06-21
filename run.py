#!/usr/bin/env python3
"""
Build the Indirect Tax Compliance database and run every analytical query.

Usage:
    python3 run.py            # build in-memory and print all 20 query results
    python3 run.py tax.db     # also persist the database to tax.db

No third-party dependencies -- uses Python's built-in sqlite3.
"""
import sqlite3
import re
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()


def main():
    db_path = sys.argv[1] if len(sys.argv) > 1 else ":memory:"
    if db_path != ":memory:" and os.path.exists(db_path):
        os.remove(db_path)

    con = sqlite3.connect(db_path)
    con.executescript(load("01_schema.sql"))
    con.executescript(load("02_seed_data.sql"))
    print(f"Database built ({'in-memory' if db_path==':memory:' else db_path}).\n")

    sql = load("03_analysis_queries.sql")
    # Split the file into per-query blocks on the "-- Qn." headers.
    parts = re.split(r"\n-- -+\n-- (Q\d+)\.", sql)
    queries = {}
    titles = {}
    for i in range(1, len(parts), 2):
        label = parts[i]
        body = parts[i + 1]
        # First comment line after the header is the human title.
        title_match = re.search(r"^\s*([^\n]+)", body)
        titles[label] = title_match.group(1).strip() if title_match else ""
        start = re.search(r"\n(WITH|SELECT)\b", body)
        queries[label] = body[start.start():].strip().rstrip(";").strip()

    for n in range(1, 21):
        label = f"Q{n}"
        q = queries.get(label)
        if not q:
            continue
        cur = con.execute(q)
        rows = cur.fetchall()
        cols = [d[0] for d in cur.description]
        print("=" * 78)
        print(f"{label}. {titles[label]}   ({len(rows)} rows)")
        print("-" * 78)
        print(" | ".join(cols))
        for r in rows:
            print(" | ".join("" if v is None else str(v) for v in r))
        print()

    con.commit()
    con.close()


if __name__ == "__main__":
    main()

import os
import sqlite3

p = os.path.expandvars(r"%LOCALAPPDATA%\Sideloadly\installations.db")
print("db:", p, os.path.exists(p))
con = sqlite3.connect(p)
tables = [r[0] for r in con.execute("select name from sqlite_master where type='table'")]
print("tables:", tables)
for t in tables:
    cur = con.execute("select * from %s" % t)
    cols = [d[0] for d in cur.description]
    rows = cur.fetchall()
    print("--", t, cols, "rows=%d" % len(rows))
    for r in rows[:8]:
        print("   ", r)

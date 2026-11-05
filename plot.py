# AI acknowledgment: this plotting script was generated with the assistance of
# Claude (Anthropic) and reviewed by me. Data extraction is done in Bash (server.sh).
import sys
import csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

years, pops = [], []
with open(sys.argv[1]) as f:
    for row in csv.reader(f):
        years.append(int(row[0])); pops.append(float(row[1]))

plt.figure(figsize=(8, 4))
plt.plot(years, pops, marker="o")
plt.xlabel("Year"); plt.ylabel("Population"); plt.title("NSW population")
plt.grid(True); plt.tight_layout()
plt.savefig(sys.argv[2])

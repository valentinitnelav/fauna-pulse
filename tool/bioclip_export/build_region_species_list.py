#!/usr/bin/env python3
"""Write a species-list CSV of the TreeOfLife arthropods that GBIF has records for in a
region, for build_label_pack.py --species-csv.

Where the idea comes from: BioCLIP's own documentation recommends restricting the
TreeOfLife candidates to a regional species list built from GBIF (or Map of Life) and
passing it to pybioclip's `--subset` / `apply_filter` ("Geo-Restricted Taxon List
Predictions", https://imageomics.github.io/pybioclip/geo-restricted-taxa/, Imageomics).
The implementation approach followed here (own code, no lines copied) is the one in
Max Sittinger's insect-detect-post, `src/insectdetect_post/build_region_filter.py`
(AGPL-3.0): the GBIF occurrence facet is queried through the API (taxon keys with at
least --min-occurrences records in the region, his default 3) instead of a manual GBIF
download, and TreeOfLife species are mapped to GBIF backbone keys with the table he
publishes as a release asset (tol_gbif_taxon_keys_Arthropoda.csv, from his
filters/resolve_tol_gbif_species.py; downloaded here on first use, not redistributed).
Differences here: regions may be GBIF continents (EUROPE, ASIA, AFRICA, NORTH_AMERICA,
SOUTH_AMERICA, OCEANIA, ANTARCTICA) or a union of ISO country codes, and the query is
restricted per order instead of per phylum.

Citations: pybioclip / BioCLIP (Imageomics, MIT): https://github.com/Imageomics/pybioclip;
Stevens et al. (2024) BioCLIP, CVPR; Gu et al. (2025) BioCLIP 2, NeurIPS.
Sittinger, M. (2026). Software for post-processing of data captured with the Insect
Detect camera trap (v1.0.0). Zenodo. https://doi.org/10.5281/zenodo.21822140
(https://github.com/maxsitt/insect-detect-post). GBIF occurrence data: GBIF.org,
https://www.gbif.org (the query date is written to the .json next to the CSV).

Examples:
    python build_region_species_list.py --continent EUROPE --orders Diptera,Hymenoptera,Coleoptera,Lepidoptera --out out/species_europe_pollinator_orders.csv
    python build_region_species_list.py --countries DE,AT,CH,CZ,PL --orders Diptera,Hymenoptera --out out/species_central_europe_flies_bees.csv

Then:
    python build_label_pack.py --model bioclip-2 --species-csv out/species_europe_pollinator_orders.csv --pack-id bioclip2_pollinator_orders_europe_v1 --out ./out

Only arthropods are covered by the mapping; other groups need their own key mapping.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path

MAPPING_URL = "https://github.com/maxsitt/insect-detect-post/releases/download/v1.0.0/tol_gbif_taxon_keys_Arthropoda.csv"
GBIF_API = "https://api.gbif.org/v1"
FACET_LIMIT = 1_200_000
RETRIES = 4


def _get_json(url: str, timeout: int = 180) -> dict:
    last = None
    for attempt in range(RETRIES):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if 400 <= e.code < 500 and e.code != 429:
                raise
            last = e
        except Exception as e:  # network hiccups, 5xx
            last = e
        time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"GBIF request failed after {RETRIES} attempts: {last}")


def order_key(name: str) -> int:
    """GBIF backbone key of an order name (e.g. Diptera -> 811)."""
    r = _get_json(f"{GBIF_API}/species/match?" + urllib.parse.urlencode({"name": name, "rank": "ORDER", "strict": "true"}))
    if r.get("matchType") == "NONE" or "usageKey" not in r:
        raise ValueError(f"GBIF does not know an order named {name!r}")
    return int(r["usageKey"])


def taxon_counts(region: dict, order_k: int, min_occ: int) -> dict[int, int]:
    """All GBIF taxon keys (any rank) with >= min_occ records of this order in the region."""
    params = {**region, "taxonKey": order_k, "limit": 0, "facet": "taxonKey",
              "facetMincount": min_occ, "facetLimit": FACET_LIMIT}
    r = _get_json(f"{GBIF_API}/occurrence/search?" + urllib.parse.urlencode(params))
    counts = r["facets"][0]["counts"] if r.get("facets") else []
    if len(counts) >= FACET_LIMIT:
        raise RuntimeError("GBIF facet truncated; raise FACET_LIMIT")
    return {int(c["name"]): int(c["count"]) for c in counts}


def load_mapping(path: Path) -> list[dict]:
    if not path.exists():
        print(f"Downloading the TreeOfLife-to-GBIF mapping (41 MB) to {path} ...")
        path.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(MAPPING_URL, path)
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--continent", help="GBIF continent, e.g. EUROPE")
    g.add_argument("--countries", help="comma list of ISO 3166-1 alpha-2 codes, e.g. DE,AT,CH")
    ap.add_argument("--orders", required=True, help="comma list of order names")
    ap.add_argument("--min-occurrences", type=int, default=3, help="GBIF records needed in the region (default 3)")
    ap.add_argument("--mapping", type=Path, default=Path("out/tol_gbif_taxon_keys_Arthropoda.csv"))
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    regions = ([{"continent": args.continent.upper()}] if args.continent
               else [{"country": c.strip().upper()} for c in args.countries.split(",") if c.strip()])
    orders = [o.strip() for o in args.orders.split(",") if o.strip()]
    mapping = load_mapping(args.mapping)
    print(f"mapping: {len(mapping)} TreeOfLife arthropod species with a GBIF key")

    keys_in_region: dict[int, int] = {}
    for o in orders:
        k = order_key(o)
        for region in regions:
            t0 = time.time()
            counts = taxon_counts(region, k, args.min_occurrences)
            for key, n in counts.items():
                keys_in_region[key] = keys_in_region.get(key, 0) + n
            print(f"  {o} ({k}) in {region}: {len(counts)} taxon keys ({time.time() - t0:.0f} s)")

    wanted_orders = set(orders)
    rows = [m for m in mapping
            if m["order"] in wanted_orders and m.get("gbif_taxon_key")
            and int(m["gbif_taxon_key"]) in keys_in_region]
    rows.sort(key=lambda m: (m["order"], m["family"], m["species"]))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["species", "genus", "family", "order", "class", "gbif_taxon_key", "gbif_occurrences_in_region"])
        for m in rows:
            w.writerow([m["species"], m["genus"], m["family"], m["order"], m["class"], m["gbif_taxon_key"],
                        keys_in_region[int(m["gbif_taxon_key"])]])
    meta = {"regions": regions, "orders": orders, "min_occurrences": args.min_occurrences,
            "species": len(rows), "mapping": str(args.mapping), "date": date.today().isoformat()}
    args.out.with_suffix(".json").write_text(json.dumps(meta, indent=2))
    per_order = {o: sum(1 for m in rows if m["order"] == o) for o in orders}
    print(f"wrote {args.out}: {len(rows)} species {per_order}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

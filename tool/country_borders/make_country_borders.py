"""Writes the country borders the app bundles and the shared test points (PC tool).

The app turns a session's position into a country code, offline, to choose the names GBIF
lists in that country (lib/fauna_pulse/identification/country_lookup.dart). The shapes must
give the same codes as the country lists of the name lists, so this tool takes them from the
loader that built those lists: `load_countries` in bioclip_export/country_neighbours.py of
fauna-pulse-models (https://github.com/valentinitnelav/fauna-pulse-models): Natural Earth map
units 1:10m v5.1.2 (public domain), units without an ISO code under the code GBIF uses.
Natural Earth draws de facto borders (a point in Crimea answers RU).

Outputs:
  assets/country_borders.json
      {"format", "version", "source", "countries": {code: [polygon, ...]}}; a polygon is a list
      of rings (outline first, then holes); a ring is a flat list lon, lat, lon, lat, ... in
      degrees, 3 decimals, the first point not repeated. Shapes simplified to about 2 km.
  test/fauna_pulse/fixtures/country_point_cases.json
      [{"name", "lat", "lon", "code"}]: the answer of the app's rule (inside a shape: its
      code; else the nearest shape within 25 km; else null), computed here from the shapes
      BEFORE simplifying. Only points whose answer the simplification cannot change are kept.

Run from the app repository (needs numpy and shapely; fauna-pulse-models' environment has both):
  python tool/country_borders/make_country_borders.py --models-repo ~/fauna-pulse-models \
      --natural-earth <folder of ne_10m_admin_0_map_units.geojson>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from datetime import date
from pathlib import Path

MAX_KM = 25.0  # the app's rule: a point outside every shape takes the nearest one within this
SAFE_INSIDE_KM = 5.0  # a test point inside a shape is at least this far from its border
SAFE_NEAR_KM = 15.0  # a test point outside is at most this far from the nearest shape ...
SAFE_OTHER_KM = 5.0  # ... and every other country is at least this much farther
SAFE_FAR_KM = 40.0  # or at least this far from every shape (answer: no country)

# (name, lat, lon, expected code): the expected code only guards against a mistyped
# coordinate; the answer written to the fixture is computed from the shapes.
POINTS = [
    ("Leipzig", 51.34, 12.37, "DE"), ("Berlin", 52.52, 13.40, "DE"), ("Munich", 48.14, 11.58, "DE"),
    ("Paris", 48.86, 2.35, "FR"), ("Madrid", 40.42, -3.70, "ES"), ("Milan", 45.46, 9.19, "IT"),
    ("Vienna", 48.21, 16.37, "AT"), ("Bern", 46.95, 7.45, "CH"), ("Prague", 50.08, 14.43, "CZ"),
    ("Warsaw", 52.23, 21.01, "PL"), ("Bucharest", 44.43, 26.10, "RO"), ("Cluj-Napoca", 46.77, 23.60, "RO"),
    ("Budapest", 47.50, 19.04, "HU"), ("Sofia", 42.70, 23.32, "BG"), ("Larissa", 39.64, 22.42, "GR"),
    ("Evora", 38.57, -7.91, "PT"), ("Birmingham", 52.48, -1.90, "GB"), ("Athlone", 53.42, -7.94, "IE"),
    ("Lillehammer", 61.12, 10.47, "NO"), ("Uppsala", 59.86, 17.64, "SE"), ("Tampere", 61.50, 23.76, "FI"),
    ("Viborg", 56.45, 9.40, "DK"), ("Utrecht", 52.09, 5.12, "NL"), ("Brussels", 50.85, 4.35, "BE"),
    ("Luxembourg", 49.61, 6.13, "LU"), ("Kyiv", 50.45, 30.52, "UA"), ("Minsk", 53.90, 27.57, "BY"),
    ("Moscow", 55.75, 37.62, "RU"), ("Ankara", 39.93, 32.86, "TR"), ("Pristina", 42.66, 21.17, "XK"),
    ("Iceland, inland", 64.90, -18.60, "IS"), ("Malta, inland", 35.89, 14.44, "MT"),
    ("Cyprus, north of the buffer zone", 35.25, 33.60, "CY"), ("Cyprus, south", 34.90, 33.00, "CY"),
    ("Crimea (de facto border)", 45.20, 34.20, "RU"), ("Golan (de facto border)", 33.00, 35.75, "IL"),
    ("Lesotho, inside South Africa", -29.60, 28.25, "LS"), ("Beersheba", 31.25, 34.79, "IL"),
    ("Marrakesh", 31.63, -8.00, "MA"), ("Kansas", 38.50, -98.00, "US"), ("Fairbanks", 64.84, -147.72, "US"),
    ("Saskatoon", 52.13, -106.67, "CA"), ("Brasilia", -15.78, -47.93, "BR"),
    ("Alice Springs", -23.70, 133.88, "AU"), ("Nagano", 36.20, 138.25, "JP"), ("Bhopal", 23.26, 77.41, "IN"),
    ("Xi'an", 34.27, 108.95, "CN"), ("Johannesburg", -26.20, 28.05, "ZA"), ("Kenya, inland", -0.02, 37.90, "KE"),
    ("New Zealand, South Island", -43.90, 170.50, "NZ"),
    # Small islands and coastal water: the nearest shape within 25 km.
    ("Heligoland", 54.18, 7.89, "DE"), ("North Sea off Sylt", 54.90, 8.15, "DE"),
    ("Baltic Sea off Ruegen", 54.76, 13.55, "DE"), ("Black Sea off Constanta", 44.17, 28.80, "RO"),
    ("Sea between the Faroe Islands", 62.00, -6.55, "FO"), ("Sea off Gozo", 36.13, 14.25, "MT"),
    # Far from every land: no country.
    ("Mid Atlantic", 30.00, -40.00, None), ("Pacific", 0.00, -140.00, None),
    ("Bay of Biscay", 45.00, -5.00, None), ("Central Mediterranean", 35.50, 18.50, None),
    ("Near the North Pole", 89.50, 0.00, None),
    # The poles and the 180 degree meridian.
    ("Near the South Pole", -89.50, 0.00, "AQ"), ("Chukotka, west of 180", 66.50, 179.00, "RU"),
    ("Chukotka, east of 180", 66.50, -179.00, "RU"), ("Sea west of Taveuni, across 180", -16.80, 179.80, "FJ"),
]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models-repo", type=Path, required=True, help="a clone of fauna-pulse-models")
    ap.add_argument("--natural-earth", type=Path, required=True, help="folder with ne_10m_admin_0_map_units.geojson")
    ap.add_argument("--simplify-km", type=float, default=2.0)
    ap.add_argument("--out", type=Path, default=Path("assets/country_borders.json"))
    ap.add_argument("--cases", type=Path, default=Path("test/fauna_pulse/fixtures/country_point_cases.json"))
    args = ap.parse_args()

    sys.path.insert(0, str(args.models_repo.expanduser() / "bioclip_export"))
    import country_neighbours as cn  # the loader of the name lists' country lists
    from shapely import affinity, clip_by_rect
    from shapely.geometry import Point

    ne = args.natural_earth.expanduser() / Path(cn.NE_URL).name
    digest = hashlib.sha256(ne.read_bytes()).hexdigest()
    if digest != cn.NE_SHA256:
        raise SystemExit(f"{ne}: SHA-256 {digest} is not the Natural Earth file the name lists were built with")
    countries = cn.load_countries(ne)
    km = cn.KM_PER_DEGREE

    # --- the borders file ---
    tol = args.simplify_km / km
    out: dict[str, list] = {}
    n_poly = n_points = 0

    def ring(coords, fallback=None) -> list[float] | None:
        pts = []
        for x, y in coords:
            p = (round(x, 3), round(y, 3))
            if not pts or pts[-1] != p:
                pts.append(p)
        if len(pts) > 1 and pts[0] == pts[-1]:
            pts.pop()
        if len(pts) < 3:
            return fallback
        return [v for p in pts for v in p]

    for code in sorted(countries):
        geom = countries[code]
        polys = []
        for part in (geom.geoms if geom.geom_type == "MultiPolygon" else [geom]):
            simple = part.simplify(tol, preserve_topology=True)
            # A shape smaller than the 3 decimals keeps a small triangle around its centre, so
            # every island still answers its country.
            c = part.representative_point()
            tiny = [round(c.x - 0.002, 3), round(c.y - 0.001, 3), round(c.x + 0.002, 3), round(c.y - 0.001, 3),
                    round(c.x, 3), round(c.y + 0.002, 3)]
            outline = ring(simple.exterior.coords, fallback=tiny)
            holes = [h for h in (ring(i.coords) for i in simple.interiors) if h]
            polys.append([outline, *holes])
            n_poly += 1
            n_points += sum(len(r) // 2 for r in polys[-1])
        out[code] = polys
    args.out.write_text(json.dumps({
        "format": "faunapulse-country-borders",
        "version": 1,
        "source": {
            "natural_earth": "ne_10m_admin_0_map_units v5.1.2 (public domain)",
            "sha256": cn.NE_SHA256,
            "codes": "fauna-pulse-models bioclip_export/country_neighbours.py (load_countries)",
            "simplify_km": args.simplify_km,
            "decimals": 3,
            "made": date.today().isoformat(),
        },
        "countries": out,
    }, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"wrote {args.out}: {len(out)} countries, {n_poly} polygons, {n_points} points, {args.out.stat().st_size / 1e6:.2f} MB")

    # --- the test points, from the shapes before simplifying ---
    def distances(lat: float, lon: float) -> list[tuple[float, str, bool]]:
        """(km, code, inside) of every country within 3 degrees of latitude, nearest first."""
        scale = max(math.cos(math.radians(lat)), 0.01)
        dy, dx = 3.0, 3.0 / scale
        found = []
        for code, geom in countries.items():
            best = None
            for shift in (0.0, 360.0, -360.0):  # shapes are cut at 180 degrees
                x = lon + shift
                if x - dx > geom.bounds[2] or x + dx < geom.bounds[0] or lat - dy > geom.bounds[3] or lat + dy < geom.bounds[1]:
                    continue
                near = clip_by_rect(geom, x - dx, lat - dy, x + dx, lat + dy)
                if near.is_empty:
                    continue
                p = Point(x, lat)
                inside = near.contains(p)
                shape = near.boundary if inside else near
                d = affinity.scale(shape, xfact=scale, yfact=1.0, origin=(0, 0)).distance(Point(x * scale, lat)) * km
                if best is None or (inside, -d) > (best[2], -best[0]):
                    best = (d, code, inside)
            if best:
                found.append(best)
        # An inside point first (its number is the distance to its own border), then by distance.
        return sorted(found, key=lambda t: (not t[2], t[0]))

    cases, problems = [], []
    for name, lat, lon, expected in POINTS:
        d = distances(lat, lon)
        if d and d[0][2]:
            code = d[0][1]
            others = [t[0] for t in d[1:]]
            safe = d[0][0] >= SAFE_INSIDE_KM or not others or min(others) >= SAFE_OTHER_KM
            how = f"inside, {d[0][0]:.0f} km from its border"
        elif d and d[0][0] <= MAX_KM:
            code = d[0][1]
            safe = d[0][0] <= SAFE_NEAR_KM and all(t[0] >= d[0][0] + SAFE_OTHER_KM for t in d[1:])
            how = f"{d[0][0]:.0f} km from the nearest shape"
        else:
            code = None
            safe = not d or d[0][0] >= SAFE_FAR_KM
            how = f"{d[0][0]:.0f} km from the nearest shape" if d else "no shape within 3 degrees"
        if code != expected:
            problems.append(f"{name}: computed {code} ({how}), expected {expected}")
        elif not safe:
            problems.append(f"{name}: {code} ({how}) is too close to call after simplifying; move the point")
        else:
            cases.append({"name": name, "lat": lat, "lon": lon, "code": code})
            print(f"  {name}: {code} ({how})")
    if problems:
        raise SystemExit("Test points to fix:\n  " + "\n  ".join(problems))
    args.cases.write_text(json.dumps(cases, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {args.cases}: {len(cases)} points")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

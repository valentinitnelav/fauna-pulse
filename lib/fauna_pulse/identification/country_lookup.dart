// FaunaPulse (round 374): the country of a position, on the phone, without internet.
//
// A name list with country lists (label_pack.dart, `regions`) can be narrowed to the names
// GBIF lists in the session's country (name_list_region.dart). This file answers "which
// country is this position in" from `assets/country_borders.json`: Natural Earth map units
// 1:10m v5.1.2 (public domain), simplified to about 2 km and written by
// tool/country_borders/make_country_borders.py with the loader that built the name lists'
// country lists (fauna-pulse-models), so both use the same codes. The position never leaves
// the phone.
//
// Rule: inside a shape, its code; outside every shape, the nearest shape within 25 km (GBIF
// counts coastal waters as the country, and a position at the coast or on an islet the map
// lacks would otherwise have no country); farther out, none. Natural Earth draws de facto
// borders (a position in Crimea answers RU, where GBIF files records under UA); the Identify
// page shows the country and lets the user choose another.
//
// The point-in-polygon test is the common even-odd ray crossing rule (no code copied).

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../logging/app_error_hooks.dart';

/// A position outside every shape takes the nearest country within this distance.
const kNearestCountryKm = 25.0;

/// km per degree of latitude (mean Earth radius), as the builder of the borders file uses.
const _kmPerDegree = 6371.0088 * math.pi / 180;

class _Polygon {
  final String code;

  /// Rings as flat lists lon, lat, lon, lat, ...: the outline first, then the holes.
  final List<Float64List> rings;
  final double minLon, minLat, maxLon, maxLat;

  _Polygon(this.code, this.rings, this.minLon, this.minLat, this.maxLon, this.maxLat);

  /// Even-odd rule over all rings: inside the outline and in no hole.
  bool contains(double lon, double lat) {
    if (lon < minLon || lon > maxLon || lat < minLat || lat > maxLat) return false;
    var inside = false;
    for (final r in rings) {
      final n = r.length ~/ 2;
      for (var i = 0, j = n - 1; i < n; j = i++) {
        final xi = r[2 * i], yi = r[2 * i + 1], xj = r[2 * j], yj = r[2 * j + 1];
        if ((yi > lat) != (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) inside = !inside;
      }
    }
    return inside;
  }

  /// Distance in km from the position to this polygon's nearest edge. Longitudes are scaled
  /// by [cosLat], the cosine of the position's latitude: good enough over a few tens of km.
  double distanceKm(double lon, double lat, double cosLat) {
    var best = double.infinity;
    for (final r in rings) {
      final n = r.length ~/ 2;
      for (var i = 0, j = n - 1; i < n; j = i++) {
        final ax = (r[2 * j] - lon) * cosLat, ay = r[2 * j + 1] - lat;
        final bx = (r[2 * i] - lon) * cosLat, by = r[2 * i + 1] - lat;
        final dx = bx - ax, dy = by - ay;
        final len2 = dx * dx + dy * dy;
        // The point of the edge nearest to the position (which is the origin here).
        final t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
        final px = ax + t * dx, py = ay + t * dy;
        final d = px * px + py * py;
        if (d < best) best = d;
      }
    }
    return math.sqrt(best) * _kmPerDegree;
  }
}

/// The country shapes of `assets/country_borders.json`.
class CountryBorders {
  final List<_Polygon> _polygons;

  CountryBorders._(this._polygons);

  /// Parses the borders file ([text]); a FormatException when it is not shaped like one.
  static CountryBorders parse(String text) {
    final root = jsonDecode(text);
    final countries = root is Map ? root['countries'] : null;
    if (countries is! Map) throw const FormatException('No countries in the borders file');
    final polygons = <_Polygon>[];
    for (final e in countries.entries) {
      final code = e.key, shapes = e.value;
      if (code is! String || shapes is! List) throw const FormatException('A country without shapes in the borders file');
      for (final shape in shapes) {
        if (shape is! List || shape.isEmpty) throw FormatException('An empty shape for $code in the borders file');
        final rings = <Float64List>[];
        for (final ring in shape) {
          if (ring is! List || ring.length < 6 || ring.length.isOdd || ring.any((v) => v is! num)) {
            throw FormatException('A ring of $code in the borders file is not a list of positions');
          }
          rings.add(Float64List.fromList([for (final v in ring) (v as num).toDouble()]));
        }
        var minLon = double.infinity, minLat = double.infinity, maxLon = -double.infinity, maxLat = -double.infinity;
        final outline = rings.first;
        for (var i = 0; i < outline.length; i += 2) {
          minLon = math.min(minLon, outline[i]);
          maxLon = math.max(maxLon, outline[i]);
          minLat = math.min(minLat, outline[i + 1]);
          maxLat = math.max(maxLat, outline[i + 1]);
        }
        polygons.add(_Polygon(code, rings, minLon, minLat, maxLon, maxLat));
      }
    }
    return CountryBorders._(polygons);
  }

  /// The two-letter code of the country at [lat], [lon] (degrees), by the rule in the file
  /// header; null when the position is farther than [maxKm] from every country, or not a
  /// position.
  String? countryAt(double lat, double lon, {double maxKm = kNearestCountryKm}) {
    if (!lat.isFinite || !lon.isFinite || lat.abs() > 90) return null;
    final x = (lon + 180) % 360 - 180; // -180 .. 180, as the shapes
    for (final p in _polygons) {
      if (p.contains(x, lat)) return p.code;
    }
    // Not on the map's land: the nearest shape. A degree of longitude shrinks with the
    // latitude; the shapes are cut at 180 degrees, so the position is also tried one turn
    // to the east and to the west.
    final cosLat = math.max(math.cos(lat * math.pi / 180), 0.01);
    final dLat = maxKm / _kmPerDegree, dLon = dLat / cosLat;
    String? best;
    var bestKm = maxKm;
    for (final p in _polygons) {
      if (lat < p.minLat - dLat || lat > p.maxLat + dLat) continue;
      for (final shift in const [0.0, 360.0, -360.0]) {
        final sx = x + shift;
        if (sx < p.minLon - dLon || sx > p.maxLon + dLon) continue;
        final km = p.distanceKm(sx, lat, cosLat);
        if (km <= bestKm) {
          bestKm = km;
          best = p.code;
        }
      }
    }
    return best;
  }
}

/// The position of a session, from the `location` of its start record (`lat`, `lon`); null
/// when the session has none (no GPS and none typed, most imported videos).
Future<(double, double)?> sessionPositionOf(Directory sessionDir) async {
  try {
    final log = File('${sessionDir.path}/session.jsonl');
    if (!await log.exists()) return null;
    // The start record is the first line of the log.
    final lines = log.openRead().transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines.take(3)) {
      if (line.trim().isEmpty) continue;
      final rec = jsonDecode(line);
      if (rec is! Map || rec['type'] != 'start_of_session') continue;
      final loc = rec['location'];
      final lat = loc is Map ? loc['lat'] : null, lon = loc is Map ? loc['lon'] : null;
      return lat is num && lon is num ? (lat.toDouble(), lon.toDouble()) : null;
    }
  } catch (e) {
    logSwallowed('session_position', e);
  }
  return null;
}

Future<CountryBorders?>? _borders;

/// The bundled borders, read once per app run and parsed in a helper isolate (about 2 MB of
/// text); null when they cannot be read, which only costs the automatic country.
Future<CountryBorders?> bundledCountryBorders() => _borders ??= () async {
  try {
    final text = await rootBundle.loadString('assets/country_borders.json', cache: false);
    return await Isolate.run(() => CountryBorders.parse(text));
  } catch (e) {
    logSwallowed('country_borders', e);
    return null;
  }
}();

/// The country of [sessionDir]'s position, or null: no position, a position far from every
/// country, or borders that cannot be read. The borders are only read for a session with a
/// position.
Future<String?> sessionCountryOf(Directory sessionDir) async {
  final position = await sessionPositionOf(sessionDir);
  if (position == null) return null;
  return (await bundledCountryBorders())?.countryAt(position.$1, position.$2);
}

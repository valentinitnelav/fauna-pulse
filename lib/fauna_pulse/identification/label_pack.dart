// FaunaPulse (round 208): label packs for on-device identification.
//
// A "label pack" is one file holding, for every candidate name the model may
// choose from, its text embedding (a unit-length vector produced once on a PC
// by build_label_pack.py (fauna-pulse-models, bioclip_export/) from the TreeOfLife-200M name
// embeddings published by Imageomics) plus its taxonomy (kingdom .. species
// epithet, common name). This is pybioclip's label-subset idea (`--subset` /
// `apply_filter` over precomputed name embeddings) in a phone-friendly file.
// A few "sink" rows (kingdom `none`: flower, leaf, shadow, ...) give false
// detections a place to go. Container format ("fpack", little-endian):
//   bytes 0..3  ASCII "FPK1"
//   bytes 4..7  uint32 header length H
//   8..8+H      UTF-8 JSON header (pack_id, model_id, dim, rows, dtype f16|f32,
//               logit_scale, temperature, ranks, sink_rows, labels[rows][8], ...)
//   then        rows x dim numbers, row-major, f16 or f32
// The Python writer (fauna-pulse-models, bioclip_export/fpack.py) and this reader are
// tested against the same fixtures (test/fauna_pulse/fixtures/*.fpack): change both together.
//
// Round 266, class lists: a fixed-class classifier (insectDCT, fauna-pulse-models classifier_export/)
// scores its own classes, so its "pack" has no vectors (dtype none, header kind
// "classes"): rows = its finest classes with their taxonomy, "classes" = the
// model's own class names, "heads" = the model's output layers one after another
// (sizes add up to dim, the model's output length), "head_index" = each row's
// class in every head. Scorer (track_fusion.dart) turns the raw scores into one
// probability per row; everything after that is the same as for BioCLIP.
//
// Words (round 276, owner: one name per thing): the screens call both kinds a
// NAME LIST, either a LABEL PACK (BioCLIP) or a CLASS LIST (a classifier). The
// file format of both is ".fpack" (FaunaPulse pack); in the code "pack" means
// such a file of either kind. Since round 276 the header's "kind" is
// "label_pack" or "class_list", the words of assets/model_downloads.json;
// files written before say "classes" for a class list and nothing for a label
// pack, and are read the same way ([isClassListHeader]).
//
// Round 372, two optional header blocks (packs named `_v3` and later; format reference:
// fpack.py's module docstring in fauna-pulse-models). A pack without them, or with a damaged
// one, loads as a plain pack:
//   "gbif":    species_key[rows], species[rows]: the Catalogue of Life species key GBIF uses
//              and its accepted name for every row (null for sink rows). Keys are text, also
//              the ones made of digits only.
//   "regions": countries[code] = {rows: base64 of ceil(rows / 8) bytes, bit i = row i, least
//              significant bit first; names; names_in_country}, the names GBIF lists in that
//              country, and neighbours[code] = [codes]. Sink rows are never set. A
//              short_list_names field (mammals and birds v4) is not read: the app has no
//              short-list limit (the page shows the number of names instead).
// Idea of narrowing the names to a region: BioCLIP's documentation ("Geo-Restricted Taxon List
// Predictions", Imageomics). The lists and the key table are built as in insect-detect-post
// (Sittinger 2026) from GBIF.org records; the pack's own source notes name the query date.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Taxonomic ranks in pack order (index 0..6).
const List<String> kRankNames = [
  'kingdom',
  'phylum',
  'class',
  'order',
  'family',
  'genus',
  'species',
];

/// A classifier's class list, by its header's `kind`: "class_list" (written
/// since round 276) or "classes" (before). Anything else is a label pack.
bool isClassListHeader(Map<String, dynamic>? header) {
  final kind = header?['kind'];
  return kind == 'class_list' || kind == 'classes';
}

/// Kingdom value marking a "none of these" sink row.
const String kSinkKingdom = 'none';

/// One candidate: seven rank names (species = epithet only) + common name.
class LabelRow {
  final List<String> ranks;
  final String common;

  const LabelRow(this.ranks, this.common);

  bool get isSink => ranks.isNotEmpty && ranks[0] == kSinkKingdom;

  /// "Genus epithet" for species rows; the sink key for sink rows; for a
  /// class-list row that stops above species (round 266: insectDCT's
  /// "Bombus", "Apidae", "Coleoptera"), its deepest named rank.
  String get speciesName {
    if (isSink || ranks[6].isNotEmpty) return isSink ? ranks[6] : '${ranks[5]} ${ranks[6]}'.trim();
    for (var k = 5; k >= 0; k--) {
      if (ranks[k].isNotEmpty) return ranks[k];
    }
    return '';
  }

  /// Display name at [rankIndex] (species shown as "Genus epithet").
  String nameAt(int rankIndex) => rankIndex == 6 ? speciesName : ranks[rankIndex];

  /// Hierarchy key at [rankIndex]: the names from kingdom down to that rank
  /// joined with '|' — unique even when two families share a genus name.
  String keyAt(int rankIndex) => ranks.sublist(0, rankIndex + 1).join('|');
}

/// Converts an IEEE 754 half-precision bit pattern to a double.
double halfToFloat(int h) {
  final sign = (h >> 15) & 0x1;
  final exp = (h >> 10) & 0x1f;
  final frac = h & 0x3ff;
  double value;
  if (exp == 0) {
    value = frac / 1024.0 * 6.103515625e-5; // subnormal: 2^-14 * frac/1024
  } else if (exp == 0x1f) {
    value = frac == 0 ? double.infinity : double.nan;
  } else {
    // 2^(exp-15) * (1 + frac/1024)
    var p = exp - 15;
    var scale = 1.0;
    if (p >= 0) {
      for (var i = 0; i < p; i++) {
        scale *= 2;
      }
    } else {
      for (var i = 0; i < -p; i++) {
        scale /= 2;
      }
    }
    value = scale * (1 + frac / 1024.0);
  }
  return sign == 1 ? -value : value;
}

/// Round 372: one country of a pack's `regions` block.
class PackCountry {
  /// One bit per pack row (row 0 = bit 0 of byte 0): set when GBIF lists the row's name there.
  final Uint8List bits;

  /// Distinct names of the pack listed there, and the country's whole GBIF list for the
  /// pack's orders (the pack holds [names] of them: its coverage of the country).
  final int names;
  final int namesInCountry;

  const PackCountry(this.bits, this.names, this.namesInCountry);

  /// The share of the country's own GBIF list that the pack holds; null when that is unknown.
  double? get coverage => namesInCountry > 0 ? names / namesInCountry : null;
}

/// Round 372: the optional `regions` block, which names GBIF lists in which country.
class PackRegions {
  final Map<String, PackCountry> countries;

  /// Country code -> the codes next to it (a shared land border or a short sea crossing; the
  /// rule is the pack builder's, fauna-pulse-models `country_neighbours.py`).
  final Map<String, List<String>> neighbours;
  final int _bytes;

  const PackRegions._(this.countries, this.neighbours, this._bytes);

  /// The block of a pack with [rows] rows, or null when [block] is missing or damaged (a
  /// hand-made file must not stop the pack from loading: it then has no country lists).
  static PackRegions? tryParse(Object? block, int rows) {
    if (block is! Map || rows <= 0) return null;
    final raw = block['countries'], rawNext = block['neighbours'];
    if (raw is! Map || raw.isEmpty) return null;
    final nBytes = (rows + 7) ~/ 8;
    final countries = <String, PackCountry>{};
    for (final e in raw.entries) {
      final code = e.key, v = e.value;
      if (code is! String || v is! Map) return null;
      final b64 = v['rows'], names = v['names'], inCountry = v['names_in_country'];
      if (b64 is! String || names is! int || inCountry is! int) return null;
      final Uint8List bits;
      try {
        bits = base64.decode(b64);
      } on FormatException {
        return null;
      }
      if (bits.length != nBytes) return null;
      if (rows % 8 != 0) bits[nBytes - 1] &= (1 << (rows % 8)) - 1; // no rows past the last one
      countries[code] = PackCountry(bits, names, inCountry);
    }
    final next = <String, List<String>>{};
    if (rawNext is Map) {
      for (final e in rawNext.entries) {
        final code = e.key, v = e.value;
        if (code is String && v is List) next[code] = [for (final c in v) if (c is String) c];
      }
    }
    return PackRegions._(countries, next, nBytes);
  }

  /// [code] and its neighbours, the ones the pack has a list for (a neighbour without one adds
  /// no names); empty when the pack has no list for [code] itself.
  List<String> withNeighbours(String code) => [
    if (countries.containsKey(code)) ...[
      code,
      for (final c in neighbours[code] ?? const <String>[])
        if (c != code && countries.containsKey(c)) c,
    ],
  ];

  /// The rows GBIF lists in any of [codes], as bits like [PackCountry.bits]; a code the pack
  /// does not know adds nothing.
  Uint8List rowBits(Iterable<String> codes) {
    final out = Uint8List(_bytes);
    for (final c in codes) {
      final bits = countries[c]?.bits;
      if (bits == null) continue;
      for (var i = 0; i < _bytes; i++) {
        out[i] |= bits[i];
      }
    }
    return out;
  }

  static bool hasRow(Uint8List bits, int row) => bits[row >> 3] & (1 << (row & 7)) != 0;

  static int countRows(Uint8List bits) {
    var n = 0;
    for (var b in bits) {
      for (; b != 0; b &= b - 1) {
        n++;
      }
    }
    return n;
  }
}

/// Round 377: the orders and families of a pack's names, to narrow the names to some of them
/// by hand (name_list_region.dart).
///
/// A row counts for an order or a family only when every rank down to it is named: the rule
/// of the whole app (a row counts down to the rank above its first empty slot,
/// `Scorer.rollUp`). So a row that the pack builder answers only down to family (its genus
/// and species slots are empty: the `name_rules` rows) counts for its family and its order; a
/// row with an empty family counts for its order only; a row with an empty order counts for
/// neither, so it is never on offer once orders or families are chosen. The "none of these"
/// rows are left out (they are always on offer). Taxa are told apart by their name: no
/// published pack uses a name for two orders or two families, or for an order and a family
/// (should a pack do so, the name stands for all of them).
class PackTaxa {
  /// The names of the orders and of the families, each in alphabetical order.
  final List<String> orders;
  final List<String> families;

  /// Every family's order (an index into [orders]): the order of its first row.
  final List<int> familyOrder;

  /// Every row's order and family (indexes into [orders] and [families]); -1 = none.
  final Int32List rowOrder;
  final Int32List rowFamily;

  const PackTaxa._(this.orders, this.families, this.familyOrder, this.rowOrder, this.rowFamily);

  factory PackTaxa.of(List<LabelRow> labels) => PackTaxa._from(labels.length, (r, k) => labels[r].ranks[k]);

  /// From a header's `labels` as decoded (one list of names per row, a missing name as null
  /// or left out): no row objects are made, because every listing of the name lists builds
  /// this (with them, reading a header of 35,000 names took a third longer).
  factory PackTaxa.ofHeaderLabels(List<List> labels) => PackTaxa._from(labels.length, (r, k) {
    final entry = labels[r];
    return k < entry.length ? (entry[k] ?? '').toString() : '';
  });

  /// [rank] gives a row's name at a rank (0 = kingdom .. 4 = family), '' when it has none.
  factory PackTaxa._from(int n, String Function(int row, int rank) rank) {
    final orderOf = <String, int>{}, familyOf = <String, int>{};
    final orderOfFamily = <int>[];
    final rowOrder = Int32List(n)..fillRange(0, n, -1), rowFamily = Int32List(n)..fillRange(0, n, -1);
    for (var r = 0; r < n; r++) {
      final kingdom = rank(r, 0);
      if (kingdom.isEmpty || kingdom == kSinkKingdom || rank(r, 1).isEmpty || rank(r, 2).isEmpty) continue;
      final order = rank(r, 3);
      if (order.isEmpty) continue;
      final o = rowOrder[r] = orderOf.putIfAbsent(order, () => orderOf.length);
      final family = rank(r, 4);
      if (family.isEmpty) continue;
      rowFamily[r] = familyOf.putIfAbsent(family, () {
        orderOfFamily.add(o);
        return familyOf.length;
      });
    }
    // Alphabetical: the indexes above follow the rows, so they are renumbered.
    final orders = orderOf.keys.toList()..sort(), families = familyOf.keys.toList()..sort();
    final newOrder = List<int>.filled(orders.length, 0), newFamily = List<int>.filled(families.length, 0);
    for (var i = 0; i < orders.length; i++) {
      newOrder[orderOf[orders[i]]!] = i;
    }
    for (var i = 0; i < families.length; i++) {
      newFamily[familyOf[families[i]]!] = i;
    }
    for (var r = 0; r < n; r++) {
      if (rowOrder[r] >= 0) rowOrder[r] = newOrder[rowOrder[r]];
      if (rowFamily[r] >= 0) rowFamily[r] = newFamily[rowFamily[r]];
    }
    return PackTaxa._(orders, families, [for (final f in families) newOrder[orderOfFamily[familyOf[f]!]]], rowOrder, rowFamily);
  }

  /// Whether the pack has an order or a family of this name.
  bool contains(String name) => orders.contains(name) || families.contains(name);

  /// The rows of the orders and families named in [names], as bits like [PackCountry.bits]; a
  /// name the pack does not have adds nothing.
  Uint8List rowBits(Iterable<String> names) {
    final wanted = names.toSet();
    final o = [for (final x in orders) wanted.contains(x)], f = [for (final x in families) wanted.contains(x)];
    final out = Uint8List((rowOrder.length + 7) ~/ 8);
    for (var r = 0; r < rowOrder.length; r++) {
      final ro = rowOrder[r], rf = rowFamily[r];
      if ((ro >= 0 && o[ro]) || (rf >= 0 && f[rf])) out[r >> 3] |= 1 << (r & 7);
    }
    return out;
  }

  /// The number of names of every order and of every family, among the rows of [within]
  /// (bits; null = every row).
  ({List<int> orders, List<int> families}) counts([Uint8List? within]) {
    final o = List<int>.filled(orders.length, 0), f = List<int>.filled(families.length, 0);
    for (var r = 0; r < rowOrder.length; r++) {
      if (rowOrder[r] < 0 || (within != null && !PackRegions.hasRow(within, r))) continue;
      o[rowOrder[r]]++;
      if (rowFamily[r] >= 0) f[rowFamily[r]]++;
    }
    return (orders: o, families: f);
  }
}

/// Where [LabelPack.readHeader] puts the pack's [PackTaxa] (not a field of the file: the
/// names it is made from are left out of that map).
const kPackTaxaKey = '_taxa';

class LabelPack {
  final String packId;
  final String modelId;
  final int dim;
  final int rows;
  final int sinkRows;
  final double logitScale;
  final double temperature;
  final List<LabelRow> labels;

  /// rows × dim unit vectors, row-major (always f32 in memory).
  final Float32List matrix;

  /// The raw header (for the summary / provenance rows).
  final Map<String, dynamic> header;

  /// Round 266, class lists only (empty for BioCLIP packs): the size of each
  /// of the model's output layers, each row's class in every one of them
  /// (rows x heads, row-major), and the model's own name for each row.
  final List<int> headSizes;
  final Int32List headIndex;
  final List<String> classNames;

  /// Round 372, the optional `gbif` block: every row's GBIF species key and accepted name
  /// ('' for a row without one, such as a sink row); both empty when the pack has no block.
  final List<String> gbifKeys;
  final List<String> gbifSpecies;

  /// Round 372, the optional `regions` block; null when the pack has none.
  final PackRegions? regions;

  bool get isClassList => headSizes.isNotEmpty;

  LabelPack({
    required this.packId,
    required this.modelId,
    required this.dim,
    required this.rows,
    required this.sinkRows,
    required this.logitScale,
    required this.temperature,
    required this.labels,
    required this.matrix,
    required this.header,
    this.headSizes = const [],
    Int32List? headIndex,
    this.classNames = const [],
    this.gbifKeys = const [],
    this.gbifSpecies = const [],
    this.regions,
  }) : headIndex = headIndex ?? _noIndex;

  static final Int32List _noIndex = Int32List(0);

  /// The same pack over another copy of its vectors (round 359: a worker isolate's view of the
  /// matrix the scoring isolate put in native memory, see identification_job.dart).
  LabelPack withMatrix(Float32List matrix) => LabelPack(
    packId: packId,
    modelId: modelId,
    dim: dim,
    rows: rows,
    sinkRows: sinkRows,
    logitScale: logitScale,
    temperature: temperature,
    labels: labels,
    matrix: matrix,
    header: header,
    headSizes: headSizes,
    headIndex: headIndex,
    classNames: classNames,
    gbifKeys: gbifKeys,
    gbifSpecies: gbifSpecies,
    regions: regions,
  );

  /// What a scoring worker isolate needs and no more (round 372): the names and numbers the
  /// fusion reads, without vectors (the worker views the shared copy, [withMatrix]) and
  /// without the header, the GBIF keys and the country lists. An isolate message copies what
  /// it carries, once per worker, and those parts are megabytes in a pack with country lists.
  LabelPack forWorker() => LabelPack(
    packId: packId,
    modelId: modelId,
    dim: dim,
    rows: rows,
    sinkRows: sinkRows,
    logitScale: logitScale,
    temperature: temperature,
    labels: labels,
    matrix: Float32List(0),
    header: const {},
    headSizes: headSizes,
    headIndex: headIndex,
    classNames: classNames,
  );

  /// Dot product of the unit vector [e] (length [dim]) with pack row [row].
  double dot(Float32List e, int row) {
    final base = row * dim;
    var s = 0.0;
    for (var i = 0; i < dim; i++) {
      s += e[i] * matrix[base + i];
    }
    return s;
  }

  /// The dot products of [e] with every row at once, into [out] (length [rows]).
  ///
  /// Round 348 (perf review H4b): four lanes at a time (`Float32x4`, NEON on the phone) when
  /// the vectors are 16-byte aligned, which they are for every model so far (dim a multiple of
  /// 4; the embeddings file is read as a view from offset 0). The lanes are added up in double
  /// after every 16 quads, so the result stays within about 1e-6 of [dot], whose products are
  /// exact in double. Anything else (a class list has no matrix) takes [dot] row by row.
  void dotsInto(Float32List e, Float64List out) {
    final q = dim ~/ 4;
    if (dim % 4 != 0 || e.length < dim || e.offsetInBytes % 16 != 0 || matrix.offsetInBytes % 16 != 0 || matrix.length < rows * dim) {
      for (var r = 0; r < rows; r++) {
        out[r] = dot(e, r);
      }
      return;
    }
    final e4 = Float32x4List.view(e.buffer, e.offsetInBytes, q);
    final m4 = _matrix4 ??= Float32x4List.view(matrix.buffer, matrix.offsetInBytes, matrix.length ~/ 4);
    for (var r = 0; r < rows; r++) {
      final base = r * q;
      var s = 0.0;
      var i = 0;
      while (i < q) {
        var end = i + 16;
        if (end > q) end = q;
        var acc = Float32x4.zero();
        for (; i < end; i++) {
          acc += e4[i] * m4[base + i];
        }
        s += acc.x + acc.y + acc.z + acc.w;
      }
      out[r] = s;
    }
  }

  /// [dotsInto] for several vectors in one pass over the pack (round 359): every pack row is
  /// loaded once for eight vectors instead of once per vector, which made a pass 2.7 times
  /// faster per vector on the laptop (the loads and the loop were the cost, not the
  /// arithmetic). The arithmetic per vector is the same as in [dotsInto], so the values are
  /// bit-identical. Vectors left over (fewer than eight) take [dotsInto]. [es] and [outs] pair
  /// up by index; every [outs] entry has length [rows].
  void dotsIntoMany(List<Float32List> es, List<Float64List> outs) {
    final q = dim ~/ 4;
    var i = 0;
    if (dim % 4 == 0 && matrix.offsetInBytes % 16 == 0 && matrix.length >= rows * dim) {
      final m4 = _matrix4 ??= Float32x4List.view(matrix.buffer, matrix.offsetInBytes, matrix.length ~/ 4);
      for (; i + 8 <= es.length; i += 8) {
        final v = <Float32x4List>[];
        for (var j = 0; j < 8; j++) {
          final e = es[i + j];
          if (e.length < dim || e.offsetInBytes % 16 != 0) break;
          v.add(Float32x4List.view(e.buffer, e.offsetInBytes, q));
        }
        if (v.length < 8) break;
        _dots8(m4, q, v, outs.sublist(i, i + 8));
      }
    }
    for (; i < es.length; i++) {
      dotsInto(es[i], outs[i]);
    }
  }

  /// Eight vectors against every row: eight accumulators in local variables (a list of
  /// Float32x4 would box them), the quads summed into doubles every 16 quads as in [dotsInto].
  void _dots8(Float32x4List m4, int q, List<Float32x4List> v, List<Float64List> outs) {
    final v0 = v[0], v1 = v[1], v2 = v[2], v3 = v[3], v4 = v[4], v5 = v[5], v6 = v[6], v7 = v[7];
    final o0 = outs[0], o1 = outs[1], o2 = outs[2], o3 = outs[3], o4 = outs[4], o5 = outs[5], o6 = outs[6], o7 = outs[7];
    for (var r = 0; r < rows; r++) {
      final base = r * q;
      var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, s5 = 0.0, s6 = 0.0, s7 = 0.0;
      var i = 0;
      while (i < q) {
        var end = i + 16;
        if (end > q) end = q;
        var a0 = Float32x4.zero(), a1 = Float32x4.zero(), a2 = Float32x4.zero(), a3 = Float32x4.zero();
        var a4 = Float32x4.zero(), a5 = Float32x4.zero(), a6 = Float32x4.zero(), a7 = Float32x4.zero();
        for (; i < end; i++) {
          final m = m4[base + i];
          a0 += v0[i] * m;
          a1 += v1[i] * m;
          a2 += v2[i] * m;
          a3 += v3[i] * m;
          a4 += v4[i] * m;
          a5 += v5[i] * m;
          a6 += v6[i] * m;
          a7 += v7[i] * m;
        }
        s0 += a0.x + a0.y + a0.z + a0.w;
        s1 += a1.x + a1.y + a1.z + a1.w;
        s2 += a2.x + a2.y + a2.z + a2.w;
        s3 += a3.x + a3.y + a3.z + a3.w;
        s4 += a4.x + a4.y + a4.z + a4.w;
        s5 += a5.x + a5.y + a5.z + a5.w;
        s6 += a6.x + a6.y + a6.z + a6.w;
        s7 += a7.x + a7.y + a7.z + a7.w;
      }
      o0[r] = s0;
      o1[r] = s1;
      o2[r] = s2;
      o3[r] = s3;
      o4[r] = s4;
      o5[r] = s5;
      o6[r] = s6;
      o7[r] = s7;
    }
  }

  Float32x4List? _matrix4;

  /// The largest JSON header a pack may have (round 327). Real headers hold about 110 bytes
  /// per name (about 2 MB for 17,130 names), so this leaves room for packs of 100,000 names.
  static const kMaxLabelPackHeaderBytes = 16 << 20;

  /// Refuses a header whose JSON nests deeper than a real one or holds far more lists and
  /// objects than names (round 327): jsonDecode builds one Dart object per "[" or "{", so a
  /// header made of brackets used gigabytes of memory (1.46 GB for 16 MB). A real header nests
  /// 3 deep and has one short list per name (about 110 bytes). Brackets inside names are text.
  static void _checkJsonShape(List<int> hdr) {
    var depth = 0, containers = 0;
    var inString = false, escaped = false;
    for (final b in hdr) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (b == 0x5C) {
          escaped = true; // backslash
        } else if (b == 0x22) {
          inString = false;
        }
      } else if (b == 0x22) {
        inString = true;
      } else if (b == 0x5B || b == 0x7B) {
        // [ or {
        if (++depth > 16 || ++containers > 64 + hdr.length ~/ 16) {
          throw const FormatException('Label pack header is not shaped like a name list');
        }
      } else if (b == 0x5D || b == 0x7D) {
        depth--;
      }
    }
  }

  /// Reads only the JSON header of [file] (no matrix), for listings. A label pack's orders
  /// and families come along under [kPackTaxaKey] (round 377).
  ///
  /// Round 372: in a helper isolate. Decoding a header of tens of thousands of names took
  /// about 0.1 s on a laptop, 0.15 s with the GBIF keys and country lists of a `_v3` pack,
  /// and every listing reads every pack again: on the screen's thread that was a visible
  /// stall on a phone. The map comes back without a copy (Isolate.run hands it over).
  static Future<Map<String, dynamic>> readHeader(File file) {
    final path = file.path;
    return Isolate.run(() => _readHeaderSync(File(path)));
  }

  /// [readHeader] for the pages that list the name lists on the phone (Identify organisms, the
  /// Find screens' "Also identify them", Download & import models), kept per file while the
  /// app runs (round 379). Those pages read every list again each time they open, and with
  /// eight BioCLIP 2 lists that took 0.3 to 0.4 s per list on a Xiaomi 11T Pro. A file whose
  /// size or modification time changed (a new download under the same name) is read again.
  /// The map is shared: callers must not change it (its top level is read-only). Import and
  /// download checks call [readHeader], which always reads the file.
  static Future<Map<String, dynamic>> listingHeader(File file) async {
    final stat = await file.stat();
    final cached = _listingCache[file.path];
    if (cached != null && cached.size == stat.size && cached.modified == stat.modified) {
      return cached.header;
    }
    final header = Map<String, dynamic>.unmodifiable(await readHeader(file));
    _listingCache.remove(file.path);
    // A few dozen lists at most on a phone; the oldest entries go first (files deleted since).
    while (_listingCache.length >= 32) {
      _listingCache.remove(_listingCache.keys.first);
    }
    _listingCache[file.path] = (size: stat.size, modified: stat.modified, header: header);
    return header;
  }

  static final _listingCache = <String, ({int size, DateTime modified, Map<String, dynamic> header})>{};

  static Map<String, dynamic> _readHeaderSync(File file) {
    final map = _decodeHeaderSync(file);
    final labels = map.remove('labels'); // keep listings light
    // Round 377: what the Identify page needs of the names, the orders and families. Label
    // entries of a wrong shape are parseBytes' to report: such a pack has no taxa here.
    if (!isClassListHeader(map) && labels is List && labels.every((e) => e is List)) {
      map[kPackTaxaKey] = PackTaxa.ofHeaderLabels(labels.cast<List>());
    }
    // Round 372: the GBIF keys are one entry per name, read only by the scoring. The
    // `regions` block stays: the Identify page reads it ([PackRegions.tryParse]).
    final gbif = map['gbif'];
    if (gbif is Map) map['gbif'] = _withoutKeys(gbif, const {'species_key', 'species'});
    return map;
  }

  /// The names of [file] as rows, in the order of the file, without reading the vectors
  /// (round 378: the page that lists a name list's names, name_list_names.dart).
  /// Synchronous: call it from a helper isolate, as [readHeader] does (decoding a header of
  /// tens of thousands of names takes 0.1 s and more).
  static List<LabelRow> readLabelsSync(File file) {
    final labels = _decodeHeaderSync(file)['labels'] as List; // a list: _checkedHeader
    try {
      return [for (final e in labels) _labelRow(e as List)];
    } on TypeError catch (e) {
      throw FormatException('Label pack header has a wrong field type: $e');
    }
  }

  /// The whole JSON header of [file], checked and decoded, with the names (no vectors).
  static Map<String, dynamic> _decodeHeaderSync(File file) {
    final raf = file.openSync();
    try {
      final magic = raf.readSync(4);
      if (magic.length != 4 || String.fromCharCodes(magic) != 'FPK1') {
        throw FormatException('Not a label pack (missing FPK1 magic)');
      }
      final lenBytes = raf.readSync(4);
      if (lenBytes.length != 4) throw const FormatException('Label pack header is truncated');
      final hlen = ByteData.sublistView(lenBytes).getUint32(0, Endian.little);
      // Round 327: the header is read whole, so a hand-made one of hundreds of MB would use
      // that much memory at every listing. Real headers are a few MB (about 2 MB for the
      // 17,130 names of the mammals and birds list).
      if (hlen > kMaxLabelPackHeaderBytes) throw const FormatException('Label pack header is too large');
      // readSync returns only what is left, so a cut file must be caught here.
      final payload = raf.lengthSync() - 8 - hlen;
      if (payload < 0) throw const FormatException('Label pack header is truncated');
      return _checkedHeader(raf.readSync(hlen), payload);
    } finally {
      raf.closeSync();
    }
  }

  static Map<String, dynamic> _withoutKeys(Map block, Set<String> keys) => {
    for (final e in block.entries)
      if (e.key is String && !keys.contains(e.key)) e.key as String: e.value,
  };

  /// The header as a loaded pack keeps it (for the summary and source rows): without the
  /// names and without the per-row and per-country parts of the optional blocks, which live in
  /// typed fields; the blocks' small source notes stay.
  static Map<String, dynamic> _slimHeader(Map<String, dynamic> header) {
    final out = Map<String, dynamic>.from(header)..remove('labels');
    final gbif = out['gbif'], regions = out['regions'];
    if (gbif is Map) out['gbif'] = _withoutKeys(gbif, const {'species_key', 'species'});
    if (regions is Map) out['regions'] = _withoutKeys(regions, const {'countries', 'neighbours'});
    return out;
  }

  /// A `labels` entry as a row: seven rank names and the common name, a missing one as ''.
  static LabelRow _labelRow(List entry) {
    final l = entry.map((x) => (x ?? '').toString()).toList();
    while (l.length < 8) {
      l.add('');
    }
    return LabelRow(l.sublist(0, 7), l[7]);
  }

  /// One text per row from a list of the `gbif` block, '' for a row without a value; empty
  /// when the list is missing or not one entry per row. A key stays text: some are made of
  /// digits only, and a number written by another tool is read as its digits.
  static List<String> _perRowText(Object? list, int rows) {
    if (list is! List || list.length != rows) return const [];
    return [for (final v in list) v is String ? v : (v is int ? '$v' : '')];
  }

  /// Loads the whole pack off the UI isolate.
  static Future<LabelPack> load(File file) {
    final path = file.path;
    return Isolate.run(() => parseBytes(File(path).readAsBytesSync()));
  }

  /// Decodes the JSON header and checks the fields every reader needs. Import
  /// and the download check call only [readHeader], so it must refuse what
  /// [parseBytes] cannot load; a FormatException gives callers a plain reason.
  /// [payloadBytes] = bytes after the header (the matrix must fit in them).
  static Map<String, dynamic> _checkedHeader(List<int> hdr, int payloadBytes) {
    if (hdr.length > kMaxLabelPackHeaderBytes) throw const FormatException('Label pack header is too large');
    _checkJsonShape(hdr);
    final h = jsonDecode(utf8.decode(hdr));
    if (h is! Map<String, dynamic>) throw const FormatException('Label pack header is not a JSON object');
    final dim = h['dim'], rows = h['rows'], labels = h['labels'];
    // The dim cap (real packs: a few hundred to a few thousand) keeps rows * dim
    // from overflowing and stops a damaged header from asking for gigabytes.
    if (dim is! int || rows is! int || dim < 0 || rows < 0 || dim > 1 << 20) {
      throw FormatException('Label pack header has a wrong dim ($dim) or rows ($rows)');
    }
    if (labels is! List || labels.length != rows) {
      throw FormatException('Label pack has ${labels is List ? labels.length : 'no'} labels for $rows rows');
    }
    if (!isClassListHeader(h) && payloadBytes < rows * dim * (h['dtype'] == 'f32' ? 4 : 2)) {
      throw const FormatException('Label pack matrix is truncated');
    }
    return h;
  }

  /// Parses pack [bytes] (synchronous; used by tests and by [load]).
  /// Any wrong field type in a damaged or hand-made header becomes a
  /// FormatException, the one error type callers expect from a bad file.
  static LabelPack parseBytes(Uint8List bytes) {
    try {
      return _parseBytes(bytes);
    } on TypeError catch (e) {
      throw FormatException('Label pack header has a wrong field type: $e');
    } on ArgumentError catch (e) {
      throw FormatException('Label pack is damaged: $e'); // includes RangeError
    } on UnsupportedError catch (e) {
      throw FormatException('Label pack header has a wrong number: $e'); // e.g. 1e999.toInt()
    }
  }

  static LabelPack _parseBytes(Uint8List bytes) {
    if (bytes.length < 8 || String.fromCharCodes(bytes.sublist(0, 4)) != 'FPK1') {
      throw const FormatException('Not a label pack (missing FPK1 magic)');
    }
    final hlen = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
    final headerEnd = 8 + hlen;
    if (headerEnd > bytes.length) {
      throw const FormatException('Label pack header is truncated');
    }
    final header = _checkedHeader(bytes.sublist(8, headerEnd), bytes.length - headerEnd);
    final dim = header['dim'] as int;
    final rows = header['rows'] as int;
    final dtype = (header['dtype'] as String?) ?? 'f16';
    final rawLabels = header['labels'] as List;
    final labels = [for (final e in rawLabels) _labelRow(e as List)];
    if (isClassListHeader(header)) {
      return _classList(header, labels, dim, rows);
    }
    final n = rows * dim; // _checkedHeader made sure the file holds n numbers
    final matrix = Float32List(n);
    final bytesPer = dtype == 'f32' ? 4 : 2;
    final data = ByteData.sublistView(bytes, headerEnd, headerEnd + n * bytesPer);
    if (dtype == 'f32') {
      for (var i = 0; i < n; i++) {
        matrix[i] = data.getFloat32(i * 4, Endian.little);
      }
    } else {
      for (var i = 0; i < n; i++) {
        matrix[i] = halfToFloat(data.getUint16(i * 2, Endian.little));
      }
    }
    final gbif = header['gbif'];
    final keys = _perRowText(gbif is Map ? gbif['species_key'] : null, rows);
    final species = _perRowText(gbif is Map ? gbif['species'] : null, rows);
    return LabelPack(
      packId: (header['pack_id'] as String?) ?? 'pack',
      modelId: (header['model_id'] as String?) ?? '',
      dim: dim,
      rows: rows,
      sinkRows: (header['sink_rows'] as num?)?.toInt() ?? 0,
      logitScale: (header['logit_scale'] as num?)?.toDouble() ?? 100.0,
      temperature: (header['temperature'] as num?)?.toDouble() ?? 1.0,
      labels: labels,
      matrix: matrix,
      header: _slimHeader(header),
      // Keys without names (or the reverse) are a damaged block: the pack then has neither.
      gbifKeys: species.isEmpty ? const [] : keys,
      gbifSpecies: keys.isEmpty ? const [] : species,
      regions: PackRegions.tryParse(header['regions'], rows),
    );
  }

  static LabelPack _classList(Map<String, dynamic> header, List<LabelRow> labels, int dim, int rows) {
    final heads = (header['heads'] as List).cast<Map>();
    final sizes = [for (final h in heads) (h['size'] as num).toInt()];
    if (sizes.fold<int>(0, (a, b) => a + b) != dim) {
      throw FormatException('Class list heads add up to ${sizes.fold<int>(0, (a, b) => a + b)}, not $dim');
    }
    final rawIndex = header['head_index'] as List;
    final names = [for (final c in header['classes'] as List) '$c'];
    if (rawIndex.length != rows || names.length != rows) {
      throw FormatException('Class list needs one class name and one head index per row ($rows rows)');
    }
    final index = Int32List(rows * sizes.length);
    for (var r = 0; r < rows; r++) {
      final idx = rawIndex[r] as List;
      for (var h = 0; h < sizes.length; h++) {
        final i = (idx[h] as num).toInt();
        if (i < 0 || i >= sizes[h]) throw FormatException('Class list row $r: index $i outside head $h');
        index[r * sizes.length + h] = i;
      }
    }
    return LabelPack(
      packId: (header['pack_id'] as String?) ?? 'classes',
      modelId: (header['model_id'] as String?) ?? '',
      dim: dim,
      rows: rows,
      sinkRows: (header['sink_rows'] as num?)?.toInt() ?? 0,
      logitScale: (header['logit_scale'] as num?)?.toDouble() ?? 1.0,
      temperature: (header['temperature'] as num?)?.toDouble() ?? 1.0,
      labels: labels,
      matrix: Float32List(0),
      header: Map<String, dynamic>.from(header)..remove('labels'),
      headSizes: sizes,
      headIndex: index,
      classNames: names,
    );
  }
}

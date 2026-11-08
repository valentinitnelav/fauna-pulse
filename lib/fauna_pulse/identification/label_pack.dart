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

  /// Reads only the JSON header of [file] (cheap: no matrix), for listings.
  static Future<Map<String, dynamic>> readHeader(File file) async {
    final raf = await file.open();
    try {
      final magic = await raf.read(4);
      if (magic.length != 4 || String.fromCharCodes(magic) != 'FPK1') {
        throw FormatException('Not a label pack (missing FPK1 magic)');
      }
      final lenBytes = await raf.read(4);
      if (lenBytes.length != 4) throw const FormatException('Label pack header is truncated');
      final hlen = ByteData.sublistView(lenBytes).getUint32(0, Endian.little);
      // Round 327: read whole on the screen's thread (each listing reads it again), so a
      // hand-made header of hundreds of MB would freeze the app. Real headers are a few MB (about
      // 2 MB for the 17,130 names of the mammals and birds list).
      if (hlen > kMaxLabelPackHeaderBytes) throw const FormatException('Label pack header is too large');
      // raf.read returns only what is left, so a cut file must be caught here.
      final payload = await raf.length() - 8 - hlen;
      if (payload < 0) throw const FormatException('Label pack header is truncated');
      final map = _checkedHeader(await raf.read(hlen), payload);
      map.remove('labels'); // keep listings light
      return map;
    } finally {
      await raf.close();
    }
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
    final labels = <LabelRow>[];
    for (final e in rawLabels) {
      final l = (e as List).map((x) => (x ?? '').toString()).toList();
      while (l.length < 8) {
        l.add('');
      }
      labels.add(LabelRow(l.sublist(0, 7), l[7]));
    }
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
      header: Map<String, dynamic>.from(header)..remove('labels'),
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

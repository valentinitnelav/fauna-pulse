// FaunaPulse (round 208): label packs for on-device identification.
//
// A "label pack" is one file holding, for every candidate name the model may
// choose from, its text embedding (a unit-length vector produced once on a PC
// by tool/bioclip_export/build_label_pack.py from the TreeOfLife-200M name
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
// The Python writer (fpack.py) and this reader are tested against one fixture.

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

/// Kingdom value marking a "none of these" sink row.
const String kSinkKingdom = 'none';

/// One candidate: seven rank names (species = epithet only) + common name.
class LabelRow {
  final List<String> ranks;
  final String common;

  const LabelRow(this.ranks, this.common);

  bool get isSink => ranks.isNotEmpty && ranks[0] == kSinkKingdom;

  /// "Genus epithet" for species rows; the sink key for sink rows.
  String get speciesName =>
      isSink ? ranks[6] : '${ranks[5]} ${ranks[6]}'.trim();

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

  const LabelPack({
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
  });

  /// Dot product of the unit vector [e] (length [dim]) with pack row [row].
  double dot(Float32List e, int row) {
    final base = row * dim;
    var s = 0.0;
    for (var i = 0; i < dim; i++) {
      s += e[i] * matrix[base + i];
    }
    return s;
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
      final hlen = ByteData.sublistView(lenBytes).getUint32(0, Endian.little);
      final hdr = await raf.read(hlen);
      final map = jsonDecode(utf8.decode(hdr)) as Map<String, dynamic>;
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

  /// Parses pack [bytes] (synchronous; used by tests and by [load]).
  static LabelPack parseBytes(Uint8List bytes) {
    if (bytes.length < 8 || String.fromCharCodes(bytes.sublist(0, 4)) != 'FPK1') {
      throw const FormatException('Not a label pack (missing FPK1 magic)');
    }
    final hlen = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
    final headerEnd = 8 + hlen;
    if (headerEnd > bytes.length) {
      throw const FormatException('Label pack header is truncated');
    }
    final header =
        jsonDecode(utf8.decode(bytes.sublist(8, headerEnd))) as Map<String, dynamic>;
    final dim = (header['dim'] as num).toInt();
    final rows = (header['rows'] as num).toInt();
    final dtype = (header['dtype'] as String?) ?? 'f16';
    final rawLabels = header['labels'] as List;
    if (rawLabels.length != rows) {
      throw FormatException('Label pack has ${rawLabels.length} labels for $rows rows');
    }
    final labels = <LabelRow>[];
    for (final e in rawLabels) {
      final l = (e as List).map((x) => (x ?? '').toString()).toList();
      while (l.length < 8) {
        l.add('');
      }
      labels.add(LabelRow(l.sublist(0, 7), l[7]));
    }
    final n = rows * dim;
    final matrix = Float32List(n);
    final bytesPer = dtype == 'f32' ? 4 : 2;
    if (bytes.length < headerEnd + n * bytesPer) {
      throw const FormatException('Label pack matrix is truncated');
    }
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
}

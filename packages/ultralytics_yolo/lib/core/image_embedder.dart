// FaunaPulse (round 208): Dart side of the identification embedder.
//
// Loads a TFLite image-embedding model (the BioCLIP image tower exported by
// tool/bioclip_export/export_image_tower.py) in the native plugin and embeds
// batches of pre-cropped RGB images. One embedder is loaded at a time; every
// call is awaited by the caller, so the native single-thread executor never
// sees overlapping work. See Embedder.kt for the native counterpart.

import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../config/channel_config.dart';

/// What the native side reports after loading an embedding model.
class ImageEmbedderInfo {
  /// "GPU" or "CPU" (the LiteRT ladder's choice after any fallback).
  final String accelerator;

  /// Why the GPU was not used although requested (compile error text or
  /// "blocklisted"); null on GPU or when the GPU was not requested.
  final String? accelerationNote;
  final int inputWidth;
  final int inputHeight;

  /// Embedding length (e.g. 768 for BioCLIP 2, 1024 for BioCLIP 2.5).
  final int dim;
  final double loadMs;

  const ImageEmbedderInfo({
    required this.accelerator,
    this.accelerationNote,
    required this.inputWidth,
    required this.inputHeight,
    required this.dim,
    required this.loadMs,
  });
}

/// A batch result: [count] unit-length vectors of [dim] floats, flattened
/// row-major in [vectors], plus the native inference time for the batch.
class ImageEmbedderBatch {
  final int dim;
  final int count;
  final Float32List vectors;
  final double ms;

  const ImageEmbedderBatch({
    required this.dim,
    required this.count,
    required this.vectors,
    required this.ms,
  });

  /// Vector [i] as its own list (a view, no copy).
  Float32List vector(int i) => Float32List.sublistView(vectors, i * dim, (i + 1) * dim);
}

class ImageEmbedder {
  static final MethodChannel _channel = ChannelConfig.createSingleImageChannel();

  /// Loads [modelPath] (absolute file path) natively, replacing any embedder
  /// loaded before. Throws a [PlatformException] with the native message when
  /// the model cannot be compiled on either accelerator.
  static Future<ImageEmbedderInfo> load(
    String modelPath, {
    bool useGpu = true,
    int cpuThreads = 0,
  }) async {
    final r = await _channel.invokeMethod<Map>('embedderLoad', {
      'modelPath': modelPath,
      'useGpu': useGpu,
      'cpuThreads': cpuThreads,
    });
    if (r == null) throw StateError('embedderLoad returned nothing');
    return ImageEmbedderInfo(
      accelerator: (r['accelerator'] as String?) ?? '?',
      accelerationNote: r['accelerationNote'] as String?,
      inputWidth: (r['inputWidth'] as num).toInt(),
      inputHeight: (r['inputHeight'] as num).toInt(),
      dim: (r['dim'] as num).toInt(),
      loadMs: (r['loadMs'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Embeds [rgbImages], each exactly inputWidth × inputHeight × 3 bytes of
  /// interleaved RGB (row-major), in one native call.
  static Future<ImageEmbedderBatch> embed(List<Uint8List> rgbImages) async {
    final r = await _channel.invokeMethod<Map>('embedderRun', {
      'images': rgbImages,
    });
    if (r == null) throw StateError('embedderRun returned nothing');
    final raw = r['vectors'];
    final vectors = raw is Float32List
        ? raw
        : Float32List.fromList([for (final v in (raw as List)) (v as num).toDouble()]);
    return ImageEmbedderBatch(
      dim: (r['dim'] as num).toInt(),
      count: (r['count'] as num).toInt(),
      vectors: vectors,
      ms: (r['ms'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Releases the native model (safe to call when none is loaded).
  static Future<void> close() => _channel.invokeMethod<void>('embedderClose');
}

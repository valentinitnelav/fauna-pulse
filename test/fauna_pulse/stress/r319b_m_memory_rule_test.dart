// Round 319, part 2: the free-memory rule for "Also identify them" in the background, checked
// against the numbers of the phone tests on the 3.6 GB Redmi (PB2/meminfo.csv, PA2/log.md).
// MemAvailable values in kB as logged; the threshold is not in the logs (226 MB is a usual
// value for a phone of this size), and availMem is set higher than MemAvailable, as Android
// counts all cached pages as free.

import 'package:fauna_pulse/fauna_pulse/identification/identification_run.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

const _kb = 1024;
const _mb = 1024 * 1024;

/// BioCLIP 2 fp16 (0.61 GB) on the CPU: 2.15 x the file (Embedder.CPU_MEMORY_FACTOR).
const _bioclip = 609000000;

/// insectDCT eff2s (41.8 MB).
const _insectDct = 41800000;

ImageEmbedderMemory _m({required int fileBytes, required int memAvailableKb, int? availMemKb, double factor = 2.15}) =>
    ImageEmbedderMemory(
      fileBytes: fileBytes,
      needBytes: (fileBytes * factor).round(),
      onGpu: factor > 3,
      availMem: (availMemKb ?? memAvailableKb + 300000) * _kb,
      threshold: 226 * _mb,
      totalMem: 3800000000,
      lowMemory: false,
      memAvailable: memAvailableKb * _kb,
    );

void main() {
  test('BioCLIP 2 on the CPU does not fit at the hand-overs where Android ended the app', () {
    // PB2 step b, 11:15:12 (killed at 11:15:18) and step b2, 11:59:20 (killed at 11:59:25).
    expect(identifyFitsInBackground(_m(fileBytes: _bioclip, memAvailableKb: 1083708)), isFalse);
    expect(identifyFitsInBackground(_m(fileBytes: _bioclip, memAvailableKb: 941312)), isFalse);
    // The foreground start of PB2 step a (11:21:21) would wait too (it ran because the app was
    // in front, where Android closes other apps first).
    expect(identifyFitsInBackground(_m(fileBytes: _bioclip, memAvailableKb: 1149980)), isFalse);
  });

  test('a small model fits on the same phone at the same moment', () {
    expect(identifyFitsInBackground(_m(fileBytes: _insectDct, memAvailableKb: 941312)), isTrue);
  });

  test('BioCLIP 2 fits on a phone with plenty free', () {
    expect(identifyFitsInBackground(_m(fileBytes: _bioclip, memAvailableKb: 3500000)), isTrue);
    // GPU guard's estimate (4.5 x the file) on such a phone: 2.7 GB needed, 3.4 GB free.
    expect(identifyFitsInBackground(_m(fileBytes: _bioclip, memAvailableKb: 3400000, factor: 4.5)), isTrue);
    expect(identifyFitsInBackground(_m(fileBytes: _bioclip, memAvailableKb: 2800000, factor: 4.5)), isFalse);
  });

  test('the margin: what must be left free after the load', () {
    final need = (_bioclip * 2.15).round();
    final atLimit = (need + 226 * _mb + kIdentifyMemoryMarginBytes) ~/ _kb;
    expect(identifyFitsInBackground(_m(fileBytes: _bioclip, memAvailableKb: atLimit + 1)), isTrue);
    expect(identifyFitsInBackground(_m(fileBytes: _bioclip, memAvailableKb: atLimit - 1)), isFalse);
    // 326 MB left free: more than the 190 to 330 MB the foreground-started run had in the background.
    expect((226 * _mb + kIdentifyMemoryMarginBytes) ~/ _mb, 326);
  });

  test('the smaller of availMem and MemAvailable counts; MemAvailable unknown: availMem', () {
    final both = _m(fileBytes: _bioclip, memAvailableKb: 3500000, availMemKb: 1000000);
    expect(identifyFreeBytes(both), 1000000 * _kb);
    expect(identifyFitsInBackground(both), isFalse);
    const unknown = ImageEmbedderMemory(
      fileBytes: _bioclip,
      needBytes: 1309350000,
      onGpu: false,
      availMem: 3000000000,
      threshold: 226 * _mb,
      totalMem: 7400000000,
      lowMemory: false,
      memAvailable: -1,
    );
    expect(identifyFreeBytes(unknown), 3000000000);
    expect(identifyFitsInBackground(unknown), isTrue);
  });
}

package com.ultralytics.yolo

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class VideoFrameSourceTest {
  private fun taken(sampler: PtsSampler, pts: List<Long>) = pts.filter { sampler.take(it) }

  @Test
  fun samplerHalvesA30FpsClipTo15() {
    val pts = (0 until 30).map { it * 33_333L }
    val got = taken(PtsSampler(66_667L, 0L), pts)
    assertEquals(15, got.size)
    assertEquals(pts.filterIndexed { i, _ -> i % 2 == 0 }, got)
  }

  @Test
  fun samplerToleratesJitterAndRestartsAfterAGap() {
    // 1 fps target; frame at 0.95 s is within 1/10 tolerance, then a 5 s gap restarts the grid.
    val got = taken(PtsSampler(1_000_000L, 0L), listOf(0L, 500_000L, 950_000L, 1_500_000L, 7_000_000L, 7_500_000L, 8_000_000L))
    assertEquals(listOf(0L, 950_000L, 7_000_000L, 8_000_000L), got)
  }

  @Test
  fun samplerEveryFrameModeSkipsOnlyRepeatsAndResumesAfterStart() {
    assertEquals(listOf(0L, 10L, 20L), taken(PtsSampler(0L, 0L), listOf(0L, 0L, 10L, 20L)))
    // Resume: frames decoded from the previous key frame but before the start are dropped.
    assertEquals(listOf(200_000L, 266_666L), taken(PtsSampler(66_667L, 200_000L), listOf(100_000L, 133_333L, 166_666L, 200_000L, 233_333L, 266_666L)))
  }

  @Test
  fun mp4DateParsesUtcAndRejectsUnsetValues() {
    assertEquals(1_790_244_900_000L, VideoFrameSource.parseMp4Date("20260924T101500.000Z"))
    assertEquals(1_790_244_900_000L, VideoFrameSource.parseMp4Date("20260924T101500Z"))
    assertNull(VideoFrameSource.parseMp4Date("19040101T000000.000Z"))
    assertNull(VideoFrameSource.parseMp4Date(null))
    assertNull(VideoFrameSource.parseMp4Date("garbage"))
  }
}

package com.ultralytics.yolo

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

// Round 319, part 3: on the Android 12 test phone the first mallopt option answered "done" but
// the app's resident memory stayed at 1553 MB; the give-back must then try the next option.
class NativeMemoryTest {
  /** A fake phone: [rss] MB resident; each step answers [answers] and frees [frees] MB. */
  private class Phone(var rss: Long, val answers: List<Int>, val frees: List<Long>) {
    val ran = mutableListOf<String>()
    fun steps() = listOf("purge all", "purge", "decay 0 + purge").mapIndexed { i, name ->
      name to { ran += name; rss -= frees[i]; answers[i] }
    }
  }

  @Test
  fun acceptedStepThatFreesNothingIsFollowedByTheNext() {
    // Redmi, Android 12: "purge all" says done but frees nothing; "purge" frees 1.07 GB.
    val phone = Phone(1553, listOf(1, 1, 1), listOf(1, 1070, 0))
    val tried = NativeMemory.tryInOrder(phone.steps(), { phone.rss }, enoughMb = 32)
    assertEquals(listOf("purge all", "purge"), phone.ran)
    assertEquals(NativeMemory.Attempt("purge", 1, 1552, 482), tried.last())
  }

  @Test
  fun firstStepThatFreesMemoryIsTheLast() {
    // 11T Pro, Android 14: "purge all" frees 1.2 GB at once.
    val phone = Phone(1687, listOf(1, 1, 1), listOf(1216, 0, 0))
    NativeMemory.tryInOrder(phone.steps(), { phone.rss }, enoughMb = 32)
    assertEquals(listOf("purge all"), phone.ran)
  }

  @Test
  fun unknownOptionsArePassedOver() {
    // Stock Android 12/13: "purge all" is unknown (0); Android 8 has no M_PURGE either.
    val phone = Phone(1500, listOf(0, 1, 1), listOf(0, 1000, 0))
    NativeMemory.tryInOrder(phone.steps(), { phone.rss }, enoughMb = 32)
    assertEquals(listOf("purge all", "purge"), phone.ran)
    val old = Phone(800, listOf(0, 0, 0), listOf(0, 0, 0))
    NativeMemory.tryInOrder(old.steps(), { old.rss }, enoughMb = 32)
    assertEquals(3, old.ran.size)
  }

  @Test
  fun littleToGiveBackOrUnknownRssStopsAtTheFirstAcceptedStep() {
    val small = Phone(512, listOf(1, 1, 1), listOf(0, 0, 0))
    NativeMemory.tryInOrder(small.steps(), { small.rss }, enoughMb = 0)
    assertEquals(listOf("purge all"), small.ran)
    val blind = Phone(1500, listOf(1, 1, 1), listOf(0, 0, 0))
    NativeMemory.tryInOrder(blind.steps(), { -1L }, enoughMb = 32)
    assertEquals(listOf("purge all"), blind.ran)
  }
}

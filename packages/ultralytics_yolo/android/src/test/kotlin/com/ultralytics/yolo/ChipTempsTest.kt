package com.ultralytics.yolo

import java.io.File
import java.nio.file.Files
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

// The unit of a thermal zone is decided once, not for every reading: the old per-reading guess
// turned a chip below 1 °C into a false hot value and dropped frost.
class ChipTempsTest {
  /** A fake /sys/class/thermal: zone number i has the name and first reading of [zones]`[i]`. */
  private fun thermalDir(vararg zones: Pair<String, String>): File {
    val dir = Files.createTempDirectory("thermal").toFile()
    zones.forEachIndexed { i, (type, temp) ->
      val z = File(dir, "thermal_zone$i").apply { mkdirs() }
      File(z, "type").writeText("$type\n")
      File(z, "temp").writeText("$temp\n")
    }
    return dir
  }

  private fun File.set(zone: Int, temp: String) = File(this, "thermal_zone$zone/temp").writeText("$temp\n")

  @Test
  fun unitComesFromTheFirstReading() {
    assertEquals(1000.0, ChipTemps.divisor(37000.0))
    assertEquals(10.0, ChipTemps.divisor(370.0))
    assertEquals(1.0, ChipTemps.divisor(37.0))
    assertEquals(1000.0, ChipTemps.divisor(-5000.0))
    // Unreadable or 0 at the start: the kernel's rule, thousandths.
    assertEquals(1000.0, ChipTemps.divisor(null))
    assertEquals(1000.0, ChipTemps.divisor(0.0))
  }

  @Test
  fun absentSensorsAndNonsenseAreDropped() {
    assertNull(ChipTemps.celsius(-40000.0, 1000.0))
    assertNull(ChipTemps.celsius(150000.0, 1000.0))
    assertNull(ChipTemps.celsius(null, 1000.0))
    assertEquals(37.5, ChipTemps.celsius(37456.0, 1000.0))
  }

  @Test
  fun coldChipStaysColdAndFrostIsKept() {
    val dir = thermalDir("cpu-0-0-usr" to "41000", "gpuss-0-usr" to "36000", "battery" to "30000")
    val chip = ChipTemps(dir)
    assertEquals(41.0, chip.cpuC())
    assertEquals(36.0, chip.gpuC())
    // 0.5 °C in thousandths: the per-reading guess made 50 °C of it.
    dir.set(0, "500")
    assertEquals(0.5, chip.cpuC())
    dir.set(0, "-5000")
    dir.set(1, "0")
    assertEquals(-5.0, chip.cpuC())
    assertEquals(0.0, chip.gpuC())
  }

  @Test
  fun tenthsZoneStaysInTenthsWhenCool() {
    val dir = thermalDir("mtktscpu" to "412", "G3D" to "38")
    val chip = ChipTemps(dir)
    assertEquals(41.2, chip.cpuC())
    assertEquals(38.0, chip.gpuC())
    // 12 °C in tenths: the per-reading guess made 120 °C of it.
    dir.set(0, "120")
    assertEquals(12.0, chip.cpuC())
  }

  @Test
  fun hottestReadableZoneWinsAndNoneGivesNull() {
    val dir = thermalDir("cpu-0-0-usr" to "41000", "cpu-0-1-usr" to "55300", "cpu-1-0-usr" to "-40000")
    val chip = ChipTemps(dir)
    assertEquals(55.3, chip.cpuC())
    assertNull(chip.gpuC())
    // A phone that does not let apps list the folder (Samsung Galaxy M12).
    val none = ChipTemps(File(dir, "missing"))
    assertNull(none.cpuC())
    assertNull(none.gpuC())
  }
}

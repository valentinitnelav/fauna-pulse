// FaunaPulse: chip temperatures (hottest CPU core sensor, hottest GPU sensor) from the kernel's
// thermal zones: folders /sys/class/thermal/thermal_zone*, each with a `type` name and a `temp`
// reading. Whether an app may read them is the phone maker's choice (Xiaomi phones yes, the
// Samsung Galaxy M12 no): both values are null then.
//
// The unit rule is the same as in the sister app FaunaLapse (its ChipTemps.java), so both apps'
// `cpu_temp_c` and `gpu_temp_c` mean the same: keep the two in sync. This file sits in the plugin
// only because the plugin has the Kotlin unit tests (ChipTempsTest).

package com.ultralytics.yolo

import java.io.File

class ChipTemps(thermalDir: File = File("/sys/class/thermal")) {

    /** A zone's `temp` file and the number that turns its reading into °C. */
    private class Zone(val temp: File) {
        val divisor = divisor(number(temp))
    }

    private val cpu = mutableListOf<Zone>()
    private val gpu = mutableListOf<Zone>()

    // The zones whose name says CPU or GPU, found once (the list does not change while the app
    // runs). Qualcomm names them cpu-0-0-usr, cpuss-0-usr, gpuss-0-step and so on; MediaTek
    // mtktscpu; Exynos calls the GPU G3D.
    init {
        val zones = thermalDir.listFiles { f -> f.name.startsWith("thermal_zone") }
        for (z in zones ?: emptyArray()) {
            val type = runCatching { File(z, "type").readText().trim().lowercase() }.getOrNull() ?: continue
            when {
                type.contains("cpu") -> cpu += Zone(File(z, "temp"))
                type.contains("gpu") || type.contains("g3d") -> gpu += Zone(File(z, "temp"))
            }
        }
    }

    /** Hottest CPU core sensor in °C; null when none is readable. */
    fun cpuC(): Double? = hottest(cpu)

    /** Hottest GPU sensor in °C; null when none is readable. */
    fun gpuC(): Double? = hottest(gpu)

    private fun hottest(zones: List<Zone>): Double? =
        zones.mapNotNull { celsius(number(it.temp), it.divisor) }.maxOrNull()

    companion object {
        /** The unit of a zone, decided once from its first reading. The kernel's rule is
         *  thousandths of a degree (37000 = 37 °C; Documentation/ABI/testing/sysfs-class-thermal);
         *  a few old drivers give tenths or whole degrees. Deciding it for every reading was
         *  wrong in the cold: a chip below 1 °C reads 0 to 999 in thousandths, which looked like
         *  tenths or degrees (500 = 0.5 °C became 50 °C). Known limit: a zone whose first reading
         *  is already below 1 °C (not 0) is still taken for tenths or degrees until the app
         *  starts again on a warmer chip. */
        fun divisor(firstRaw: Double?): Double {
            if (firstRaw == null || firstRaw == 0.0) return 1000.0
            val a = Math.abs(firstRaw)
            return if (a >= 1000) 1000.0 else if (a >= 200) 10.0 else 1.0
        }

        /** A reading in °C (one decimal), or null when it is none: -40 °C or lower means that
         *  the sensor is absent, 150 °C or more that it is no temperature. Frost is kept. */
        fun celsius(raw: Double?, divisor: Double): Double? {
            val c = (raw ?: return null) / divisor
            return if (c > -40 && c < 150) Math.round(c * 10) / 10.0 else null
        }

        private fun number(temp: File): Double? =
            runCatching { temp.readText().trim().toDouble() }.getOrNull()
    }
}

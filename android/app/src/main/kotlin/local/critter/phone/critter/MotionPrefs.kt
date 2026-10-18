package local.critter.phone.critter

/** The phone-wide "reduce motion" switch from the settings; the system's "remove animations" counts as well. */
object MotionPrefs {
    @Volatile var manual = false
}

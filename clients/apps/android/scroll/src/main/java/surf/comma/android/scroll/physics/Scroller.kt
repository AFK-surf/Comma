/*
 * Copyright (C) 2023 Helixform
 * Modified by the comma authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package surf.comma.android.scroll.physics

import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.pow

class Scroller(private val decelerateRate: Float = ScrollPhysicsConfig.DECELERATION_RATE_NORMAL) {
    data class ScrollValue(
        val value: Float,
        val velocity: Float,
        val isFinished: Boolean
    )

    private var startValue: Float = 0f
    private var initialVelocity: Float = 0f

    private val threshold = ScrollPhysicsConfig.FLING_VELOCITY_THRESHOLD

    fun fling(startValue: Float, velocity: Float) {
        this.startValue = startValue
        initialVelocity = velocity
    }

    fun value(time: Float): ScrollValue {
        val velocity = velocityAt(time)
        return ScrollValue(offsetAt(time), velocity, abs(velocity) < threshold)
    }

    fun finalOffset(): Float {
        // A scroll won't happen when the velocity is below the threshold.
        // Meanwhile, Avoiding division by zero.
        if (abs(initialVelocity) < threshold) {
            return 0f
        }
        val t = ln(threshold / abs(initialVelocity)) / ln(decelerateRate)
        return offsetAt(t)
    }

    private fun velocityAt(time: Float): Float {
        return initialVelocity * decelerateRate.pow(time)
    }

    private fun offsetAt(time: Float): Float {
        return startValue + initialVelocity * (1f / ln(decelerateRate)) * (decelerateRate.pow(time) - 1f)
    }
}
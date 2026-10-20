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

class RubberBand {
    companion object {
        fun offset(distance: Float, range: Float): Float {
            // Check if offset and range are positive.
            if (distance < 0f || range <= 0f) {
                return 0f
            }
            // The calculated offset of  always stays within the range.
            return (1f - (1f / (distance / range * ScrollPhysicsConfig.RUBBER_BAND_COEFFICIENT + 1f))) * range
        }

        fun distance(offset: Float, range: Float): Float {
            if (offset < 0f || range <= 0f) {
                return 0f
            }
            // The offset cannot be greater than or equal to the range.
            // We subtract a very small value to ensure that the offset does not out of range.
            val clampedOffset = offset.coerceAtMost(range - ScrollPhysicsConfig.RUBBER_BAND_RANGE_EPSILON)
            return (range * clampedOffset / (range - clampedOffset)) / ScrollPhysicsConfig.RUBBER_BAND_COEFFICIENT
        }
    }
}
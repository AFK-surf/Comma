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

/** Shared coefficients for scrolling, overscroll, and spring-back. */
object ScrollPhysicsConfig {
    const val RUBBER_BAND_COEFFICIENT = 0.55f
    const val RUBBER_BAND_RANGE_EPSILON = 0.00001f
    const val DECELERATION_RATE_NORMAL = 0.998f
    const val FLING_VELOCITY_THRESHOLD = 1e-2f
    const val SPRING_PERIOD_SECONDS = 0.575f
    const val SPRING_VALUE_THRESHOLD = 0.1f
    const val SPRING_VELOCITY_THRESHOLD = 1e-2f
    const val RELEASE_VELOCITY_DIVISOR = 100f
}

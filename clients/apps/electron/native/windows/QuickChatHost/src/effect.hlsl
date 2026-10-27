// NameDrop's connection effect: the macOS QuickChatHost's NameDropEffect.swift, which builds it from Core Animation
// layers, private filters and mesh transforms, as one pixel shader (as the Electron overlay's WebGL one was).
//
//   the screen (lifted, refracted and blurred) · the ridge's band of blur and color fringes · the dim ·
//   the bloom (plus) · the rainbow arc (color dodge) · the dark arc (multiply) · the ridge glow and sheen (plus) ·
//   the hint's glows (plus)
//
// Positions are in device pixels from the overlay's bottom left (y up). The screen texture holds the display's capture,
// sRGB-encoded with its SDR white as 1.0, with mips for the blur.

Texture2D<float4> screen : register(t0);
SamplerState linearClamp : register(s0);

cbuffer Values : register(b0) {
    float2 uSize;
    float uHasScreen;
    float uMaxLod;
    float3 uStage;       // left, width, height of the package's canvas, px; its bottom on the screen's bottom
    float uLift;
    float uBlur;
    float uBackdrop;
    float uShocking;
    float uDim;
    float4 uShock;
    float3 uBand;
    float uRainbowBlur;
    float4 uCircle;
    float4 uRainbow;
    float4 uDarkArc;
    float3 uRidgeGlow;
    float pad0;
    float3 uShockSheen;
    float pad1;
    float4 uHint;
    float2 uHintMove;    // the hint sheen's y and the hint's translation, px
    float2 pad2;
};

static const float REACH_ACROSS = 1.36;
static const float REACH_UP = 0.63;
static const float BLUR_TUNING = 1.1;
static const float MESH_TUNING = 0.3;
static const float REFRACTION_TUNING = 1.0;
static const float RECOIL_TUNING = 1.0;

float4 vs(uint id : SV_VertexID) : SV_Position {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}

float sq(float x) { return x * x; }
float sstep(float a, float b, float x) { float t = saturate((x - a) / (b - a)); return t * t * (3.0 - 2.0 * t); }
float scaleUnit() { return uStage.y / 1179.0; }
// A canvas point (y down from the canvas top) in px.
float2 canvasPoint(float2 p) { return float2(uStage.x + p.x * scaleUnit(), (2556.0 - p.y) * scaleUnit()); }
// Phone units: x -1…1 across the canvas, y 0…1 up it.
float2 phone(float2 px) { return float2((px.x - (uStage.x + uStage.y * 0.5)) / (uStage.y * 0.5), px.y / uStage.z); }
// All of the effect across the middle of the canvas, easing out past its sides where the phone would end.
float strengthAcross(float x) { return 1.0 - sstep(0.25, 1.3, abs(x)); }

// The screen at a point (px, y up), at a mip level.
float3 screenLod(float2 px, float lod) {
    return screen.SampleLevel(linearClamp, float2(px.x / uSize.x, 1.0 - px.y / uSize.y), lod).rgb;
}

// The hint's stretch up: the bottom 1243.55 units are sampled from above, magnified, more at the very bottom.
float liftAt(float y, float stretch) {
    float span = 1243.55 / 2556.0;
    float depth = saturate((span - y) / span);
    float ratio = 0.25 + 0.09 * sstep(0.75, 1.0, depth);
    return depth * ratio * span * stretch;
}

// How far to sample, in canvas widths (x) and heights (y): the lift, then the ridge refracting upward and the recoil.
float2 displacement(float2 q) {
    float strength = strengthAcross(q.x);
    if (uShocking < 0.5) return float2(0.0, liftAt(q.y, uLift) * strength);
    float across = clamp(q.x, -1.0, 1.0);
    float curve = abs(across);
    float2 normal = normalize(float2(-0.09 * across, 1.0));
    float meshDistance = q.y - (uShock.x + 0.045 * curve * curve);
    float meshQ = meshDistance / 0.090;
    float meshDerivative = -2.0 * meshQ * exp(-meshQ * meshQ);
    float meshBody = exp(-sq(meshDistance / 0.17));
    float recoilQ = (q.y - (uShock.z + 0.030 * curve * curve)) / 0.085;
    float recoilDerivative = -2.0 * recoilQ * exp(-recoilQ * recoilQ);
    float lens = meshDerivative * 0.010 * REFRACTION_TUNING * uShock.y
        + meshBody * 0.0035 * MESH_TUNING * uShock.y
        + recoilDerivative * 0.0035 * RECOIL_TUNING * uShock.w;
    float dx = normal.x * lens - 0.10 * across * curve * meshBody * MESH_TUNING * uShock.y;
    return float2(dx, normal.y * lens + liftAt(q.y, uLift)) * strength;
}

// The screen at px, blurred by σ px: a ring of taps at the mip level that already averages most of it.
float3 screenAt(float2 px, float sigma) {
    if (sigma < 0.5) return screenLod(px, 0.0);
    float lod = clamp(log2(sigma / 1.5), 0.0, uMaxLod);
    float3 sum = screenLod(px, lod) * 0.2;
    float r = sigma * 1.1;
    [unroll] for (int i = 0; i < 8; i++) {
        float a = 6.2831853 * (float(i) + 0.5) / 8.0;
        sum += screenLod(px + float2(cos(a), sin(a)) * r, lod) * 0.1;
    }
    return sum;
}

// The package's glows fall to 0.4 at 0.4 of their half-width.
float glowAlpha(float2 px, float2 center, float2 size) {
    float r = length((px - center) / (size * 0.5));
    return exp(-(r * r) / (2.0 * 0.295 * 0.295));
}

float3 stops9(float t, float3 c0, float3 c1, float3 c2, float3 c3, float3 c4, float3 c5, float3 c6, float3 c7, float3 c8) {
    t = saturate(t);
    if (t < 0.2) return lerp(c0, c1, t / 0.2);
    if (t < 0.3) return lerp(c1, c2, (t - 0.2) / 0.1);
    if (t < 0.4) return lerp(c2, c3, (t - 0.3) / 0.1);
    if (t < 0.5) return lerp(c3, c4, (t - 0.4) / 0.1);
    if (t < 0.6) return lerp(c4, c5, (t - 0.5) / 0.1);
    if (t < 0.7) return lerp(c5, c6, (t - 0.6) / 0.1);
    if (t < 0.8) return lerp(c6, c7, (t - 0.7) / 0.1);
    return lerp(c7, c8, (t - 0.8) / 0.2);
}
// Deep blue at the top through pale yellow at the center to dark red below; the shockwave's is paler.
float3 sheenColor(float t) {
    return stops9(t, float3(0.13, 0.13, 0.13), float3(0.11, 0.12, 0.27), float3(0.11, 0.27, 0.53),
        float3(0.23, 0.58, 0.72), float3(0.82, 0.88, 0.55), float3(0.91, 0.52, 0.27), float3(0.46, 0.12, 0.12),
        float3(0.16, 0.15, 0.15), float3(0.3, 0.3, 0.3));
}
float3 paleSheenColor(float t) {
    return stops9(t, float3(0.44, 0.44, 0.44), float3(0.45, 0.5, 0.58), float3(0.49, 0.59, 0.74),
        float3(0.55, 0.75, 0.81), float3(0.86, 0.91, 0.63), float3(0.93, 0.69, 0.55), float3(0.69, 0.45, 0.44),
        float3(0.4, 0.37, 0.37), float3(0.37, 0.37, 0.37));
}
float3 sheen(float2 px, float2 center, float2 size, bool pale) {
    float a = glowAlpha(px, center, size);
    float yDown = 0.5 - (px.y - center.y) / size.y;
    return (pale ? paleSheenColor(yDown) : sheenColor(yDown)) * a;
}

// The eclipse arcs are the bottom of an ellipse: lowest at the center, drawn as they appear, a dome.
float arcY(float x, float bottom, float halfWidth, float depth) {
    float dx = min(abs(x - 0.5) / halfWidth, 1.0);
    return bottom - depth + depth * sqrt(1.0 - dx * dx);
}
float arcFade(float x, float reach) { float dx = abs(x - 0.5) / reach; return max(0.0, 1.0 - dx * dx * dx); }

static const float ARC_STOPS[12] = { 0.0, 5.0 / 39.0, 9.0 / 39.0, 13.0 / 39.0, 16.0 / 39.0, 19.0 / 39.0, 21.0 / 39.0,
    24.0 / 39.0, 27.0 / 39.0, 31.0 / 39.0, 35.0 / 39.0, 1.0 };
static const float3 ARC_COLORS[12] = { float3(0.24, 0.28, 0.43), float3(0.29, 0.37, 0.53), float3(0.35, 0.49, 0.56),
    float3(0.45, 0.62, 0.53), float3(0.58, 0.72, 0.56), float3(0.75, 0.78, 0.69), float3(0.79, 0.78, 0.71),
    float3(0.78, 0.67, 0.57), float3(0.70, 0.50, 0.38), float3(0.60, 0.30, 0.24), float3(0.47, 0.18, 0.17),
    float3(0.30, 0.13, 0.13) };

float3 arcColor(float t) {
    t = saturate(t);
    [unroll] for (int i = 1; i < 12; i++) {
        if (t <= ARC_STOPS[i])
            return lerp(ARC_COLORS[i - 1], ARC_COLORS[i], (t - ARC_STOPS[i - 1]) / (ARC_STOPS[i] - ARC_STOPS[i - 1]));
    }
    return ARC_COLORS[11];
}
// The rainbow arc at a point of its layer (x 0…1 from the left, y 0…1 from the bottom), black off it.
float3 rainbowArc(float2 uv) {
    float rows = (uv.y - arcY(uv.x, 0.648, 0.45, 0.927)) * 398.0;
    float envelope = rows < 0.0 ? 1.0 - sstep(21.0, 27.0, -rows) : 1.0 - sstep(18.0, 24.0, rows);
    return arcColor((rows + 21.0) / 39.0) * envelope * arcFade(uv.x, 0.33);
}
// The rainbow blurred across its bands by `deviation` (layer units up): it softens as the wave rises.
float3 blurredRainbowArc(float2 uv, float deviation) {
    if (deviation < 0.0005) return rainbowArc(uv);
    float3 sum = float3(0.0, 0.0, 0.0);
    float total = 0.0;
    [unroll] for (int i = -4; i <= 4; i++) {
        float k = float(i) * 0.75;
        float w = exp(-0.5 * k * k);
        sum += rainbowArc(uv + float2(0.0, k * deviation)) * w;
        total += w;
    }
    return sum / total;
}
float darkArc(float2 uv) {
    float d = uv.y - arcY(uv.x, 0.633, 1.0, 4.42);
    return 1.0 - 0.31 * exp(-(d * d) / (2.0 * 0.071 * 0.071)) * arcFade(uv.x, 0.36);
}
float2 layerUv(float2 px, float2 center, float2 size) { return (px - center) / size + 0.5; }
// The rainbow's layer is 398 canvas units high at its scale.
float3 rainbowArcAt(float2 uv) {
    return blurredRainbowArc(uv, uRainbowBlur / (398.0 * scaleUnit() * uRainbow.z));
}
bool inLayer(float2 uv) { return all(uv >= 0.0) && all(uv <= 1.0); }

float3 lights(float2 px, float su) {
    float3 light = float3(0.0, 0.0, 0.0);
    if (uRidgeGlow.z > 0.0)
        light += glowAlpha(px, uRidgeGlow.xy, float2(413.0 * 8.54, 165.0 * 5.92) * su) * uRidgeGlow.z;
    if (uShockSheen.z > 0.0)
        light += sheen(px, uShockSheen.xy, float2(1130.0, 391.0) * 4.47 * su, true) * uShockSheen.z;
    float2 hint = float2(0.0, uHintMove.y);
    if (uHint.x > 0.0)
        light += glowAlpha(px, canvasPoint(float2(589.0, 2532.5)) + hint, float2(1130.0, 391.0) * 2.64 * su) * uHint.x;
    if (uHint.y > 0.0)
        light += glowAlpha(px, canvasPoint(float2(589.0, 2509.5)) + hint, float2(648.0, 391.0) * 1.98 * su) * uHint.y;
    if (uHint.z > 0.0)
        light += glowAlpha(px, canvasPoint(float2(589.0, 2556.0)) + hint, float2(560.0, 300.0) * 1.4 * su) * uHint.z;
    if (uHint.w > 0.0)
        light += sheen(px, float2(canvasPoint(float2(589.0, 0.0)).x, uHintMove.x) + hint,
            float2(1346.0, 1600.0) * 1.89 * su, false) * uHint.w;
    return light;
}

float3 bloom(float2 px, float su) {
    if (uCircle.w <= 0.0) return float3(0.0, 0.0, 0.0);
    float2 size = float2(1000.0, 1000.0) * su * uCircle.z;
    float r = length((px - uCircle.xy) / (size * 0.5)) * 2.0;
    return float3(1.0, 0.985, 0.94) * exp(-r * r * 2.2) * uCircle.w;
}

float4 ps(float4 position : SV_Position) : SV_Target {
    float2 px = float2(position.x, uSize.y - position.y);
    // Nothing of the effect reaches this high (the shockwave's sheen ends below 0.9 of the canvas).
    if (px.y > uStage.z * 0.95)
        return uHasScreen < 0.5 ? float4(0.0, 0.0, 0.0, 1.0) : float4(screenLod(px, 0.0), 1.0);
    float su = scaleUnit();
    float2 q = phone(px);
    float dimAlpha = uDim * (1.0 - sstep(0.40, 0.64, q.y)) * (1.0 - sstep(0.4, 1.6, abs(q.x)));

    float3 base = uHasScreen < 0.5 ? float3(0.0, 0.0, 0.0) : screenLod(px, 0.0);
    float3 color = base;

    float2 center = float2(uStage.x + uStage.y * 0.5, 0.0);
    // The backdrop: out to reachAcross half-widths and up to reachUp heights, meeting the screen through a fade.
    float halfWidth = min(uSize.x * 0.5, uStage.y * 0.5 * REACH_ACROSS);
    float areaHeight = uStage.z * REACH_UP;
    float2 area = float2((px.x - (center.x - halfWidth)) / (halfWidth * 2.0), px.y / areaHeight);
    float inArea = step(0.0, area.x) * step(area.x, 1.0) * step(area.y, 1.0);
    float fade = (1.0 - sstep(0.93, 1.0, area.y)) * (1.0 - sstep(0.93, 1.0, abs(area.x - 0.5) * 2.0)) * inArea;

    if (uHasScreen > 0.5 && fade > 0.0 && uBackdrop > 0.0) {
        float2 d = displacement(q);
        float2 lo = float2(center.x - halfWidth, 0.0);
        float2 source = clamp(px + float2(d.x * uStage.y, d.y * uStage.z), lo, lo + float2(halfWidth * 2.0, areaHeight));
        // The hint's blur: full up to its boundary, 0.44 of the way up and curving up to the sides, then soft above it.
        float boundary = 0.44 + 0.020 * q.x * q.x;
        float blurMask = min(1.0, (1.0 - sstep(boundary - 0.055, boundary + 0.13, q.y)) * BLUR_TUNING)
            * strengthAcross(q.x);
        float3 moved = screenAt(source, uBlur * blurMask);
        // The ridge's band: what is below it, refraction included, blurred, its red and blue drawn apart.
        if (uBand.y > 0.0) {
            float curve = min(abs(q.x), 1.0);
            float distance = (px.y - uBand.x) / uStage.z - 0.045 * curve * curve;
            float band = exp(-sq(distance / 0.17)) * strengthAcross(q.x) * uBand.y;
            if (band > 0.002) {
                float sigma = 8.0 * su;
                float3 fringed = float3(
                    screenAt(source + float2(0.0, uBand.z), sigma).r,
                    screenAt(source, sigma).g,
                    screenAt(source - float2(0.0, uBand.z), sigma).b);
                moved = lerp(moved, fringed, band);
            }
        }
        color = lerp(base, moved, fade * uBackdrop);
    }

    color *= 1.0 - dimAlpha;
    color += bloom(px, su);
    if (uRainbow.w > 0.0) {
        float2 uv = layerUv(px, uRainbow.xy, float2(795.0, 398.0) * su * uRainbow.z);
        if (inLayer(uv)) {
            float3 dodge = min(color / max(1.0 - rainbowArcAt(uv) * 0.999, 0.001), 1.0);
            color = lerp(color, dodge, uRainbow.w);
        }
    }
    if (uDarkArc.w > 0.0) {
        float2 uv = layerUv(px, uDarkArc.xy, float2(795.0, 398.0) * su * uDarkArc.z);
        if (inLayer(uv)) color *= lerp(1.0, darkArc(uv), uDarkArc.w);
    }
    color += lights(px, su);
    return float4(saturate(color), 1.0);
}

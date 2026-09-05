#include <metal_stdlib>
using namespace metal;

// Catmull-Rom reconstruction retains sharp text during magnification. Unlike
// a bilinear-only blur pass, each shutter sample retains its spatial detail.
static float4 cubicWeights(float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    return float4(-0.5f*t + t2 - 0.5f*t3, 1.0f - 2.5f*t2 + 1.5f*t3,
                  0.5f*t + 2.0f*t2 - 1.5f*t3, -0.5f*t2 + 0.5f*t3);
}

static float lanczosWeight(float x) {
    x = abs(x);
    if (x < 0.00001f) return 1;
    if (x >= 2.0f) return 0;
    float a = M_PI_F * x;
    return sin(a) * sin(a * 0.5f) / (a * a * 0.5f);
}

static float4 reconstruct(texture2d<float, access::sample> image, float2 uv, float2 drawSize) {
    constexpr sampler pixelSampler(coord::pixel, address::clamp_to_edge, filter::nearest);
    float2 size = float2(image.get_width(), image.get_height());
    float2 p = uv * size - 0.5f;
    float2 scale = clamp(size / drawSize, 1.0f, 4.0f);
    if (scale.x > 1.0f || scale.y > 1.0f) {
        // Expand the reconstruction footprint when reducing Retina frames:
        // a fixed 4-tap magnification filter would alias one-pixel features.
        int2 low = int2(ceil(p - 2.0f * scale));
        int2 high = int2(floor(p + 2.0f * scale));
        // The Swift renderer bounds the scale to 4, hence at most 17 taps
        // per axis. Reuse horizontal weights instead of recomputing their
        // trigonometric functions for every row of the filter.
        float weightsX[17];
        float totalX = 0;
        for (int x = low.x; x <= high.x; ++x) {
            float weight = lanczosWeight((p.x - float(x)) / scale.x);
            weightsX[x - low.x] = weight;
            totalX += weight;
        }
        float4 color = 0;
        float totalY = 0;
        for (int y = low.y; y <= high.y; ++y) {
            float wy = lanczosWeight((p.y - float(y)) / scale.y);
            float4 row = 0;
            for (int x = low.x; x <= high.x; ++x) {
                row += image.sample(pixelSampler, float2(x, y) + 0.5f) * weightsX[x - low.x];
            }
            color += row * wy;
            totalY += wy;
        }
        return clamp(color / (totalX * totalY), 0.0f, 1.0f);
    }
    float2 origin = floor(p);
    float4 wx = cubicWeights(p.x - origin.x);
    float4 wy = cubicWeights(p.y - origin.y);
    float4 color = 0;
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            color += image.sample(pixelSampler, origin + float2(x - 1, y - 1) + 0.5f) * wx[x] * wy[y];
        }
    }
    return clamp(color, 0.0f, 1.0f);
}

kernel void studioMotionBlur(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<float, access::read> backdrop [[texture(1)]],
                             texture2d<float, access::read> clip [[texture(2)]],
                             texture2d<float, access::write> output [[texture(3)]],
                             constant float4 *rects [[buffer(0)]],
                             constant uint &count [[buffer(1)]],
                             uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) return;
    float4 result = backdrop.read(pixel);
    float coverage = clip.read(pixel).a;
    float2 center = float2(pixel) + 0.5f;
    if (coverage > 0) {
        for (uint i = 0; i < count; ++i) {
            float4 rect = rects[i];
            float2 edge = clamp(min(center - rect.xy, rect.xy + rect.zw - center) + 0.5f, 0.0f, 1.0f);
            float opacity = coverage * edge.x * edge.y / float(i + 1);
            if (opacity == 0) continue;
            float4 value = reconstruct(source, (center - rect.xy) / rect.zw, rect.zw);
            // Match the existing premultiplied source-over running average
            // in encoded sRGB bytes, including 8-bit rounding after each draw.
            result = round(clamp(value * opacity + result * (1.0f - value.a * opacity), 0.0f, 1.0f) * 255.0f) / 255.0f;
        }
    }
    output.write(result, pixel);
}

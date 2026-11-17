#include <metal_stdlib>
using namespace metal;

struct StudioFaceTouchUpParameters {
    // Where the output's pixel (0, 0) sits in the source texture.
    int2 offset;
    // Pixels between taps; the filter reaches three taps each way.
    float step;
    // How different a neighbour may be, in gamma-ish units, before it
    // stops counting: wider smooths stronger blemishes away.
    float rangeSigma;
    float smoothing;
    // The share of the finest texture put back over the smoothed skin.
    float grain;
    float light;
};

// The most face light lifts a midtone by, in gamma-ish units.
constant float maximumLight = 0.2f;
// The share of the lift added as neutral light rather than scaling the
// face's own colour. Light reflecting off skin isn't all skin-coloured:
// scaling alone made a lit face read orange.
constant float neutralLight = 0.35f;
// How much further skin colour is evened than skin brightness. Blotches
// and redness live in colour; pores and texture live in brightness.
constant float toneEvening = 1.35f;
constant float3 lumaWeights = float3(0.2126f, 0.7152f, 0.0722f);

// Skin smoothing then face light, for the face Vision found.
//
// Smoothing is an edge-preserving (bilateral) blur where the skin mask is,
// blended back over the original. Eyes, brows and lips are cut out of the
// mask, and the range weight keeps any remaining hard edge - a hairline, a
// beard - from bleeding.
//
// The smoothed result is split into brightness and colour: colour (where
// redness and blotches are) is evened a little further than brightness,
// so tone evens out while the skin keeps its texture.
//
// Face light lifts brightness on a curve that peaks in the shadows and
// fades to nothing at white, mostly by scaling the face's colour and partly
// as neutral light, the way a soft white key light lands: the face
// brightens without turning orange, and never clips.
kernel void studioFaceTouchUp(texture2d<float, access::read> source [[texture(0)]],
                              texture2d<float, access::read> skin [[texture(1)]],
                              texture2d<float, access::read> light [[texture(2)]],
                              texture2d<float, access::write> output [[texture(3)]],
                              constant StudioFaceTouchUpParameters &parameters [[buffer(0)]],
                              uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) return;
    int2 size = int2(source.get_width(), source.get_height());
    int2 center = clamp(int2(pixel) + parameters.offset, int2(0), size - 1);
    float4 original = source.read(uint2(center));
    float smoothWeight = skin.read(min(pixel, uint2(skin.get_width() - 1, skin.get_height() - 1))).r
        * parameters.smoothing;
    float lightWeight = light.read(min(pixel, uint2(light.get_width() - 1, light.get_height() - 1))).r
        * parameters.light;
    float3 color = original.rgb;

    if (smoothWeight >= 0.004f) {
        // Compare in a perceptual-ish space so shadows and highlights
        // smooth alike; the working space is linear.
        float3 reference = sqrt(max(original.rgb, 0.0f));
        float inverseRange = 1.0f / (2.0f * parameters.rangeSigma * parameters.rangeSigma);
        float3 total = 0;
        float totalWeight = 0;
        // The neighbourhood's brightness spread, from spatial weights alone.
        float lumaSum = 0, lumaSquares = 0, spatialSum = 0;
        for (int y = -3; y <= 3; ++y) {
            for (int x = -3; x <= 3; ++x) {
                float2 offset = float2(x, y) * parameters.step;
                int2 tap = clamp(center + int2(round(offset)), int2(0), size - 1);
                float3 neighbour = source.read(uint2(tap)).rgb;
                float3 gamma = sqrt(max(neighbour, 0.0f));
                float3 difference = gamma - reference;
                // Spatial sigma of 1.5 taps.
                float spatial = exp(-float(x * x + y * y) / 4.5f);
                float range = exp(-dot(difference, difference) * inverseRange);
                float w = spatial * range;
                total += neighbour * w;
                totalWeight += w;
                float luma = dot(gamma, lumaWeights);
                lumaSum += luma * spatial;
                lumaSquares += luma * luma * spatial;
                spatialSum += spatial;
            }
        }
        float mean = lumaSum / spatialSum;
        float spread = sqrt(max(lumaSquares / spatialSum - mean * mean, 0.0f));
        // Skin, blemishes and all, is calm next to stubble, lashes and
        // hair, which are left as they are.
        smoothWeight *= 1.0f - smoothstep(0.09f, 0.18f, spread);

        // The finest texture - pores, the camera's grain - is what makes
        // skin read as skin, and what the rest of the frame still has: put
        // some of it back, so mostly blemishes and uneven tone smooth away.
        float3 local = 0;
        for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
                local += source.read(uint2(clamp(center + int2(x, y), int2(0), size - 1))).rgb;
            }
        }
        float3 grain = original.rgb - local / 9.0f;
        float3 blurred = total / max(totalWeight, 1e-5f);
        float3 smoothed = max(blurred + grain * parameters.grain, 0.0f);

        float originalLuma = dot(original.rgb, lumaWeights);
        float smoothedLuma = dot(smoothed, lumaWeights);
        float blurredLuma = dot(blurred, lumaWeights);
        float luma = mix(originalLuma, smoothedLuma, smoothWeight);
        float3 tone = mix(original.rgb - originalLuma, blurred - blurredLuma, min(smoothWeight * toneEvening, 1.0f));
        color = max(luma + tone, 0.0f);
    }

    if (lightWeight >= 0.004f) {
        float3 gamma = sqrt(max(color, 0.0f));
        float luma = dot(gamma, lumaWeights);
        if (luma > 1e-4f && luma < 1.0f) {
            // 4v(1-v)^2 peaks at a third and is gentle by the highlights.
            float lift = maximumLight * lightWeight * 4.0f * luma * (1.0f - luma) * (1.0f - luma);
            float3 scaled = gamma * ((luma + lift) / luma);
            float3 lit = mix(scaled, gamma + lift, neutralLight);
            color = lit * lit;
        }
    }

    output.write(float4(color, original.a), pixel);
}

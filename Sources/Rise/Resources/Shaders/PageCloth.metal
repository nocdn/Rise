#include <metal_stdlib>
using namespace metal;

struct ClothUniforms {
    float2 size;
    float pull, elapsed, strength, originFraction, forward, reveal;
};
struct Raster { float4 position [[position]]; float2 uv; };
vertex Raster clothVertex(uint id [[vertex_id]]) {
    float2 p = id == 0 ? float2(-1,-1) : id == 1 ? float2(3,-1) : float2(-1,3);
    return { float4(p,0,1), p * float2(0.5,-0.5) + 0.5 };
}

// Uniform side compression at every height. In the forward mapping, horizontal
// displacement is depth * (1 - sourceX / width), tapering to zero at the far edge.
// Keep vertical coordinates unchanged; the release ripple is applied separately.
float2 clothWarp(float2 p, constant ClothUniforms &u) {
    float2 q = p;
    if (u.forward > 0.5) q.x = u.size.x - q.x;
    float depth = u.size.x * 0.05 * u.pull;
    float sourceX = (q.x - depth) * u.size.x / (u.size.x - depth);
    float sourceY = q.y;
    if (u.forward > 0.5) sourceX = u.size.x - sourceX;
    return clamp(float2(sourceX, sourceY), float2(0.5), u.size - float2(0.5));
}
float2 canonical(float2 p, constant ClothUniforms &u) {
    return float2(u.forward > 0.5 ? u.size.x - p.x : p.x, p.y);
}
float4 pageComposite(float2 p, constant ClothUniforms &u,
                     texture2d<float> outgoing, texture2d<float> incoming) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = clothWarp(p,u) / u.size;
    float4 old = outgoing.sample(s,uv);
    if (u.reveal < 0.5) return old;
    // Exact flat destination endpoint, also for very tall/narrow split panes.
    if (u.elapsed >= 0.30) return incoming.sample(s,uv);
    float distance = abs(canonical(p,u).x - u.originFraction*u.size.x);
    float scale = u.size.x / 280.0;
    float front = max(u.elapsed,0.0) * 1320.0 * scale;
    float oldAlpha = smoothstep(front-26.0*scale,front+26.0*scale,distance);
    return mix(incoming.sample(s,uv),old,oldAlpha);
}
fragment float4 clothFragment(Raster in [[stage_in]], constant ClothUniforms &u [[buffer(0)]],
                              texture2d<float> outgoing [[texture(0)]], texture2d<float> incoming [[texture(1)]]) {
    float2 p = in.uv * u.size;
    if (u.elapsed < 0.0 || u.elapsed >= 0.30 || u.strength <= 0.0)
        return pageComposite(p,u,outgoing,incoming);
    // A full-height wavefront moves inward from the released side. Its wider
    // envelope and shorter clock are independent of the page's spring return.
    float offset = canonical(p,u).x - u.originFraction*u.size.x;
    float distance = abs(offset), scale = u.size.x / 280.0;
    float front = u.elapsed * 1320.0 * scale;
    float packet = exp(-pow((distance-front)/(50.0*scale),2.0));
    float fade = 1.0 - smoothstep(0.24,0.30,u.elapsed);
    float wave = packet * fade * exp(-u.elapsed*1.68) * clamp(u.strength,0.0,1.0);
    float2 direction = float2(offset < 0.0 ? -1.0 : 1.0,0.0);
    if (u.forward > 0.5) direction.x = -direction.x;
    float2 samplePosition = clamp(p + direction*(wave*4.0*scale),float2(0.5),u.size-float2(0.5));
    float4 color = pageComposite(samplePosition,u,outgoing,incoming);
    color.rgb = clamp(color.rgb + wave*0.028*color.a,float3(0),float3(color.a));
    return color;
}

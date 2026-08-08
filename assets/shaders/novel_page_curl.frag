#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform vec2 uDrag;
uniform float uDirection;
uniform vec4 uBackColor;
uniform sampler2D uCurrent;
uniform sampler2D uTarget;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / max(uSize, vec2(1.0));
  float progress = clamp(uDrag.x, 0.0, 1.0);
  float radius = clamp(0.045 + 0.035 * (1.0 - abs(uDrag.y - 0.5)), 0.035, 0.08);
  float fold = uDirection > 0.0 ? 1.0 - progress : progress;
  float signedDistance = uDirection > 0.0 ? uv.x - fold : fold - uv.x;
  float reveal = smoothstep(-radius, radius, signedDistance);
  vec4 current = texture(uCurrent, uv);
  vec4 target = texture(uTarget, uv);
  vec4 color = mix(current, target, reveal);

  float foldBand = 1.0 - smoothstep(0.0, radius, abs(signedDistance));
  float backFace = smoothstep(-radius, 0.0, signedDistance) *
      (1.0 - smoothstep(0.0, radius, signedDistance));
  color.rgb = mix(color.rgb, uBackColor.rgb * 0.92, backFace * 0.65);
  color.rgb *= 1.0 - foldBand * 0.16;
  color.rgb += foldBand * 0.05;
  fragColor = vec4(color.rgb, color.a);
}

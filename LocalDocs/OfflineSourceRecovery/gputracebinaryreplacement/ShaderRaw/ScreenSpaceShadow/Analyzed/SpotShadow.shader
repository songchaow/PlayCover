// Translated from Metal IR: rps450_SpotShadow_frag_lib302.ll
// Screen-space spot light shadow with 16-tap rotated Poisson disk sampling
Shader "Hidden/LYSK/ScreenSpaceShadow/SpotShadow"
{
    SubShader
    {
        Tags { "RenderType" = "Opaque" }

        Pass
        {
            Name "SpotShadow"
            ZTest Always
            ZWrite Off
            Cull Off

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 5.0

            #include "UnityCG.cginc"

            // Textures & Samplers
            sampler2D _CameraDepthTexture;
            Texture2D _LocalShadowMapAtlas;
            SamplerState sampler_LocalShadowMapAtlas;

            // UnityPerPass (index 5 = InvViewProjMatrix, index 10 = _HDRSize)
            float4x4 hlslcc_mtx4x4_InvViewProjMatrix;
            half4 _HDRSize;

            // _LocalLightShadowBuffer
            float4x4 hlslcc_mtx4x4_LocalLightWorldToShadow[3];
            half4 _LocalShadowStrength;
            float4x4 hlslcc_mtx4x4_CloseUpWorldToShadow;
            float4 _LocalLightShadowmapSize;
            float4 _LocalLightCloseUpShadowSliceTransform;

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float4 pos : SV_POSITION;
                float4 texcoord : TEXCOORD0;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.texcoord = o.pos;
                return o;
            }

            float4 frag(v2f i) : SV_Target
            {
                float4 clipPos = i.texcoord;

                // --- Step 1: Compute screen UV ---
                // %9 = clipPos.y
                // %11 = _ProjectionParams (UnityPerCamera index 10)
                // %12 = _ProjectionParams.x (projection sign flip)
                // %13 = _ProjectionParams.x * clipPos.y
                float correctedY = _ProjectionParams.x * clipPos.y;
                // %14 = clipPos with y replaced
                // %15 = (clipPos.x, correctedY)
                // %16 = (clipPos.w, clipPos.w)
                // %17 = (clipPos.x, correctedY) / clipPos.w
                float2 ndc = float2(clipPos.x, correctedY) / clipPos.w;
                // %18 = ndc * 0.5 + 0.5
                float2 screenUV = ndc * 0.5 + 0.5;

                // --- Step 2: Load _HDRSize.xy (UnityPerPass index 10, half4) ---
                float2 hdrSize = (float2)_HDRSize.xy;

                // --- Step 3: Sample depth ---
                // %23 = sample(_CameraDepthTexture, screenUV)
                float depth = tex2D(_CameraDepthTexture, screenUV).r;

                // --- Step 4: Dithering rotation angle ---
                // %24 = screenUV * 0x3F40000000000000 = screenUV * (1.0/2048.0)
                float2 scaledUV = screenUV * 0.000488281250;
                // %25 = scaledUV * hdrSize
                float2 noiseInput = scaledUV * hdrSize;
                // %26 = noiseInput >= 0
                bool2 isPositive = (noiseInput >= 0.0);
                // %27 = abs(noiseInput)
                float2 absInput = abs(noiseInput);
                // %28 = fract(absInput) [fast path since arg=0]
                float2 fractAbs = frac(absInput);
                // %32,%36 = sign-corrected fract
                float2 signedFract;
                signedFract.x = isPositive.x ? fractAbs.x : -fractAbs.x;
                signedFract.y = isPositive.y ? fractAbs.y : -fractAbs.y;

                // %40 = fma(signedFract, 0x3FDE573AC0000000, (0.25, 0.0))
                float2 hashInput = signedFract * 0.4740740656852722 + float2(0.25, 0.0);
                // %41 = hashInput * hashInput
                float2 hashSq = hashInput * hashInput;
                // %42 = dot(hashSq, (3571.0, 3571.0))
                float h1 = dot(hashSq, float2(3571.0, 3571.0));
                // %43 = fract(h1)
                float h1f = frac(h1);
                // %44 = h1f * h1f
                float h1f2 = h1f * h1f;
                // %47 = dot((h1f2, h1f2), (3571.0, 3571.0)) = h1f2 * 7142.0
                float h2 = h1f2 * 7142.0;
                // %48 = fract(h2)
                float h2f = frac(h2);
                // %49 = h2f - 0.5
                float centered = h2f - 0.5;
                // %50 = fract(centered)
                float angle01 = frac(centered);
                // %51 = (half)angle01
                // %52 = angle01 * 6.28125 (half 0xH4648 ≈ 2*PI)
                // %53 = fpext to float
                float angleRad = (float)((half)angle01 * (half)6.28125);
                // %54 = sin(angleRad)
                float sinA = sin(angleRad);
                // %56 = cos(angleRad)
                float cosA = cos(angleRad);

                // --- Step 5: Shadow texel offset ---
                // %59 = _LocalLightShadowmapSize
                // %60 = .w, %61 = .z
                // %62 = w / z
                float texelRatio = _LocalLightShadowmapSize.w / _LocalLightShadowmapSize.z;
                // Poisson radius constant: 0x3F600E6B00000000
                // %65 = texelRatio * (-R, +R)
                const float POISSON_R = 0.0019600000232458115;
                float2 baseOffset = texelRatio * float2(-POISSON_R, POISSON_R);
                // %67 = baseOffset * cos (broadcasted)
                float2 offsetCos = baseOffset * cosA;
                // %69 = baseOffset * sin (broadcasted)
                float2 offsetSin = baseOffset * sinA;

                // --- Step 6: Reconstruct world position ---
                // %70 = clipPos.xy (original)
                // %71 = clipPos.xy / clipPos.w (original NDC without y-flip)
                float2 origNDC = clipPos.xy / clipPos.w;
                // %72 = origNDC.yyyy
                // Reconstruct: InvViewProjMatrix * (origNDC.x, origNDC.y, depth, 1)
                // The IR does: row0*x + row1*y + row2*depth + row3
                float4 worldPos4 = hlslcc_mtx4x4_InvViewProjMatrix[0] * origNDC.x
                                 + hlslcc_mtx4x4_InvViewProjMatrix[1] * origNDC.y
                                 + hlslcc_mtx4x4_InvViewProjMatrix[2] * depth
                                 + hlslcc_mtx4x4_InvViewProjMatrix[3];
                // %92 = worldPos4.xyz / worldPos4.w
                float3 worldPos = worldPos4.xyz / worldPos4.w;

                // --- Step 7: Transform to shadow space ---
                // LocalLightWorldToShadow[0] (first 4x4 matrix, rows 0-3)
                float4x4 lightMat = hlslcc_mtx4x4_LocalLightWorldToShadow[0];
                float4 shadowPos4 = lightMat[0] * worldPos.x
                                  + lightMat[1] * worldPos.y
                                  + lightMat[2] * worldPos.z
                                  + lightMat[3];
                // %110 = shadowPos4.xyz / shadowPos4.w
                float3 shadowCoord = shadowPos4.xyz / shadowPos4.w;

                // --- Step 8: 4-gather shadow sampling (16 depth comparisons) ---
                // Build 4 sample coordinates using rotated offsets:
                // Tap set 1 uses rotation matrix applied to baseOffset:
                // %111 = (offsetCos.x, offsetSin.x, offsetCos.y, offsetSin.y)
                // sampleCoords1 = shadowCoord.xyxy + %111
                float2 tap1A = shadowCoord.xy + float2(offsetCos.x, offsetSin.x);
                float2 tap1B = shadowCoord.xy + float2(offsetCos.y, offsetSin.y);

                // Tap set 2 uses perpendicular rotation (NO texelRatio in IR):
                // %129 = sin * (-R, +R)
                // %130 = cos * (+R, -R)
                // %131 = (sinOffset.x, cosOffset.x, sinOffset.y, cosOffset.y)
                // sampleCoords2 = shadowCoord.xyxy + %131
                float2 sinOffset = sinA * float2(-POISSON_R, POISSON_R);
                float2 cosOffset = cosA * float2(POISSON_R, -POISSON_R);
                float2 tap2A = shadowCoord.xy + float2(sinOffset.x, cosOffset.x);
                float2 tap2B = shadowCoord.xy + float2(sinOffset.y, cosOffset.y);

                // Gather red channel (depth) from shadow map at each tap
                // Each gather returns 4 depth values from 2x2 texel neighborhood
                float4 g1 = _LocalShadowMapAtlas.Gather(sampler_LocalShadowMapAtlas, tap1A);
                float4 g2 = _LocalShadowMapAtlas.Gather(sampler_LocalShadowMapAtlas, tap1B);
                float4 g3 = _LocalShadowMapAtlas.Gather(sampler_LocalShadowMapAtlas, tap2A);
                float4 g4 = _LocalShadowMapAtlas.Gather(sampler_LocalShadowMapAtlas, tap2B);

                // Shadow comparison: shadowCoord.z >= gathered_depth ? 1.0 : 0.0
                float refZ = shadowCoord.z;
                float4 cmp1 = (refZ >= g1) ? 1.0 : 0.0;
                float4 cmp2 = (refZ >= g2) ? 1.0 : 0.0;
                float4 cmp3 = (refZ >= g3) ? 1.0 : 0.0;
                float4 cmp4 = (refZ >= g4) ? 1.0 : 0.0;

                // Sum all 16 comparisons in the exact order from the IR:
                // The IR adds: cmp2[1]+cmp2[0]+cmp2[2]+cmp2[3]
                //            + cmp3[1]+cmp3[0]+cmp3[2]+cmp3[3]
                //            + cmp1[1]+cmp1[0]+cmp1[2]+cmp1[3]
                //            + cmp4[1]+cmp4[0]+cmp4[2]+cmp4[3]
                float shadow = (cmp2.y + cmp2.x + cmp2.z + cmp2.w)
                             + (cmp3.y + cmp3.x + cmp3.z + cmp3.w)
                             + (cmp1.y + cmp1.x + cmp1.z + cmp1.w)
                             + (cmp4.y + cmp4.x + cmp4.z + cmp4.w);

                // Average: 1/16 = 0.0625
                shadow *= 0.0625;

                // Output: float4(1.0, shadow, 1.0, 1.0)
                return float4(1.0, shadow, 1.0, 1.0);
            }
            ENDCG
        }
    }

    FallBack Off
}

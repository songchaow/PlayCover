// Translated from Metal IR: rps449_ScreenSpaceShadowMap_simple_frag_lib298.ll
// Original shader: ScreenSpaceShadowMap (simple variant)
// This shader is from an external project and is NOT related to our project.
Shader "Hidden/ScreenSpaceShadowMap_Simple"
{
    Properties
    {
        _SSAOTexture ("SSAO Texture", 2D) = "white" {}
        _PenumbraMask ("Penumbra Mask", 2D) = "white" {}
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" }

        Pass
        {
            ZWrite Off
            ZTest Always
            Cull Off

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 4.5

            #include "UnityCG.cginc"

            // Corresponds to _DirectionalShadowBuffer_Type in the Metal IR
            // Only the field at offset 1284 (_PenumbraBias) is actually used in this shader
            float _PenumbraBias;

            // Texture2D + SamplerState declarations for Gather support
            Texture2D _SSAOTexture;
            SamplerState sampler_SSAOTexture;

            Texture2D _PenumbraMask;
            SamplerState sampler_PenumbraMask;

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                return o;
            }

            float4 frag(v2f i) : SV_Target
            {
                // Step 1: Gather the red channel from _PenumbraMask at the UV coordinate.
                // air.gather_texture_2d gathers 4 texels (2x2 footprint) of the specified component.
                // The last i32 0 parameter indicates component 0 (Red channel).
                // Gather() returns the red channel values from the 4 texels in the 2x2 footprint.
                float4 gathered = _PenumbraMask.Gather(sampler_PenumbraMask, i.uv);

                // Step 2: Sum all 4 gathered components
                // IR: %12 = fadd %10, %11; %14 = fadd %12, %13; %16 = fadd %14, %15
                float sum = gathered.x + gathered.y + gathered.z + gathered.w;

                // Step 3: Average (multiply by 0.25)
                // IR: %17 = fmul fast float %16, 2.500000e-01
                float avg = sum * 0.25;

                // Step 4: Conditional discard
                // IR: %18 = fcmp fast ogt float %16, 0x3FA47AE140000000  (0.04f)
                // IR: %21 = fcmp fast olt float %17, %20  (_PenumbraBias)
                // IR: %22 = select i1 %21, i1 %18, i1 false
                // Semantics: if (sum > 0.04 && avg < _PenumbraBias) discard
                bool sumAboveThreshold = sum > 0.04;
                bool avgBelowBias = avg < _PenumbraBias;

                if (sumAboveThreshold && avgBelowBias)
                {
                    discard;
                }

                // Step 5: Sample _SSAOTexture at the same UV
                // IR: air.sample_texture_2d on _SSAOTexture with sampler_SSAOTexture
                float4 ssaoSample = _SSAOTexture.Sample(sampler_SSAOTexture, i.uv);

                // Step 6: Construct output
                // IR: float4(avg, 1.0, 1.0, ssaoSample.r)
                // %29 = insertelement <float undef, 1.0, 1.0, undef>, ssaoSample.r -> index 3
                // %30 = insertelement %29, avg -> index 0
                return float4(avg, 1.0, 1.0, ssaoSample.r);
            }
            ENDCG
        }
    }

    FallBack Off
}

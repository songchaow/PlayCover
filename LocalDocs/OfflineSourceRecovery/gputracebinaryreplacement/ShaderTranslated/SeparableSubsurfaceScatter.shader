Shader "Papegame/LYSK/SeparableSubsurfaceScatter"
{
    Properties
    {
        _SceneTex ("Scene Texture", 2D) = "white" {}
        _QuarterLinearDepthTexture ("Quarter Linear Depth", 2D) = "white" {}
        _SSSSkinAlphaTexture ("SSS Skin Alpha", 2D) = "white" {}
        _SSSScale ("SSS Scale", Float) = 1.0
        _SamplerSteps ("Sampler Steps", Int) = 25
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "Queue"="Geometry" }

        Pass
        {
            Name "SeparableSSS"
            ZTest Always
            ZWrite Off
            Cull Off

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0
            #pragma multi_compile_local _ _HIGH_QUALITY

            #include "UnityCG.cginc"

            half4 _QuarterDepthTexture_TexelSize;
            half _SSSScale;
            half4 _Kernel[25];
            int _SamplerSteps;

            sampler2D _QuarterLinearDepthTexture;
            sampler2D _SceneTex;
            sampler2D _SSSSkinAlphaTexture;

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float4 pos : SV_POSITION;
                half2 uv : TEXCOORD0;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                return o;
            }

            half4 frag(v2f i) : SV_Target
            {
                half2 uv = i.uv;

                half3 centerColor = tex2D(_SceneTex, (float2)uv).rgb;
                half skinAlphaR = tex2D(_SSSSkinAlphaTexture, (float2)uv).r;
                float skinMask = 1.0 - (float)skinAlphaR;

                const float kSkinThreshold = 0.99;
                const float kDepthScaleNumerator = 5.671281814575195f;

                if (skinMask <= kSkinThreshold)
                {
                    // Normal SSS blur loop path
                    half4 result;
                    result.a = (half)skinMask;

                    half texelOffset = _QuarterDepthTexture_TexelSize.x;
                    half baseStep = texelOffset * _SSSScale;
                    float centerDepth = tex2D(_QuarterLinearDepthTexture, (float2)uv).r;
                    half depthScale = (half)(kDepthScaleNumerator / centerDepth);
                    half stepScale = baseStep * depthScale;
                    half2 stepDir = half2(stepScale, 0.0h);

                    half3 colorAccum = _Kernel[0].rgb * centerColor;
                    half bilateralScale = baseStep * 1701.0h;

                    [loop]
                    for (int s = 1; s < _SamplerSteps; s++)
                    {
                        half kernelOffset = _Kernel[s].a;
                        float2 sampleUV = (float2)(half2(kernelOffset, kernelOffset) * stepDir + uv);

                        half3 sampleColor = tex2D(_SceneTex, sampleUV).rgb;
                        float sampleDepth = tex2D(_QuarterLinearDepthTexture, sampleUV).r;
                        half sampleAlpha = tex2D(_SSSSkinAlphaTexture, sampleUV).r;
                        float sampleSkinMask = 1.0 - (float)sampleAlpha;

                        half depthDiff = (half)(centerDepth - sampleDepth);
                        half bilateralWeight = saturate(bilateralScale * abs(depthDiff));

                        half3 blendedColor = lerp(sampleColor, centerColor, bilateralWeight);
                        half3 finalSampleColor = (half3)lerp((float3)blendedColor, (float3)centerColor, sampleSkinMask);

                        colorAccum += _Kernel[s].rgb * finalSampleColor;
                    }

                    result.rgb = colorAccum;
                    return result;
                }
                else
                {
                    // Fast bilateral path: skinMask > threshold
                    float4 centerFull = float4((float3)centerColor, skinMask);
                    half texelOffset = _QuarterDepthTexture_TexelSize.x;

                    half2 offset = half2(texelOffset, 0.0h);
                    float2 uvMinus = (float2)(uv - offset);
                    float2 uvPlus = (float2)(uv + offset);

                    half3 colorMinus = tex2D(_SceneTex, uvMinus).rgb;
                    half3 colorPlus = tex2D(_SceneTex, uvPlus).rgb;

                    half alphaMinus = tex2D(_SSSSkinAlphaTexture, uvMinus).r;
                    half alphaPlus = tex2D(_SSSSkinAlphaTexture, uvPlus).r;
                    float skinMaskMinus = 1.0 - (float)alphaMinus;
                    float skinMaskPlus = 1.0 - (float)alphaPlus;

                    float4 sampleMinus = float4((float3)colorMinus, skinMaskMinus);
                    float4 samplePlus = float4((float3)colorPlus, skinMaskPlus);

                    half alphaDiff = alphaPlus - alphaMinus;
                    float dirSign = saturate(sign((float)alphaDiff));
                    float4 blended = lerp(sampleMinus, samplePlus, dirSign);

                    half maskDiff = (half)(skinMask - blended.w);
                    float blendFactor = saturate(sign((float)maskDiff));
                    float4 finalResult = lerp(centerFull, blended, blendFactor);

                    if (finalResult.a > kSkinThreshold)
                    {
                        return (half4)finalResult;
                    }
                    else
                    {
                        // Fall through to SSS blur loop
                        half3 colorForLoop = (half3)finalResult.rgb;
                        half maskForLoop = (half)finalResult.a;

                        half baseStep = texelOffset * _SSSScale;
                        float centerDepth = tex2D(_QuarterLinearDepthTexture, (float2)uv).r;
                        half depthScale = (half)(kDepthScaleNumerator / centerDepth);
                        half stepScale = baseStep * depthScale;
                        half2 stepDir = half2(stepScale, 0.0h);

                        half3 colorAccum = _Kernel[0].rgb * colorForLoop;
                        half bilateralScale = baseStep * 1701.0h;

                        [loop]
                        for (int s = 1; s < _SamplerSteps; s++)
                        {
                            half kernelOff = _Kernel[s].a;
                            float2 sampleUV = (float2)(half2(kernelOff, kernelOff) * stepDir + uv);

                            half3 sampleColor = tex2D(_SceneTex, sampleUV).rgb;
                            float sampleDepth = tex2D(_QuarterLinearDepthTexture, sampleUV).r;
                            half sampleAlpha = tex2D(_SSSSkinAlphaTexture, sampleUV).r;
                            float sampleSkinMask = 1.0 - (float)sampleAlpha;

                            half depthDiffH = (half)(centerDepth - sampleDepth);
                            half bilateralWeight = saturate(bilateralScale * abs(depthDiffH));

                            half3 blendedCol = lerp(sampleColor, colorForLoop, bilateralWeight);
                            half3 finalSampleCol = (half3)lerp((float3)blendedCol, (float3)colorForLoop, sampleSkinMask);

                            colorAccum += _Kernel[s].rgb * finalSampleCol;
                        }

                        half4 result;
                        result.rgb = colorAccum;
                        result.a = maskForLoop;
                        return result;
                    }
                }
            }
            ENDCG
        }
    }

    FallBack Off
}
